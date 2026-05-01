defmodule BharatRelayer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Solana port (Node.js signer) — must start before SolanaRelayWorker
      BharatAdapters.Blockchain.SolanaPortClient,

      # EVM→Solana relay worker
      BharatRelayer.SolanaRelayWorker,

      # POC v1 — amoy↔sepolia single relayer
      BharatRelayer.Worker,
      # POC v2 — block hash reporters (one per relayer address, threshold=2-of-3 in oracle)
      {BharatRelayer.BlockHashReporter, name: BharatRelayer.BlockHashReporterR1},
      {BharatRelayer.BlockHashReporter, name: BharatRelayer.BlockHashReporterR2},
      {BharatRelayer.BlockHashReporter, name: BharatRelayer.BlockHashReporterR3},
      # POC v2 — proof submitters (any one succeeds, others get NonceAlreadyUsed)
      BharatRelayer.V2WorkerR1,
      BharatRelayer.V2WorkerR2,
      BharatRelayer.V2WorkerR3
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BharatRelayer.Supervisor)
  end
end
