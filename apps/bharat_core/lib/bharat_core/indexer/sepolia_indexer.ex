defmodule BharatCore.Indexer.SepoliaIndexer do
  @moduledoc """
  Sepolia event indexer for the Sepolia→Amoy return bridge.
  Polls Sepolia for TokensBurned events from MintBridge every 3s.
  On confirmed burn: notifies TransferServer to proceed with unlock on Amoy.
  """

  use GenServer
  require Logger

  alias BharatCore.Indexer.EventParser
  alias BharatCore.Bridge.TransferServer
  alias BharatData.{Transfers, IndexerCheckpoints}
  alias BharatAdapters.Blockchain.Contract

  @confirmation_depth Application.compile_env(:bharat_core, :confirmation_depth, 3)
  @backfill_batch_size 9
  @poll_interval_ms 3_000
  @chain "sepolia"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :start)
    {:ok, %{pending: %{}, current_block: 0}}
  end

  @impl true
  def handle_info(:start, state) do
    state = run_backfill(state)
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_new_blocks(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Poll ──────────────────────────────────────────────────────────────────

  defp poll_new_blocks(state) do
    case Contract.sepolia_block_number() do
      {:ok, latest} when latest > state.current_block ->
        from = state.current_block + 1
        to   = latest

        state =
          case Contract.get_sepolia_logs(from, to) do
            {:ok, logs} ->
              Enum.reduce(logs, state, fn raw_log, acc ->
                case EventParser.parse(raw_log) do
                  {:tokens_burned, event} ->
                    Logger.debug("TokensBurned block=#{event.block_number} transfer=#{event.transfer_id}")
                    put_in(acc.pending[{event.nonce_hash, event.tx_hash}], {event, event.block_number})
                  _ -> acc
                end
              end)

            {:error, reason} ->
              Logger.error("Sepolia eth_getLogs #{from}..#{to} failed: #{inspect(reason)}")
              state
          end

        state = %{state | current_block: latest}
        state = promote_confirmed(state, latest)
        IndexerCheckpoints.update_last_block(latest, @chain)
        state

      {:ok, _same} -> state

      {:error, reason} ->
        Logger.error("Sepolia eth_blockNumber failed: #{inspect(reason)}")
        state
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  # ── Backfill ──────────────────────────────────────────────────────────────

  defp run_backfill(state) do
    case Contract.sepolia_block_number() do
      {:ok, current_block} ->
        last_saved = IndexerCheckpoints.get_last_block(@chain)

        from_block =
          if last_saved == 0,
            do: max(0, current_block - 1000),
            else: last_saved + 1

        if from_block < current_block do
          Logger.info("Sepolia indexer backfill: blocks #{from_block}..#{current_block}")
          backfill_range(from_block, current_block)
          IndexerCheckpoints.update_last_block(current_block, @chain)
        end

        %{state | current_block: current_block}

      {:error, reason} ->
        Logger.error("Sepolia backfill: could not get block number: #{inspect(reason)}")
        state
    end
  end

  defp backfill_range(from, to) when from > to, do: :ok

  defp backfill_range(from, to) do
    batch_to = min(from + @backfill_batch_size - 1, to)

    case Contract.get_sepolia_logs(from, batch_to) do
      {:ok, logs} ->
        Enum.each(logs, fn raw_log ->
          case EventParser.parse(raw_log) do
            {:tokens_burned, event} ->
              Logger.info("Sepolia backfill: confirming return transfer #{event.transfer_id}")
              TransferServer.on_confirmed(event.transfer_id, event.block_number)
            _ -> :skip
          end
        end)

      {:error, reason} ->
        Logger.error("Sepolia backfill get_logs #{from}..#{batch_to} failed: #{inspect(reason)}")
    end

    backfill_range(batch_to + 1, to)
  end

  # ── Confirmation depth ────────────────────────────────────────────────────

  defp promote_confirmed(state, current_block) do
    {to_confirm, still_pending} =
      Enum.split_with(state.pending, fn {_k, {_event, block}} ->
        current_block - block >= @confirmation_depth
      end)

    Enum.each(to_confirm, fn {_k, {event, block}} ->
      Logger.info("Sepolia confirmed: return transfer #{event.transfer_id} at block #{block}")
      TransferServer.on_confirmed(event.transfer_id, block)
    end)

    %{state | pending: Map.new(still_pending)}
  end
end
