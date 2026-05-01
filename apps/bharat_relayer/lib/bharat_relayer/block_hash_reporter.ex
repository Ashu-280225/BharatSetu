defmodule BharatRelayer.BlockHashReporter do
  @moduledoc """
  GenServer that watches Anvil for new finalized blocks and submits their
  block hashes to BlockHashOracle on Polygon Amoy.

  Each relayer runs its own BlockHashReporter — once `threshold` relayers
  agree on the same hash for a block, BlockHashOracle finalizes it, enabling
  StablecoinBridge.executeWithProof() to verify MPT proofs against that root.

  Confirmation depth: waits for CONFIRMATION_DEPTH blocks before submitting,
  matching the AnvilIndexer's finality assumption.
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract

  @confirmation_depth 3
  @poll_interval_ms   6_000

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      last_submitted: 0,
      pending: %{}   # block_number => block_hash (submitted but not confirmed on Amoy yet)
    }
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state2 = check_and_report(state)
    schedule_poll()
    {:noreply, state2}
  end

  # ── Internal ──────────────────────────────────────────────────────────────

  defp check_and_report(state) do
    with {:ok, current_block} <- Contract.anvil_block_number() do
      finalized_up_to = current_block - @confirmation_depth
      next_to_submit  = state.last_submitted + 1

      if finalized_up_to >= next_to_submit do
        Enum.reduce(next_to_submit..finalized_up_to, state, fn block_num, acc ->
          submit_block(block_num, acc)
        end)
      else
        state
      end
    else
      {:error, reason} ->
        Logger.warning("BlockHashReporter: anvil_block_number failed: #{inspect(reason)}")
        state
    end
  end

  defp submit_block(block_num, state) do
    case get_block_hash(block_num) do
      {:ok, block_hash} ->
        case Contract.submit_block_hash(block_num, block_hash) do
          {:ok, _tx_hash} ->
            Logger.info("BlockHashReporter: submitted block=#{block_num} hash=#{block_hash}")
            %{state | last_submitted: block_num}

          {:error, reason} ->
            Logger.warning("BlockHashReporter: submit failed block=#{block_num}: #{inspect(reason)}")
            state
        end

      {:error, reason} ->
        Logger.warning("BlockHashReporter: get_block_hash failed block=#{block_num}: #{inspect(reason)}")
        state
    end
  end

  defp get_block_hash(block_num) do
    anvil_url = Application.get_env(:bharat_core, :anvil_http_url) ||
                raise "anvil_http_url not configured"
    block_hex = "0x" <> Integer.to_string(block_num, 16)
    body = Jason.encode!(%{
      jsonrpc: "2.0", id: 1,
      method: "eth_getBlockByNumber",
      params: [block_hex, false]
    })
    case Req.post(anvil_url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => %{"hash" => hash}}}} -> {:ok, hash}
      {:ok, %{body: %{"result" => nil}}}               -> {:error, :block_not_found}
      {:ok, %{body: %{"error" => err}}}                -> {:error, err}
      {:error, reason}                                 -> {:error, reason}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
