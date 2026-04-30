defmodule BharatCore.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Distributed cache (ETS-backed)
      {Cachex, name: :price_cache},

      # Phoenix PubSub — intra-node messaging
      {Phoenix.PubSub, name: BharatSetu.PubSub},

      # Redis connection
      {Redix, name: :redix, host: "localhost", port: 6379},

      # Process registry for TransferServer lookup by transfer_id
      {Registry, keys: :unique, name: BharatCore.Bridge.Registry},

      # Task supervisor for async work inside FSM
      {Task.Supervisor, name: BharatCore.TaskSupervisor},

      # Pricing service — self-healing GenServer with ETS cache
      BharatCore.Pricing.PriceAggregator,

      # Amoy indexer — polls TokensLocked events for Amoy→Sepolia
      BharatCore.Indexer.BlockchainIndexer,

      # Sepolia indexer — polls TokensBurned events for Sepolia→Amoy
      BharatCore.Indexer.SepoliaIndexer,

      # Anvil indexer — polls CBDCLocked events for cbdc_to_stablecoin (POC v2)
      BharatCore.Indexer.AnvilIndexer,

      # Expires init transfers with no tx hash older than 10 min
      BharatCore.Bridge.InitTimeoutWorker,

      # Bridge supervisor — one TransferServer per in-flight transfer
      {DynamicSupervisor, name: BharatCore.Bridge.Supervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: BharatCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
