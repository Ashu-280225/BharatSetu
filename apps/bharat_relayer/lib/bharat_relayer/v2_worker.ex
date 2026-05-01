defmodule BharatRelayer.V2Worker do
  @moduledoc """
  Base behaviour for POC v2 hub-and-spoke relayer workers (R1, R2, R3).

  Polls confirmed POC v2 transfers and submits MPT receipt proofs to
  StablecoinBridge.executeWithProof() on Amoy instead of ECDSA signatures.

  Security model:
  - Workers share block hash submission duty (BlockHashReporter handles that).
  - Once BlockHashOracle finalizes a block hash, any worker can submit the proof.
  - Only one worker needs to succeed — the others will fail with NonceAlreadyUsed,
    which is treated as a success (transfer already executed).
  """

  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.{Contract, ProofBuilder}

  @v2_directions ~w(cbdc_to_stablecoin token_to_instruction asset_to_instruction)

  # Topic hashes for CBDCLocked and AssetLocked on Anvil
  @cbdc_locked_topic  "0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8"
  @asset_locked_topic "0xfebbc5c036aa2aa6ef382b492327c08033496d19d1286f732900cb5d618a70d4"

  defmacro __using__(opts) do
    worker_name = Keyword.fetch!(opts, :name)

    quote do
      use GenServer
      require Logger

      @poll_interval_ms 6_000

      def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: unquote(worker_name))

      @impl true
      def init(state) do
        schedule_poll()
        {:ok, state}
      end

      @impl true
      def handle_info(:poll, state) do
        BharatRelayer.V2Worker.process_confirmed_transfers()
        schedule_poll()
        {:noreply, state}
      end

      defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
    end
  end

  # ── Shared logic ──────────────────────────────────────────────────────────

  def process_confirmed_transfers do
    confirmed = Transfers.get_confirmed_pending_relay()
    v2 = Enum.filter(confirmed, &(&1.direction in @v2_directions))
    Enum.each(v2, &submit_proof/1)
  end

  defp submit_proof(transfer) do
    topic = event_topic_for(transfer.direction)

    case ProofBuilder.build(transfer.lock_tx_hash, topic) do
      {:ok, proof_data} ->
        case Contract.execute_with_proof(proof_data) do
          {:ok, tx_hash} ->
            Logger.info("V2Worker: proof submitted transfer=#{transfer.id} tx=#{tx_hash}")

          {:error, %{"message" => msg}} when is_binary(msg) ->
            if String.contains?(msg, "NonceAlreadyUsed") do
              # Another worker already executed — treat as success
              Logger.info("V2Worker: transfer already executed #{transfer.id}")
            else
              Logger.warning("V2Worker: proof submission failed #{transfer.id}: #{msg}")
            end

          {:error, reason} ->
            Logger.warning("V2Worker: proof submission failed #{transfer.id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("V2Worker: proof build failed #{transfer.id}: #{inspect(reason)}")
    end
  end

  defp event_topic_for(direction) when direction in ["cbdc_to_stablecoin", "token_to_instruction"] do
    @cbdc_locked_topic
  end
  defp event_topic_for("asset_to_instruction"), do: @asset_locked_topic
end
