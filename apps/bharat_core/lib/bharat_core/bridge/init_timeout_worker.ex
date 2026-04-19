defmodule BharatCore.Bridge.InitTimeoutWorker do
  @moduledoc """
  Polls every 2 minutes and expires init transfers older than 10 minutes
  that have no lock_tx_hash (MetaMask was never confirmed).
  """

  use GenServer
  require Logger

  alias BharatData.Transfers

  @poll_interval_ms 120_000
  @cutoff_seconds   600

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    expired = Transfers.expire_stale_init_transfers(@cutoff_seconds)
    if expired > 0 do
      Logger.info("InitTimeoutWorker: expired #{expired} stale init transfer(s)")
    end
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
