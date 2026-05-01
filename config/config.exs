import Config

config :bharat_web, BharatWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: BharatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BharatSetu.PubSub,
  live_view: [signing_salt: "bharat_setu_lv"]

config :bharat_core,
  confirmation_depth: 12,
  solana_rpc_url: System.get_env("SOLANA_RPC_URL", "https://api.devnet.solana.com"),
  solana_escrow_program: System.get_env("SOLANA_ESCROW_PROGRAM_ID"),
  solana_reserve_pool:   System.get_env("SOLANA_RESERVE_POOL_PUBKEY"),
  winrx_mint:            System.get_env("WINRX_MINT_PUBKEY"),
  relayer_solana_keypair: System.get_env("RELAYER_SOLANA_KEYPAIR_JSON"),
  evm_escrow_contract:   System.get_env("EVM_ESCROW_CONTRACT")

config :bharat_adapters,
  kyc_adapter: BharatAdapters.KYC.MockClient,
  registry_adapter: BharatAdapters.Registry.MockStrategy

config :bharat_data,
  ecto_repos: [BharatData.Repo]

config :bharat_data, BharatData.Repo,
  migration_primary_key: [type: :uuid],
  migration_timestamps: [type: :utc_datetime_usec]

config :bharat_web, BharatWeb.Auth.Guardian,
  issuer: "bharat_setu"

import_config "#{config_env()}.exs"
