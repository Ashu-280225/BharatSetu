defmodule BharatRelayer.SolanaToEvmWorker do
  @moduledoc """
  Reverse token flow: Solana → EVM.
  Polls confirmed solana_to_evm transfers and calls EVMEscrow.unlockFromZone
  to release original ERC-20 tokens to the destination EVM wallet.
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.Contract
  alias BharatCore.Bridge.TransferServer

  @poll_interval_ms 5_000
  @max_relay_attempts 3
  @wei_per_token Decimal.new("1000000000000000000")

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    process_pending()
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp process_pending do
    Transfers.get_confirmed_solana_to_evm()
    |> Enum.each(&relay_to_evm/1)
  end

  defp relay_to_evm(transfer) do
    Logger.info("SolanaToEvmWorker: processing transfer #{transfer.id} (attempt #{transfer.relay_attempts + 1})")

    amount_wei = Decimal.mult(transfer.amount, @wei_per_token)

    case Contract.unlock_from_zone(transfer.wallet, transfer.token_address, amount_wei, transfer.nonce_hash) do
      {:ok, tx_hash} ->
        Transfers.update_state(transfer.id, "minted", %{mint_tx_hash: tx_hash})
        TransferServer.on_minted(transfer.id, tx_hash)
        Logger.info("SolanaToEvmWorker: unlocked transfer #{transfer.id} tx=#{tx_hash}")

      {:error, reason} ->
        Transfers.increment_relay_attempts(transfer.id)
        new_attempts = transfer.relay_attempts + 1

        if new_attempts >= @max_relay_attempts do
          Transfers.update_state(transfer.id, "failed", %{
            failure_reason: "solana_to_evm relay failed after #{new_attempts} attempts: #{inspect(reason)}"
          })
          Logger.error("SolanaToEvmWorker: transfer #{transfer.id} FAILED after #{new_attempts} attempts")
        else
          Logger.warning("SolanaToEvmWorker: transfer #{transfer.id} attempt #{new_attempts} failed: #{inspect(reason)}")
        end
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
