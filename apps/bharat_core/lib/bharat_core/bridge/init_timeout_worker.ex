defmodule BharatCore.Bridge.InitTimeoutWorker do
  @moduledoc """
  Polls every 2 minutes and expires init transfers older than 10 minutes
  that have no lock_tx_hash (MetaMask was never confirmed).
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.{Contract, SolanaPortClient}

  @poll_interval_ms  120_000
  @cutoff_seconds    600
  @locked_cutoff_seconds 1_200  # 20 min grace for locked/confirmed

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    expired = Transfers.expire_stale_init_transfers(@cutoff_seconds)
    if expired > 0 do
      Logger.info("InitTimeoutWorker: expired #{expired} stale init transfer(s)")
    end

    rollback_stale_locked_transfers()

    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp rollback_stale_locked_transfers do
    stale = Transfers.get_stale_locked_transfers(@locked_cutoff_seconds)

    Enum.each(stale, fn transfer ->
      Logger.info("InitTimeoutWorker: rolling back stale transfer #{transfer.id} direction=#{transfer.direction}")

      on_chain_rollback(transfer)

      BharatCore.Bridge.TransferServer.on_rollback(
        transfer.id,
        "timeout rollback after #{@locked_cutoff_seconds}s"
      )
    end)
  end

  @evm_source_directions ~w(evm_to_solana nft_evm_to_solana amoy_to_sepolia cbdc_to_stablecoin token_to_instruction asset_to_instruction)
  @solana_source_directions ~w(solana_to_evm nft_solana_to_evm)

  # EVMEscrow.refundAfterTimeout is permissionless — anyone can call on-chain after 1hr timeout.
  # We call it proactively from the relayer.
  defp on_chain_rollback(%{direction: d, nonce_hash: nonce_hash}) when d in @evm_source_directions do
    case Contract.refund_after_timeout(nonce_hash) do
      {:ok, tx_hash} ->
        Logger.info("InitTimeoutWorker: EVM refund tx=#{tx_hash}")
      {:error, reason} ->
        Logger.warning("InitTimeoutWorker: EVM refund failed: #{inspect(reason)}")
    end
  end

  defp on_chain_rollback(%{direction: d, id: transfer_id}) when d in @solana_source_directions do
    program_id   = Application.get_env(:bharat_core, :solana_escrow_program)
    keypair_json = Application.get_env(:bharat_core, :relayer_solana_keypair)
    payload      = Jason.encode!(%{program_id: program_id, transfer_id: transfer_id, keypair_json: keypair_json})

    case SolanaPortClient.call("cancel_lock", payload) do
      {:ok, _} -> Logger.info("InitTimeoutWorker: Solana cancel_lock sent for #{transfer_id}")
      {:error, reason} -> Logger.warning("InitTimeoutWorker: Solana cancel_lock failed #{transfer_id}: #{inspect(reason)}")
    end
  end

  defp on_chain_rollback(_transfer), do: :ok

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
