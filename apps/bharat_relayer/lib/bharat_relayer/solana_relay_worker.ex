defmodule BharatRelayer.SolanaRelayWorker do
  @moduledoc """
  Relayer for EVM → Solana transfers.
  Polls confirmed evm_to_solana transfers, submits release_to_beneficiary to Solana EscrowProgram.
  Uses Node.js port (SolanaPortClient) for Solana tx signing.
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.SolanaPortClient

  @poll_interval_ms 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    process_pending_transfers()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)

  defp process_pending_transfers do
    Transfers.get_confirmed_evm_to_solana()
    |> Enum.each(&submit_release/1)
  end

  defp submit_release(transfer) do
    Logger.info("SolanaRelayWorker: processing transfer #{transfer.id}")

    with {:ok, spl_amount}  <- normalize_amount(transfer.amount),
         {:ok, tx_sig}      <- call_release_instruction(transfer, spl_amount) do
      Logger.info("SolanaRelayWorker: released transfer=#{transfer.id} sig=#{tx_sig}")
      Transfers.update_solana_released(transfer.id, tx_sig, nil)
      BharatCore.Bridge.TransferServer.on_solana_released(transfer.id, tx_sig, nil)
    else
      {:error, reason} ->
        Logger.warning("SolanaRelayWorker: release failed #{transfer.id}: #{inspect(reason)}")
    end
  end

  # 18-decimal EVM amount → 6-decimal SPL amount
  defp normalize_amount(amount_decimal) do
    amount_wei = Decimal.to_integer(amount_decimal)
    spl_amount = div(amount_wei, 1_000_000_000_000)
    if spl_amount > 0, do: {:ok, spl_amount}, else: {:error, :below_minimum}
  end

  defp call_release_instruction(transfer, spl_amount) do
    program_id   = Application.get_env(:bharat_core, :solana_escrow_program)
    reserve_pool = Application.get_env(:bharat_core, :solana_reserve_pool)
    keypair_json = Application.get_env(:bharat_core, :relayer_solana_keypair)

    beneficiary_pubkey = Base58.encode(transfer.destination_address)

    transfer_id_hex =
      (transfer.lock_tx_hash || transfer.nonce_hash)
      |> String.trim_leading("0x")

    payload = Jason.encode!(%{
      program_id:         program_id,
      reserve_pool:       reserve_pool,
      beneficiary_pubkey: beneficiary_pubkey,
      transfer_id_hex:    transfer_id_hex,
      amount:             spl_amount,
      evm_sender:         transfer.wallet,
      source_zone:        "evm:amoy",
      keypair_json:       keypair_json
    })

    case SolanaPortClient.call("release", payload) do
      {:ok, %{"signature" => sig}} -> {:ok, sig}
      {:ok, %{"error" => err}}     -> {:error, err}
      {:error, reason}             -> {:error, reason}
    end
  end
end
