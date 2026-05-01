defmodule BharatCore.Indexer.SolanaIndexer do
  @moduledoc """
  Solana event indexer for EscrowProgram on devnet.
  Polls getSignaturesForAddress — checkpoints last seen signature.
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.SolanaRpc
  alias BharatData.IndexerCheckpoints

  @poll_interval_ms 1_000
  @finality_slots   32
  @chain            "solana_devnet"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :poll)
    {:ok, %{last_sig: IndexerCheckpoints.get_last_sig(@chain)}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    program_id = Application.get_env(:bharat_core, :solana_escrow_program)

    opts = [limit: 50, commitment: "finalized"]
    opts = if state.last_sig, do: opts ++ [until: state.last_sig], else: opts

    case SolanaRpc.get_signatures_for_address(program_id, opts) do
      {:ok, []} ->
        state

      {:ok, sigs} ->
        # Signatures come newest-first — process oldest-first
        finalized =
          sigs
          |> Enum.reverse()
          |> Enum.filter(&finalized?(&1["slot"]))

        Enum.each(finalized, &process_sig/1)

        newest_sig = List.first(sigs)["signature"]
        IndexerCheckpoints.update_last_sig(@chain, newest_sig)
        %{state | last_sig: newest_sig}

      {:error, reason} ->
        Logger.error("SolanaIndexer poll failed: #{inspect(reason)}")
        state
    end
  end

  defp finalized?(slot) when is_integer(slot) do
    case SolanaRpc.get_slot("finalized") do
      {:ok, current} -> current >= slot + @finality_slots
      _ -> false
    end
  end
  defp finalized?(_), do: false

  defp process_sig(%{"signature" => sig, "err" => nil}) do
    case SolanaRpc.get_transaction(sig) do
      {:ok, tx} -> parse_and_dispatch(tx, sig)
      {:error, reason} ->
        Logger.warning("SolanaIndexer: get_transaction #{sig} failed: #{inspect(reason)}")
    end
  end
  defp process_sig(%{"err" => err, "signature" => sig}) when not is_nil(err) do
    Logger.debug("SolanaIndexer: skipping failed tx #{sig}")
  end

  defp parse_and_dispatch(tx, sig) do
    logs = get_in(tx, ["meta", "logMessages"]) || []

    Enum.each(logs, fn log ->
      case parse_log(log) do
        {:released, transfer_id_hex, solana_slot} ->
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: EscrowReleased transfer=#{transfer_id_hex} sig=#{sig}")
          BharatCore.Bridge.TransferServer.on_solana_released(transfer_id, sig, solana_slot)

        :skip ->
          :ok
      end
    end)
  end

  # Anchor emits events as base64 logs: "Program data: <b64>"
  # EscrowReleased: 8-byte discriminator + [u8;32] transfer_id + Pubkey + u64
  defp parse_log("Program data: " <> b64) do
    case Base.decode64(b64) do
      {:ok, <<_disc::binary-8, transfer_id::binary-32, _rest::binary>>} ->
        hex = Base.encode16(transfer_id, case: :lower)
        {:released, hex, nil}
      _ ->
        :skip
    end
  end
  defp parse_log(_), do: :skip
end
