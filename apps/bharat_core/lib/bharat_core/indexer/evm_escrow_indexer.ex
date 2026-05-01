defmodule BharatCore.Indexer.EVMEscrowIndexer do
  @moduledoc """
  Indexes TokensLockedForZone events from EVMEscrow contract on Amoy.
  Mirrors BlockchainIndexer pattern with 12-block confirmation depth.
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatCore.Bridge.TransferServer
  alias BharatData.{Transfers, IndexerCheckpoints}

  @confirmation_depth 12
  @poll_interval_ms   3_000
  @chain              "amoy_evm_escrow"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :start)
    {:ok, %{pending: %{}, current_block: 0}}
  end

  @impl true
  def handle_info(:start, state) do
    last    = IndexerCheckpoints.get_last_block(@chain)
    {:ok, current} = Contract.current_block_number()
    from    = if last == 0, do: max(0, current - 1000), else: last + 1
    backfill(from, current)
    IndexerCheckpoints.update_last_block_for_chain(@chain, current)
    schedule_poll()
    {:noreply, %{state | current_block: current}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    case Contract.current_block_number() do
      {:ok, latest} when latest > state.current_block ->
        case Contract.get_evm_escrow_logs(state.current_block + 1, latest) do
          {:ok, logs} ->
            state =
              Enum.reduce(logs, state, fn raw, acc ->
                case parse_lock_for_zone(raw) do
                  {:ok, event} ->
                    put_in(acc.pending[event.transfer_id], {event, event.block_number})
                  :skip -> acc
                end
              end)

            state = promote_confirmed(state, latest)
            IndexerCheckpoints.update_last_block_for_chain(@chain, latest)
            %{state | current_block: latest}

          {:error, e} ->
            Logger.error("EVMEscrowIndexer getLogs failed: #{inspect(e)}")
            state
        end

      _ -> state
    end
  end

  defp promote_confirmed(state, current_block) do
    {to_confirm, still_pending} =
      Enum.split_with(state.pending, fn {_k, {_ev, block}} ->
        current_block - block >= @confirmation_depth
      end)

    Enum.each(to_confirm, fn {_k, {event, block}} ->
      Logger.info("EVMEscrowIndexer: confirmed #{Base.encode16(event.transfer_id)} at block #{block}")
      Transfers.confirm_evm_escrow_lock(event)
      TransferServer.on_confirmed(event.transfer_id, block)
    end)

    %{state | pending: Map.new(still_pending)}
  end

  defp parse_lock_for_zone(raw_log) do
    # TokensLockedForZone(bytes32 indexed transferId, address indexed token,
    #   uint256 amount, address sender, string destinationZone,
    #   bytes32 destinationAddress, bytes metadata)
    # topics[1] = transferId (indexed), data = amount+sender+offsets+destAddr+...
    try do
      [_sig, transfer_id_hex | _] = raw_log["topics"]
      data = Base.decode16!(String.trim_leading(raw_log["data"], "0x"), case: :mixed)

      <<amount_bin::binary-32,
        _sender_padded::binary-32,
        _zone_offset::binary-32,
        dest_addr::binary-32,
        _rest::binary>> = data

      amount = :binary.decode_unsigned(amount_bin)
      transfer_id_raw = Base.decode16!(String.trim_leading(transfer_id_hex, "0x"), case: :mixed)
      block_number = String.to_integer(String.trim_leading(raw_log["blockNumber"], "0x"), 16)

      {:ok, %{
        transfer_id:         transfer_id_raw,
        amount:              amount,
        destination_address: dest_addr,
        block_number:        block_number
      }}
    rescue
      _ -> :skip
    end
  end

  defp backfill(from, to) when from > to, do: :ok
  defp backfill(from, to) do
    batch = min(from + 499, to)
    case Contract.get_evm_escrow_logs(from, batch) do
      {:ok, logs} ->
        Enum.each(logs, fn raw ->
          case parse_lock_for_zone(raw) do
            {:ok, event} -> Transfers.confirm_evm_escrow_lock(event)
            :skip -> :ok
          end
        end)
      {:error, e} ->
        Logger.error("EVMEscrowIndexer backfill failed: #{inspect(e)}")
    end
    backfill(batch + 1, to)
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
