defmodule BharatRelayer.V2Worker do
  @moduledoc """
  Base behaviour for POC v2 hub-and-spoke relayer workers (R1, R2, R3).
  Polls all confirmed POC v2 transfers (cbdc_to_stablecoin, token_to_instruction,
  asset_to_instruction), signs the approval message, and submits to HubRouter.

  Signing scheme per transfer_type:
    token_to_token:       sign(eth_sign_hash(keccak256(to ++ amount_wei ++ nonce_hash)))
    token_to_instruction: sign(eth_sign_hash(keccak256(to ++ keccak256(payload) ++ nonce_hash)))
    asset_to_instruction: sign(eth_sign_hash(keccak256(to ++ contract ++ tokenId ++ keccak256(payload) ++ nonce_hash)))
  """

  require Logger

  alias BharatData.Transfers
  alias BharatRelayer.HubRouter

  @wei_per_token Decimal.new("1000000000000000000")

  @v2_directions ~w(cbdc_to_stablecoin token_to_instruction asset_to_instruction)

  defmacro __using__(opts) do
    relayer_idx     = Keyword.fetch!(opts, :relayer_idx)
    private_key_env = Keyword.fetch!(opts, :private_key_env)
    worker_name     = Keyword.fetch!(opts, :name)

    quote do
      use GenServer
      require Logger

      @relayer_idx     unquote(relayer_idx)
      @private_key_env unquote(private_key_env)
      @poll_interval_ms 5_000

      def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: unquote(worker_name))

      @impl true
      def init(state) do
        schedule_poll()
        {:ok, state}
      end

      @impl true
      def handle_info(:poll, state) do
        BharatRelayer.V2Worker.process_confirmed_transfers(@relayer_idx, private_key())
        schedule_poll()
        {:noreply, state}
      end

      defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

      defp private_key do
        Application.get_env(:bharat_core, @private_key_env) ||
          raise "#{@private_key_env} not configured"
      end
    end
  end

  # ── Shared logic called by all 3 workers ─────────────────────────────────

  def process_confirmed_transfers(relayer_idx, private_key_hex) do
    confirmed = Transfers.get_confirmed_pending_relay()
    v2 = Enum.filter(confirmed, &(&1.direction in @v2_directions))
    Enum.each(v2, fn transfer -> sign_and_submit(transfer, relayer_idx, private_key_hex) end)
  end

  defp sign_and_submit(transfer, relayer_idx, private_key_hex) do
    message_hash = build_message(transfer)
    eth_hash     = eth_sign_hash(message_hash)
    private_key  = decode_hex(private_key_hex)

    case ExSecp256k1.sign_compact(eth_hash, private_key) do
      {:ok, {sig_bytes, recovery_id}} ->
        <<r::binary-32, s::binary-32>> = sig_bytes
        signature = r <> s <> <<recovery_id + 27>>

        case HubRouter.submit_approval(transfer.id, relayer_idx, signature) do
          :ok                          -> Logger.info("V2 Relayer #{relayer_idx}: submitted approval for #{transfer.id}")
          {:error, :already_submitted} -> :ok
          {:error, reason}             -> Logger.warning("V2 Relayer #{relayer_idx}: submit failed #{transfer.id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("V2 Relayer #{relayer_idx}: sign failed for #{transfer.id}: #{inspect(reason)}")
    end
  end

  defp build_message(transfer) do
    case transfer.transfer_type do
      "token_to_token" ->
        amount_wei = Decimal.mult(transfer.amount, @wei_per_token)
        HubRouter.build_message(transfer.wallet, amount_wei, transfer.nonce_hash)

      "token_to_instruction" ->
        HubRouter.build_instruction_message(
          transfer.wallet,
          transfer.instruction_payload,
          transfer.nonce_hash
        )

      "asset_to_instruction" ->
        HubRouter.build_asset_instruction_message(
          transfer.wallet,
          transfer.asset_contract,
          transfer.asset_token_id,
          transfer.instruction_payload,
          transfer.nonce_hash
        )

      _ ->
        # Fallback: treat as token_to_token
        amount_wei = Decimal.mult(transfer.amount, @wei_per_token)
        HubRouter.build_message(transfer.wallet, amount_wei, transfer.nonce_hash)
    end
  end

  # "\x19Ethereum Signed Message:\n32" prefix (EIP-191)
  defp eth_sign_hash(message_hash) do
    ExKeccak.hash_256(<<0x19>> <> "Ethereum Signed Message:\n32" <> message_hash)
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex),          do: Base.decode16!(hex, case: :mixed)
end
