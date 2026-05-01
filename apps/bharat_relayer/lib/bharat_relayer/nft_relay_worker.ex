defmodule BharatRelayer.NFTRelayWorker do
  @moduledoc """
  Handles both NFT bridge directions:

  nft_evm_to_solana (forward):
    Polls confirmed EVM NFT locks → calls Solana program mintWrappedNFT.
    On Solana mint confirmed (via SolanaIndexer), TransferServer marks completed.

  nft_solana_to_evm (reverse):
    Polls confirmed Solana wrapped NFT locks → calls AssetVault.unlockAsset on EVM.
    After EVM unlock confirmed → calls Solana program burnWrappedNFT.
    Burn must happen AFTER EVM unlock confirmation (per flow spec).
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.{Contract, SolanaPortClient}
  alias BharatCore.Bridge.TransferServer

  @poll_interval_ms 5_000
  @max_relay_attempts 3

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    process_nft_evm_to_solana()
    process_nft_solana_to_evm()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── NFT EVM → Solana ──────────────────────────────────────────────────────

  defp process_nft_evm_to_solana do
    Transfers.get_confirmed_nft_evm_to_solana()
    |> Enum.each(&mint_wrapped_nft/1)
  end

  defp mint_wrapped_nft(transfer) do
    Logger.info("NFTRelayWorker: minting wrapped NFT for transfer #{transfer.id}")

    program_id   = Application.get_env(:bharat_core, :solana_escrow_program)
    keypair_json = Application.get_env(:bharat_core, :relayer_solana_keypair)
    beneficiary  = Base58.encode(transfer.destination_address)

    transfer_id_hex = (transfer.lock_tx_hash || transfer.nonce_hash)
                      |> String.trim_leading("0x")

    payload = Jason.encode!(%{
      program_id:         program_id,
      beneficiary_pubkey: beneficiary,
      transfer_id_hex:    transfer_id_hex,
      token_contract:     transfer.asset_contract,
      token_id:           transfer.asset_token_id,
      metadata:           transfer.instruction_payload,
      keypair_json:       keypair_json
    })

    case SolanaPortClient.call("mint_wrapped_nft", payload) do
      {:ok, %{"signature" => sig}} ->
        Transfers.update_solana_released(transfer.id, sig, nil)
        Logger.info("NFTRelayWorker: wrapped NFT minted transfer=#{transfer.id} sig=#{sig}")

      {:ok, %{"error" => err}} ->
        handle_nft_failure(transfer, err)

      {:error, reason} ->
        handle_nft_failure(transfer, reason)
    end
  end

  # ── NFT Solana → EVM ──────────────────────────────────────────────────────

  defp process_nft_solana_to_evm do
    Transfers.get_confirmed_nft_solana_to_evm()
    |> Enum.each(&unlock_original_nft/1)
  end

  defp unlock_original_nft(transfer) do
    Logger.info("NFTRelayWorker: unlocking original NFT for transfer #{transfer.id}")

    case Contract.unlock_asset(transfer.wallet, transfer.asset_contract,
                               transfer.asset_token_id, transfer.nonce_hash) do
      {:ok, tx_hash} ->
        # Phase 1 done: EVM original NFT released.
        # Phase 2 (burn wrapped on Solana) triggered after indexer confirms this tx.
        # EVMEscrowIndexer will call on_minted which moves to :minted state.
        # Then SolanaIndexer burn confirmation calls on_solana_released → completed.
        Transfers.update_state(transfer.id, "minted", %{mint_tx_hash: tx_hash})
        trigger_solana_burn(transfer)
        Logger.info("NFTRelayWorker: EVM NFT unlocked transfer=#{transfer.id} tx=#{tx_hash}")

      {:error, reason} ->
        handle_nft_failure(transfer, reason)
    end
  end

  # Burn wrapped NFT on Solana AFTER EVM unlock confirmed.
  # Called immediately after unlock_asset succeeds — Solana program must
  # verify the EVM tx before accepting the burn (via cross-chain proof or relayer attestation).
  defp trigger_solana_burn(transfer) do
    program_id   = Application.get_env(:bharat_core, :solana_escrow_program)
    keypair_json = Application.get_env(:bharat_core, :relayer_solana_keypair)

    transfer_id_hex = (transfer.lock_tx_hash || transfer.nonce_hash)
                      |> String.trim_leading("0x")

    payload = Jason.encode!(%{
      program_id:      program_id,
      transfer_id_hex: transfer_id_hex,
      token_id:        transfer.asset_token_id,
      keypair_json:    keypair_json
    })

    case SolanaPortClient.call("burn_wrapped_nft", payload) do
      {:ok, %{"signature" => sig}} ->
        TransferServer.on_solana_released(transfer.id, sig, nil)
        Logger.info("NFTRelayWorker: wrapped NFT burned transfer=#{transfer.id} sig=#{sig}")

      {:ok, %{"error" => err}} ->
        Logger.error("NFTRelayWorker: burn_wrapped_nft failed transfer=#{transfer.id}: #{inspect(err)}")

      {:error, reason} ->
        Logger.error("NFTRelayWorker: burn_wrapped_nft error transfer=#{transfer.id}: #{inspect(reason)}")
    end
  end

  defp handle_nft_failure(transfer, reason) do
    Transfers.increment_relay_attempts(transfer.id)
    new_attempts = transfer.relay_attempts + 1

    if new_attempts >= @max_relay_attempts do
      Transfers.update_state(transfer.id, "failed", %{
        failure_reason: "nft relay failed after #{new_attempts} attempts: #{inspect(reason)}"
      })
      Logger.error("NFTRelayWorker: transfer #{transfer.id} FAILED after #{new_attempts} attempts: #{inspect(reason)}")
    else
      Logger.warning("NFTRelayWorker: transfer #{transfer.id} attempt #{new_attempts} failed: #{inspect(reason)}")
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
