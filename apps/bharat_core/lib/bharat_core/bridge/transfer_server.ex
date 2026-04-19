defmodule BharatCore.Bridge.TransferServer do
  @moduledoc """
  FSM for a single cross-chain token transfer.

  States:
    INIT      — unsigned lockTokens() tx built; waiting for user to submit MetaMask tx
    LOCKED    — lock tx_hash received from frontend; indexer takes over
    CONFIRMED — indexer confirmed TokensLocked at ≥12 blocks; relayer picks up
    MINTED    — relayer submitted mintOnProof(); mint tx_hash stored
    COMPLETED — all done
    FAILED    — terminal failure

  Responsibilities of this process:
    - INIT: build unsigned tx, broadcast to frontend
    - LOCKED: persist tx_hash, wait for indexer
    - CONFIRMED: set by indexer, relayer polls DB independently
    - MINTED/COMPLETED: set by relayer, broadcast final status

  What is NOT here:
    - KYC check (done by RequireKYC plug before this process starts)
    - Registry verification (out of scope for POC)
    - CBDC settlement (out of scope for POC)
    - Consensus / validators (deleted)
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatData.Transfers

  defstruct [:id, :wallet, :token_address, :amount,
             :nonce_hash, :lock_tx_hash, :state, :direction, :started_at]

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts[:id]))
  end

  def get_state(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :get_state)}
      {:error, _} = err -> err
    end
  end

  # Called by TransferController when user submits lock tx
  def lock_submitted(id, tx_hash) do
    case lookup(id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:lock_submitted, tx_hash})
        :ok
      {:error, _} ->
        # Process may have restarted; update DB directly
        Transfers.update_state(id, "locked", %{lock_tx_hash: tx_hash})
        :ok
    end
  end

  # Called by BlockchainIndexer when TokensLocked is confirmed on-chain
  def on_confirmed(id, block_number) do
    case lookup(id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:confirmed, block_number})
      {:error, _} ->
        # Process not running; update DB — relayer will pick it up
        Transfers.update_state(id, "confirmed", %{lock_block: block_number})
    end

    :ok
  end

  # Called by BharatRelayer.Worker after successful mint
  def on_minted(id, mint_tx_hash) do
    case lookup(id) do
      {:ok, pid} -> GenServer.cast(pid, {:minted, mint_tx_hash})
      {:error, _} ->
        Transfers.update_state(id, "minted", %{mint_tx_hash: mint_tx_hash})
        Transfers.update_state(id, "completed", %{})
        broadcast(id, %{event: "completed", state: "completed", transfer_id: id})
    end

    :ok
  end

  # ── Init ──────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = struct(__MODULE__,
      id:            opts[:id],
      wallet:        opts[:wallet],
      token_address: opts[:token_address],
      amount:        opts[:amount],
      nonce_hash:    compute_nonce(opts[:wallet], opts[:id]),
      state:         :init,
      direction:     opts[:direction] || "amoy_to_sepolia",
      started_at:    DateTime.utc_now()
    )

    {:ok, state, {:continue, :init_transfer}}
  end

  # ── handle_continue ───────────────────────────────────────────────────────

  @impl true
  def handle_continue(:init_transfer, s) do
    payload =
      if s.direction == "amoy_to_sepolia" do
        unsigned_tx = Contract.build_lock_tx(s.token_address, s.amount, s.id)
        %{event: "await_lock", transfer_id: s.id, unsigned_tx: unsigned_tx, nonce_hash: s.nonce_hash}
      else
        %{event: "await_burn", transfer_id: s.id, nonce_hash: s.nonce_hash}
      end

    broadcast(s.id, payload)
    Logger.info("Transfer #{s.id} INIT direction=#{s.direction} — awaiting user tx")
    {:noreply, s}
  end

  # ── Casts ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:lock_submitted, tx_hash}, %{state: :init} = s) do
    s = %{s | state: :locked, lock_tx_hash: tx_hash}
    Transfers.update_state(s.id, "locked", %{lock_tx_hash: tx_hash})
    broadcast(s.id, %{event: "state_change", state: "locked", tx_hash: tx_hash})
    Logger.info("Transfer #{s.id} LOCKED — tx #{tx_hash}")
    {:noreply, s}
  end

  def handle_cast({:confirmed, block_number}, %{state: state} = s) when state in [:init, :locked] do
    s = %{s | state: :confirmed}
    Transfers.update_state(s.id, "confirmed", %{lock_block: block_number})
    broadcast(s.id, %{event: "state_change", state: "confirmed", block: block_number})
    Logger.info("Transfer #{s.id} CONFIRMED at block #{block_number} (from #{state}) — relayer will process")
    {:noreply, s}
  end

  def handle_cast({:minted, mint_tx_hash}, %{state: :confirmed} = s) do
    s = %{s | state: :minted}
    Transfers.update_state(s.id, "minted", %{mint_tx_hash: mint_tx_hash})
    broadcast(s.id, %{event: "state_change", state: "minted", mint_tx_hash: mint_tx_hash})
    Logger.info("Transfer #{s.id} MINTED — tx #{mint_tx_hash}")
    {:noreply, s, {:continue, :complete}}
  end

  def handle_cast({:minted, mint_tx_hash}, %{state: :minted} = s) do
    # Idempotent — relayer may resubmit; ignore if already minted
    Logger.debug("Transfer #{s.id} duplicate minted cast — ignoring")
    {:noreply, s}
  end

  def handle_cast(msg, s) do
    Logger.warning("Transfer #{s.id}: unexpected cast #{inspect(msg)} in state #{s.state}")
    {:noreply, s}
  end

  # ── Completion ────────────────────────────────────────────────────────────

  @impl true
  def handle_continue(:complete, s) do
    s = %{s | state: :completed}
    Transfers.update_state(s.id, "completed", %{})
    broadcast(s.id, %{event: "completed", state: "completed", transfer_id: s.id})
    Logger.info("Transfer #{s.id} COMPLETED")
    # Process can exit — all state is in DB
    {:stop, :normal, s}
  end

  # ── Calls ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, s) do
    {:reply, Map.from_struct(s), s}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp compute_nonce(wallet, id) do
    :crypto.hash(:sha256, wallet <> id)
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end

  defp broadcast(id, payload) do
    Phoenix.PubSub.broadcast(BharatSetu.PubSub, "transfer:#{id}", {:transfer_update, payload})
  end

  defp via(id), do: {:via, Registry, {BharatCore.Bridge.Registry, id}}

  defp lookup(id) do
    case Registry.lookup(BharatCore.Bridge.Registry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
