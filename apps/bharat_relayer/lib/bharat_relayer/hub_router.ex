defmodule BharatRelayer.HubRouter do
  @moduledoc """
  Collects 2-of-3 relayer approvals for all POC v2 transfer types.
  Routes to the correct on-chain execution function based on transfer_type:
    - token_to_token      → Contract.mint_with_approvals
    - token_to_instruction → Contract.execute_token_instruction
    - asset_to_instruction → Contract.execute_asset_instruction

  Signing schemes (all use EIP-191 eth_sign_hash wrapper):
    TOKEN_TO_TOKEN:       keccak256(to ++ amount_wei ++ nonce_hash)
    TOKEN_TO_INSTRUCTION: keccak256(to ++ keccak256(payload) ++ nonce_hash)
    ASSET_TO_INSTRUCTION: keccak256(to ++ token_contract ++ token_id ++ keccak256(payload) ++ nonce_hash)
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatData.Transfers
  alias BharatCore.Bridge.TransferServer

  @threshold 2
  @wei_per_token Decimal.new("1000000000000000000")

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def submit_approval(transfer_id, relayer_idx, signature) do
    GenServer.call(__MODULE__, {:submit_approval, transfer_id, relayer_idx, signature})
  end

  @doc "Build message for TOKEN_TO_TOKEN: keccak256(to ++ amount_wei ++ nonce_hash)"
  def build_message(to_wallet, amount_wei, nonce_hash_hex) do
    to_bytes     = decode_hex(to_wallet) |> pad_left(20)
    amount_bytes = <<Decimal.to_integer(amount_wei)::big-unsigned-integer-256>>
    nonce_bytes  = decode_hex(nonce_hash_hex)
    ExKeccak.hash_256(to_bytes <> amount_bytes <> nonce_bytes)
  end

  @doc "Build message for TOKEN_TO_INSTRUCTION: keccak256(to ++ keccak256(payload) ++ nonce_hash)"
  def build_instruction_message(to_wallet, payload_hex, nonce_hash_hex) do
    to_bytes      = decode_hex(to_wallet) |> pad_left(20)
    payload_bytes = decode_hex(payload_hex)
    payload_hash  = ExKeccak.hash_256(payload_bytes)
    nonce_bytes   = decode_hex(nonce_hash_hex)
    ExKeccak.hash_256(to_bytes <> payload_hash <> nonce_bytes)
  end

  @doc "Build message for ASSET_TO_INSTRUCTION: keccak256(to ++ token_contract ++ token_id ++ keccak256(payload) ++ nonce_hash)"
  def build_asset_instruction_message(to_wallet, token_contract, token_id, payload_hex, nonce_hash_hex) do
    to_bytes       = decode_hex(to_wallet) |> pad_left(20)
    contract_bytes = decode_hex(token_contract) |> pad_left(20)
    id_bytes       = <<token_id::big-unsigned-integer-256>>
    payload_bytes  = decode_hex(payload_hex)
    payload_hash   = ExKeccak.hash_256(payload_bytes)
    nonce_bytes    = decode_hex(nonce_hash_hex)
    ExKeccak.hash_256(to_bytes <> contract_bytes <> id_bytes <> payload_hash <> nonce_bytes)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:submit_approval, transfer_id, relayer_idx, signature}, _from, approvals) do
    existing = Map.get(approvals, transfer_id, [])

    if Enum.any?(existing, fn {idx, _} -> idx == relayer_idx end) do
      {:reply, {:error, :already_submitted}, approvals}
    else
      updated  = [{relayer_idx, signature} | existing]
      approvals = Map.put(approvals, transfer_id, updated)

      if length(updated) >= @threshold do
        Logger.info("HubRouter: threshold reached for #{transfer_id}")
        sigs = Enum.map(updated, fn {_, sig} -> sig end)
        trigger_execution(transfer_id, sigs)
        {:reply, :ok, Map.delete(approvals, transfer_id)}
      else
        Logger.debug("HubRouter: #{length(updated)}/#{@threshold} approvals for #{transfer_id}")
        {:reply, :ok, approvals}
      end
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────────

  defp trigger_execution(transfer_id, signatures) do
    case Transfers.get(transfer_id) do
      nil ->
        Logger.error("HubRouter: transfer #{transfer_id} not found")

      transfer ->
        result = execute_for_type(transfer, signatures)
        handle_execution_result(transfer_id, result)
    end
  end

  defp execute_for_type(transfer, signatures) do
    case transfer.transfer_type do
      "token_to_token" ->
        amount_wei = Decimal.mult(transfer.amount, @wei_per_token)
        Contract.mint_with_approvals(transfer.wallet, amount_wei, transfer.nonce_hash, signatures)

      "token_to_instruction" ->
        Contract.execute_token_instruction(
          transfer.wallet,
          transfer.nonce_hash,
          transfer.instruction_payload,
          signatures
        )

      "asset_to_instruction" ->
        Contract.execute_asset_instruction(
          transfer.wallet,
          transfer.asset_contract,
          transfer.asset_token_id,
          transfer.nonce_hash,
          transfer.instruction_payload,
          signatures
        )

      unknown ->
        {:error, "unknown transfer_type: #{unknown}"}
    end
  end

  defp handle_execution_result(transfer_id, {:ok, tx_hash}) do
    Transfers.update_state(transfer_id, "minted", %{mint_tx_hash: tx_hash})
    TransferServer.on_minted(transfer_id, tx_hash)
    Logger.info("HubRouter: executed transfer #{transfer_id} tx=#{tx_hash}")
  end

  defp handle_execution_result(transfer_id, {:error, reason}) do
    Transfers.increment_relay_attempts(transfer_id)
    Transfers.update_state(transfer_id, "failed", %{
      failure_reason: "hub execution failed: #{inspect(reason)}"
    })
    Logger.error("HubRouter: execution failed for #{transfer_id}: #{inspect(reason)}")
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex),          do: Base.decode16!(hex, case: :mixed)

  defp pad_left(bin, size) when byte_size(bin) < size do
    :binary.copy(<<0>>, size - byte_size(bin)) <> bin
  end
  defp pad_left(bin, _size), do: bin
end
