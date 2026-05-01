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

  # Anchor event discriminators (first 8 bytes of sha256("event:<EventName>"))
  # Generate with: python3 -c "import hashlib; print(hashlib.sha256(b'event:EscrowReleased').digest()[:8].hex())"
  # These must match the Rust program definitions exactly.
  @disc_escrow_released  <<0x98, 0x3A, 0x6D, 0x2E, 0xB7, 0x5C, 0x11, 0xAF>>
  @disc_tokens_locked    <<0x1B, 0x44, 0xA2, 0x9F, 0xC3, 0x87, 0x5E, 0xD0>>
  @disc_nft_locked       <<0x4C, 0x81, 0x37, 0xBB, 0xE9, 0x02, 0xDA, 0x56>>
  @disc_nft_minted       <<0x7F, 0xA3, 0xC5, 0x18, 0x6D, 0x44, 0x9B, 0x2C>>

  defp parse_and_dispatch(tx, sig) do
    logs = get_in(tx, ["meta", "logMessages"]) || []
    slot = get_in(tx, ["slot"])

    Enum.each(logs, fn log ->
      case parse_log(log) do
        {:released, transfer_id_hex} ->
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: EscrowReleased transfer=#{transfer_id_hex} sig=#{sig}")
          BharatCore.Bridge.TransferServer.on_solana_released(transfer_id, sig, slot)

        {:tokens_locked, transfer_id_hex} ->
          # Reverse token flow: user locked tokens on Solana → confirm Zone B state
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: TokensLocked (reverse) transfer=#{transfer_id_hex} sig=#{sig}")
          BharatCore.Bridge.TransferServer.on_confirmed(transfer_id, slot)

        {:nft_locked, transfer_id_hex} ->
          # Reverse NFT flow: wrapped NFT locked on Solana → confirm Zone B state
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: NFTLocked (reverse) transfer=#{transfer_id_hex} sig=#{sig}")
          BharatCore.Bridge.TransferServer.on_confirmed(transfer_id, slot)

        {:nft_minted, transfer_id_hex} ->
          # Forward NFT flow: wrapped NFT minted on Solana → mark complete
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: NFTMinted transfer=#{transfer_id_hex} sig=#{sig}")
          BharatCore.Bridge.TransferServer.on_solana_released(transfer_id, sig, slot)

        :skip ->
          :ok
      end
    end)
  end

  # Anchor emits events as base64 logs: "Program data: <b64>"
  # Layout: 8-byte discriminator + [u8;32] transfer_id + ...rest
  defp parse_log("Program data: " <> b64) do
    case Base.decode64(b64) do
      {:ok, <<@disc_escrow_released, transfer_id::binary-32, _rest::binary>>} ->
        {:released, Base.encode16(transfer_id, case: :lower)}

      {:ok, <<@disc_tokens_locked, transfer_id::binary-32, _rest::binary>>} ->
        {:tokens_locked, Base.encode16(transfer_id, case: :lower)}

      {:ok, <<@disc_nft_locked, transfer_id::binary-32, _rest::binary>>} ->
        {:nft_locked, Base.encode16(transfer_id, case: :lower)}

      {:ok, <<@disc_nft_minted, transfer_id::binary-32, _rest::binary>>} ->
        {:nft_minted, Base.encode16(transfer_id, case: :lower)}

      _ ->
        :skip
    end
  end
  defp parse_log(_), do: :skip
end
