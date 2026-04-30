defmodule BharatRelayer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # POC v1 — amoy↔sepolia single relayer
      BharatRelayer.Worker,
      # POC v2 — hub-and-spoke 2-of-3 threshold relayers
      BharatRelayer.HubRouter,
      BharatRelayer.V2WorkerR1,
      BharatRelayer.V2WorkerR2,
      BharatRelayer.V2WorkerR3
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BharatRelayer.Supervisor)
  end
end
