# Implementation Plan: EVM → Solana (POC)

**Scope:** Lock INRX on Polygon Amoy → release wINRX to beneficiary on Solana Devnet  
**Trust model:** Hub relayer R1 single-sig (POC — add multisig later)  
**Reserve model:** Pre-minted wINRX pool in EscrowProgram (no mint-authority complexity for POC)

---

## Dependency Order

```
Step 1: DB migration            (no deps)
Step 2: EVMEscrow.sol           (no deps)
Step 3: Solana EscrowProgram    (no deps — parallel with Step 2)
Step 4: Deploy both contracts   (deps: Step 2, Step 3)
Step 5: Config + env vars       (deps: Step 4)
Step 6: Transfer schema update  (deps: Step 1)
Step 7: SolanaRpc adapter       (deps: Step 5)
Step 8: SolanaIndexer           (deps: Step 7)
Step 9: SolanaRelayWorker       (deps: Step 7, Step 6)
Step 10: TransferServer FSM     (deps: Step 6)
Step 11: TransferController     (deps: Step 10)
Step 12: Application supervisor (deps: Step 8, Step 9)
Step 13: Frontend               (deps: Step 11)
```

---

## Step 1 — DB Migration

**File:** `apps/bharat_data/priv/repo/migrations/<timestamp>_add_solana_fields_to_transfers.exs`

```elixir
defmodule BharatData.Repo.Migrations.AddSolanaFieldsToTransfers do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :destination_zone,    :string                  # "sol:devnet"
      add :destination_address, :binary                  # 32-byte Solana pubkey raw bytes
      add :solana_slot,         :bigint
      add :solana_tx_sig,       :string                  # base58 Solana tx signature
    end

    # Add "evm_to_solana" to direction check constraint
    # Drop old constraint, re-add with new value
    execute """
      ALTER TABLE transfers DROP CONSTRAINT IF EXISTS transfers_direction_check;
    """, ""

    execute """
      ALTER TABLE transfers ADD CONSTRAINT transfers_direction_check
        CHECK (direction IN (
          'amoy_to_sepolia','sepolia_to_amoy',
          'cbdc_to_stablecoin','stablecoin_to_cbdc',
          'token_to_instruction','asset_to_instruction',
          'evm_to_solana'
        ));
    """, ""
  end
end
```

Run: `mix ecto.migrate`

---

## Step 2 — EVMEscrow.sol (New Contract)

**File:** `contracts/src/EVMEscrow.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";
import "./utils/Ownable.sol";

contract EVMEscrow is Ownable {
    uint256 public constant TIMEOUT = 1 hours;
    uint256 public constant MIN_AMOUNT = 1e12;      // 1 SPL unit in 18-decimal terms

    address public relayer;
    bool    public paused;

    struct Lock {
        address token;
        uint256 amount;
        address sender;
        uint256 lockedAt;
        bool    released;
    }

    mapping(bytes32 => Lock) public locks;
    mapping(address => uint256) public nonces;

    event TokensLockedForZone(
        bytes32 indexed transferId,
        address indexed token,
        uint256 amount,
        address sender,
        string  destinationZone,
        bytes32 destinationAddress,   // Solana pubkey as raw 32 bytes
        bytes   metadata
    );
    event TokensUnlocked(bytes32 indexed transferId, address recipient, uint256 amount);
    event RefundIssued(bytes32 indexed transferId, address recipient, uint256 amount);

    modifier onlyRelayer() { require(msg.sender == relayer, "not relayer"); _; }
    modifier notPaused()   { require(!paused, "paused"); _; }

    constructor(address _relayer) { relayer = _relayer; }

    function lockForZone(
        address token,
        uint256 amount,
        string  calldata destinationZone,
        bytes32 destinationAddress,
        bytes   calldata metadata
    ) external notPaused {
        require(amount >= MIN_AMOUNT, "below minimum");

        // Round down to SPL precision — user keeps dust in wallet
        uint256 transferable = (amount / MIN_AMOUNT) * MIN_AMOUNT;

        // transferId derived from sender + nonce + chainId — collision-proof
        bytes32 transferId = keccak256(
            abi.encode(msg.sender, nonces[msg.sender]++, block.chainid)
        );

        IERC20(token).transferFrom(msg.sender, address(this), transferable);

        locks[transferId] = Lock({
            token:     token,
            amount:    transferable,
            sender:    msg.sender,
            lockedAt:  block.timestamp,
            released:  false
        });

        emit TokensLockedForZone(
            transferId, token, transferable, msg.sender,
            destinationZone, destinationAddress, metadata
        );
    }

    // Called by relayer after Solana release confirmed
    function unlockFromZone(
        address token,
        address recipient,
        uint256 amount,
        bytes32 transferId
    ) external onlyRelayer {
        Lock storage lock = locks[transferId];
        require(!lock.released, "already released");
        require(lock.token == token, "token mismatch");
        require(lock.amount == amount, "amount mismatch");

        lock.released = true;
        IERC20(token).transfer(recipient, amount);
        emit TokensUnlocked(transferId, recipient, amount);
    }

    // Permissionless refund — anyone can call after timeout
    function refundAfterTimeout(bytes32 transferId) external {
        Lock storage lock = locks[transferId];
        require(!lock.released, "already released");
        require(block.timestamp >= lock.lockedAt + TIMEOUT, "not timed out");

        lock.released = true;
        IERC20(lock.token).transfer(lock.sender, lock.amount);
        emit RefundIssued(transferId, lock.sender, lock.amount);
    }

    function setRelayer(address _relayer) external onlyOwner { relayer = _relayer; }
    function setPaused(bool _paused) external onlyOwner { paused = _paused; }
}
```

**Deploy script:** `contracts/script/DeployEVMEscrow.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "../src/EVMEscrow.sol";

contract DeployEVMEscrow is Script {
    function run() external {
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        vm.startBroadcast();
        EVMEscrow escrow = new EVMEscrow(relayer);
        console.log("EVMEscrow deployed:", address(escrow));
        vm.stopBroadcast();
    }
}
```

Run:
```bash
forge script contracts/script/DeployEVMEscrow.s.sol \
  --rpc-url $AMOY_RPC_URL --broadcast \
  --private-key $DEPLOYER_KEY
```

---

## Step 3 — Solana EscrowProgram (Anchor)

**New directory:** `contracts/solana/`

```
contracts/solana/
├── Anchor.toml
└── programs/
    └── escrow/
        ├── Cargo.toml
        └── src/
            ├── lib.rs
            ├── state.rs
            └── instructions/
                ├── release.rs
                └── refund.rs
```

**`Anchor.toml`:**
```toml
[features]
seeds = false
skip-lint = false

[programs.localnet]
escrow = "Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS"   # placeholder, update after deploy

[registry]
url = "https://api.apr.dev"

[provider]
cluster = "devnet"
wallet = "~/.config/solana/id.json"

[scripts]
test = "yarn run ts-mocha -p ./tsconfig.json -t 1000000 tests/**/*.ts"
```

**`programs/escrow/src/state.rs`:**
```rust
use anchor_lang::prelude::*;

#[account]
pub struct EscrowState {
    pub transfer_id:     [u8; 32],   // matches EVM bytes32 transferId
    pub source_zone:     [u8; 32],   // "evm:amoy" padded
    pub evm_sender:      [u8; 20],   // EVM sender address (20 bytes)
    pub beneficiary:     Pubkey,     // Solana recipient
    pub mint:            Pubkey,     // wINRX SPL token mint
    pub amount:          u64,        // SPL units (6 decimals)
    pub created_at:      i64,        // unix timestamp
    pub status:          EscrowStatus,
    pub bump:            u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum EscrowStatus { Locked, Released, Refunded }

impl EscrowState {
    pub const LEN: usize = 8   // discriminator
        + 32 + 32 + 20 + 32 + 32 + 8 + 8 + 1 + 1 + 32; // padding
}
```

**`programs/escrow/src/lib.rs`:**
```rust
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer as SplTransfer};

mod state;
mod instructions;
use state::*;
use instructions::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

// Hub relayer pubkey — hardcoded for POC, use multisig for production
const RELAYER_PUBKEY: &str = "YOUR_RELAYER_SOLANA_PUBKEY";

#[program]
pub mod escrow {
    use super::*;

    // Called by relayer after EVM lock confirmed — releases wINRX from reserve pool
    pub fn release_to_beneficiary(
        ctx: Context<ReleaseToBeneficiary>,
        transfer_id: [u8; 32],
        amount: u64,
        evm_sender: [u8; 20],
        source_zone: [u8; 32],
    ) -> Result<()> {
        instructions::release::handler(ctx, transfer_id, amount, evm_sender, source_zone)
    }

    // Permissionless timeout refund — refunds SPL tokens to escrow reserve
    // For reserve-pool model: no-op refund (just marks state — reserve stays in pool)
    pub fn mark_refunded(
        ctx: Context<MarkRefunded>,
        transfer_id: [u8; 32],
    ) -> Result<()> {
        instructions::refund::handler(ctx, transfer_id)
    }
}

#[derive(Accounts)]
#[instruction(transfer_id: [u8; 32])]
pub struct ReleaseToBeneficiary<'info> {
    // Relayer must sign this transaction
    #[account(mut, constraint = relayer.key().to_string() == RELAYER_PUBKEY)]
    pub relayer: Signer<'info>,

    // EscrowState PDA — initialized here (init) — prevents double-release via Anchor constraint
    #[account(
        init,
        payer = relayer,
        space = EscrowState::LEN,
        seeds = [b"escrow", transfer_id.as_ref()],
        bump
    )]
    pub escrow_state: Account<'info, EscrowState>,

    // Reserve pool token account owned by program (pre-funded wINRX)
    #[account(mut, constraint = reserve_pool.owner == program_id)]
    pub reserve_pool: Account<'info, TokenAccount>,

    // Beneficiary's token account for wINRX
    #[account(mut)]
    pub beneficiary_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
```

**`programs/escrow/src/instructions/release.rs`:**
```rust
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Transfer as SplTransfer};
use crate::state::*;
use crate::ReleaseToBeneficiary;

#[event]
pub struct EscrowReleased {
    pub transfer_id: [u8; 32],
    pub beneficiary: Pubkey,
    pub amount: u64,
}

pub fn handler(
    ctx: Context<ReleaseToBeneficiary>,
    transfer_id: [u8; 32],
    amount: u64,
    evm_sender: [u8; 20],
    source_zone: [u8; 32],
) -> Result<()> {
    let escrow = &mut ctx.accounts.escrow_state;
    let clock = Clock::get()?;

    escrow.transfer_id = transfer_id;
    escrow.source_zone = source_zone;
    escrow.evm_sender  = evm_sender;
    escrow.beneficiary = ctx.accounts.beneficiary_token_account.owner;
    escrow.mint        = ctx.accounts.reserve_pool.mint;
    escrow.amount      = amount;
    escrow.created_at  = clock.unix_timestamp;
    escrow.status      = EscrowStatus::Released;
    escrow.bump        = ctx.bumps.escrow_state;

    // Transfer wINRX from reserve pool to beneficiary
    // Program authority signs via seeds (reserve_pool owned by program)
    token::transfer(
        CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            SplTransfer {
                from:      ctx.accounts.reserve_pool.to_account_info(),
                to:        ctx.accounts.beneficiary_token_account.to_account_info(),
                authority: ctx.accounts.escrow_state.to_account_info(),  // PDA authority
            },
        ),
        amount,
    )?;

    emit!(EscrowReleased {
        transfer_id,
        beneficiary: ctx.accounts.beneficiary_token_account.owner,
        amount,
    });

    Ok(())
}
```

Build and deploy:
```bash
cd contracts/solana
anchor build
anchor deploy --provider.cluster devnet
```

Note the deployed program ID — update `Anchor.toml` and `declare_id!()`.

Pre-fund reserve pool:
```bash
spl-token create-token --decimals 6           # creates wINRX mint
spl-token create-account <MINT>               # reserve pool account
spl-token mint <MINT> 1000000 <RESERVE_ACCT>  # 1M wINRX
```

---

## Step 4 — Config & Env Vars

**`config/runtime.exs`** — add under existing EVM config:

```elixir
# Solana
config :bharat_core,
  solana_rpc_url:       System.get_env("SOLANA_RPC_URL", "https://api.devnet.solana.com"),
  solana_escrow_program: System.get_env("SOLANA_ESCROW_PROGRAM_ID") ||
                          raise("SOLANA_ESCROW_PROGRAM_ID required"),
  solana_reserve_pool:  System.get_env("SOLANA_RESERVE_POOL_PUBKEY") ||
                          raise("SOLANA_RESERVE_POOL_PUBKEY required"),
  winrx_mint:           System.get_env("WINRX_MINT_PUBKEY") ||
                          raise("WINRX_MINT_PUBKEY required"),
  relayer_solana_keypair: System.get_env("RELAYER_SOLANA_KEYPAIR_JSON") ||
                           raise("RELAYER_SOLANA_KEYPAIR_JSON required"),

# EVM
config :bharat_core,
  evm_escrow_contract:  System.get_env("EVM_ESCROW_CONTRACT") ||
                          raise("EVM_ESCROW_CONTRACT required")
```

**.env additions:**
```
SOLANA_RPC_URL=https://api.devnet.solana.com
SOLANA_ESCROW_PROGRAM_ID=<from anchor deploy>
SOLANA_RESERVE_POOL_PUBKEY=<reserve pool token account>
WINRX_MINT_PUBKEY=<wINRX mint address>
RELAYER_SOLANA_KEYPAIR_JSON=[1,2,3,...]   # keypair as JSON array
EVM_ESCROW_CONTRACT=0x<deployed EVMEscrow address>
```

---

## Step 5 — Transfer Schema Update

**`apps/bharat_data/lib/bharat_data/schemas/transfer.ex`**

```elixir
# Add to @valid_directions:
@valid_directions ~w(amoy_to_sepolia sepolia_to_amoy cbdc_to_stablecoin stablecoin_to_cbdc
                     token_to_instruction asset_to_instruction evm_to_solana)

# Add fields to schema block:
field :destination_zone,    :string    # "sol:devnet"
field :destination_address, :binary    # 32 raw bytes (Solana pubkey)
field :solana_slot,         :integer
field :solana_tx_sig,       :string    # base58 Solana tx signature

# Add to cast/2 in changeset:
|> cast(attrs, [...existing..., :destination_zone, :destination_address,
                :solana_slot, :solana_tx_sig])
```

**`apps/bharat_data/lib/bharat_data/transfers.ex`** — add query for Solana relayer:

```elixir
# Add alongside existing get_confirmed_pending_relay/0:
def get_confirmed_evm_to_solana do
  Transfer
  |> where([t], t.direction == "evm_to_solana" and t.state == "confirmed")
  |> where([t], t.solana_tx_sig |> is_nil())
  |> Repo.all()
end

def update_solana_released(transfer_id, solana_tx_sig, solana_slot) do
  from(t in Transfer, where: t.id == ^transfer_id)
  |> Repo.update_all(set: [
    state: "minted",
    solana_tx_sig: solana_tx_sig,
    solana_slot: solana_slot
  ])
end
```

---

## Step 6 — SolanaRpc Adapter

**New file:** `apps/bharat_adapters/lib/bharat_adapters/blockchain/solana_rpc.ex`

```elixir
defmodule BharatAdapters.Blockchain.SolanaRpc do
  @moduledoc "Solana JSON-RPC HTTP adapter (mirrors Contract.ex pattern)."

  require Logger

  def get_slot(commitment \\ "finalized") do
    case rpc("getSlot", [%{commitment: commitment}]) do
      {:ok, slot} when is_integer(slot) -> {:ok, slot}
      err -> err
    end
  end

  def get_signatures_for_address(address, opts \\ []) do
    params = [address, Map.new(opts)]
    case rpc("getSignaturesForAddress", params) do
      {:ok, sigs} when is_list(sigs) -> {:ok, sigs}
      err -> err
    end
  end

  def get_transaction(signature) do
    params = [signature, %{encoding: "jsonParsed", commitment: "finalized",
                           maxSupportedTransactionVersion: 0}]
    rpc("getTransaction", params)
  end

  def get_account_info(pubkey) do
    rpc("getAccountInfo", [pubkey, %{encoding: "base64", commitment: "finalized"}])
  end

  # Send a pre-serialized base64 transaction (signed externally by Node.js port)
  def send_transaction(base64_tx) do
    rpc("sendTransaction", [base64_tx, %{encoding: "base64",
                                          skipPreflight: false,
                                          preflightCommitment: "finalized"}])
  end

  defp rpc(method, params) do
    url = Application.get_env(:bharat_core, :solana_rpc_url) ||
          raise "solana_rpc_url not configured"

    body = Jason.encode!(%{
      jsonrpc: "2.0",
      id:      :erlang.unique_integer([:positive]),
      method:  method,
      params:  params
    })

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => err}}}     -> {:error, err}
      {:error, reason}                      -> {:error, reason}
    end
  end
end
```

---

## Step 7 — SolanaIndexer

**New file:** `apps/bharat_core/lib/bharat_core/indexer/solana_indexer.ex`

Pattern mirrors `AnvilIndexer` — HTTP polling every 1s, DB-checkpointed.

```elixir
defmodule BharatCore.Indexer.SolanaIndexer do
  @moduledoc """
  Solana event indexer for EscrowProgram on devnet.
  Uses getSignaturesForAddress polling — no eth_getLogs equivalent on Solana.
  Checkpoints last seen signature to IndexerCheckpoints (chain: "solana_devnet").
  """

  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.SolanaRpc
  alias BharatData.{IndexerCheckpoints}

  @poll_interval_ms 1_000
  @finality_slots   32
  @chain            "solana_devnet"

  # Anchor event discriminator: first 8 bytes of SHA256("event:EscrowReleased")
  # Precompute at compile time — never changes after deploy
  @escrow_released_disc :crypto.hash(:sha256, "event:EscrowReleased")
                        |> :binary.part(0, 8)
                        |> Base.encode64()

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :poll)
    {:ok, %{last_sig: IndexerCheckpoints.get_last_sig(@chain)}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    program_id = Application.get_env(:bharat_core, :solana_escrow_program)

    opts = [limit: 50, commitment: "finalized"]
    opts = if state.last_sig, do: opts ++ [until: state.last_sig], else: opts

    case SolanaRpc.get_signatures_for_address(program_id, opts) do
      {:ok, []} ->
        state

      {:ok, sigs} ->
        # Signatures come newest-first — process oldest-first
        finalized = sigs
          |> Enum.reverse()
          |> Enum.filter(&finalized?(&1["slot"]))

        Enum.each(finalized, &process_sig/1)

        newest_sig = List.first(sigs)["signature"]
        IndexerCheckpoints.update_last_sig(@chain, newest_sig)
        %{state | last_sig: newest_sig}

      {:error, reason} ->
        Logger.error("SolanaIndexer poll failed: #{inspect(reason)}")
        state
    end
  end

  defp finalized?(slot) when is_integer(slot) do
    case SolanaRpc.get_slot("finalized") do
      {:ok, current} -> current >= slot + @finality_slots
      _ -> false
    end
  end
  defp finalized?(_), do: false

  defp process_sig(%{"signature" => sig, "err" => nil}) do
    case SolanaRpc.get_transaction(sig) do
      {:ok, tx} -> parse_and_dispatch(tx, sig)
      {:error, reason} ->
        Logger.warning("SolanaIndexer: get_transaction #{sig} failed: #{inspect(reason)}")
    end
  end
  defp process_sig(%{"err" => err, "signature" => sig}) when not is_nil(err) do
    Logger.debug("SolanaIndexer: skipping failed tx #{sig}")
  end

  defp parse_and_dispatch(tx, sig) do
    # Anchor emits events as base64-encoded logs: "Program log: BHARAT_RELEASE <b64>"
    logs = get_in(tx, ["meta", "logMessages"]) || []

    Enum.each(logs, fn log ->
      case parse_log(log) do
        {:released, transfer_id_hex, solana_slot} ->
          transfer_id = Base.decode16!(transfer_id_hex, case: :mixed)
          Logger.info("SolanaIndexer: EscrowReleased transfer=#{transfer_id_hex} sig=#{sig}")
          # Notify TransferServer — same pattern as BlockchainIndexer → TransferServer.on_confirmed
          BharatCore.Bridge.TransferServer.on_solana_released(
            transfer_id, sig, solana_slot
          )

        :skip ->
          :ok
      end
    end)
  end

  defp parse_log("Program log: BHARAT_RELEASE " <> b64) do
    # Decode Anchor event: 8-byte discriminator + Borsh-encoded EscrowReleased
    # EscrowReleased { transfer_id: [u8;32], beneficiary: Pubkey, amount: u64 }
    case Base.decode64(b64) do
      {:ok, <<_disc::binary-8, transfer_id::binary-32, _rest::binary>>} ->
        hex = Base.encode16(transfer_id, case: :lower)
        {:released, hex, nil}  # slot comes from outer sig metadata
      _ ->
        :skip
    end
  end
  defp parse_log(_), do: :skip
end
```

**`apps/bharat_data/lib/bharat_data/indexer_checkpoints.ex`** — add sig-based checkpoint variant:

```elixir
# Add alongside existing get_last_block/update_last_block:
def get_last_sig(chain) do
  case Repo.get_by(IndexerCheckpoint, chain: chain) do
    nil -> nil
    cp  -> cp.last_sig
  end
end

def update_last_sig(chain, sig) do
  now = DateTime.utc_now()
  Repo.insert!(
    %IndexerCheckpoint{chain: chain, last_sig: sig, updated_at: now},
    on_conflict: [set: [last_sig: sig, updated_at: now]],
    conflict_target: :chain
  )
end
```

**`apps/bharat_data/lib/bharat_data/schemas/indexer_checkpoint.ex`** — add `last_sig` field:

```elixir
field :last_sig, :string   # for Solana (signature-based, not block-based)
```

Migration for this:
```elixir
alter table(:indexer_checkpoints) do
  add :last_sig, :string
end
```

---

## Step 8 — TransferServer FSM Extension

**`apps/bharat_core/lib/bharat_core/bridge/transfer_server.ex`**

**Changes needed (4 places):**

**1. Add `on_solana_released/3` public API:**
```elixir
# Add after on_minted/2:
def on_solana_released(transfer_id, solana_tx_sig, solana_slot) do
  case lookup(transfer_id) do
    {:ok, pid} ->
      GenServer.cast(pid, {:solana_released, solana_tx_sig, solana_slot})
    {:error, _} ->
      BharatData.Transfers.update_solana_released(transfer_id, solana_tx_sig, solana_slot)
      BharatData.Transfers.update_state(transfer_id, "completed", %{})
      broadcast(transfer_id, %{event: "completed", state: "completed", transfer_id: transfer_id})
  end
  :ok
end
```

**2. Extend `handle_continue(:init_transfer)` for `evm_to_solana` direction:**
```elixir
"evm_to_solana" ->
  unsigned_tx = Contract.build_evm_escrow_lock_tx(
    s.token_address, s.amount, s.id,
    s.destination_zone, s.destination_address
  )
  %{event: "await_lock", transfer_id: s.id, unsigned_tx: unsigned_tx,
    nonce_hash: s.nonce_hash, chain: "evm_escrow"}
```

**3. Add cast handler for `:solana_released`:**
```elixir
def handle_cast({:solana_released, solana_tx_sig, _slot}, %{state: :confirmed} = s) do
  s = %{s | state: :minted}
  Transfers.update_state(s.id, "minted", %{mint_tx_hash: solana_tx_sig})
  broadcast(s.id, %{event: "state_change", state: "sol_released",
                     solana_tx_sig: solana_tx_sig})
  Logger.info("Transfer #{s.id} SOL_RELEASED — sig #{solana_tx_sig}")
  {:noreply, s, {:continue, :complete}}
end
```

**4. Extend struct to carry destination fields:**
```elixir
defstruct [...existing..., :destination_zone, :destination_address]

# In init/1:
destination_zone:    opts[:destination_zone],
destination_address: opts[:destination_address],
```

---

## Step 9 — SolanaRelayWorker

**New file:** `apps/bharat_relayer/lib/bharat_relayer/solana_relay_worker.ex`

Mirrors `V2Worker` — polls confirmed `evm_to_solana` transfers, submits Solana release tx.

```elixir
defmodule BharatRelayer.SolanaRelayWorker do
  @moduledoc """
  Relayer for EVM → Solana transfers.
  Polls confirmed evm_to_solana transfers from DB.
  Builds and submits release_to_beneficiary instruction to Solana EscrowProgram.
  Uses Node.js port for Solana tx signing (keypair management in JS ecosystem).
  """

  use GenServer
  require Logger

  alias BharatData.Transfers
  alias BharatAdapters.Blockchain.SolanaRpc

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

    with {:ok, solana_amount} <- normalize_amount(transfer.amount),
         {:ok, tx_sig}        <- call_release_instruction(transfer, solana_amount) do
      Logger.info("SolanaRelayWorker: released transfer=#{transfer.id} sig=#{tx_sig}")
      # SolanaIndexer will detect the on-chain event and call TransferServer.on_solana_released
      # This is belt-and-suspenders: update DB directly in case indexer lags
      Transfers.update_solana_released(transfer.id, tx_sig, nil)
      BharatCore.Bridge.TransferServer.on_solana_released(transfer.id, tx_sig, nil)
    else
      {:error, reason} ->
        Logger.warning("SolanaRelayWorker: release failed #{transfer.id}: #{inspect(reason)}")
    end
  end

  # Convert ERC-20 18-decimal amount to SPL 6-decimal amount
  defp normalize_amount(amount_decimal) do
    amount_wei = Decimal.to_integer(amount_decimal)
    spl_amount = div(amount_wei, 1_000_000_000_000)  # 10^12 = 18-6 decimals
    if spl_amount > 0, do: {:ok, spl_amount}, else: {:error, :below_minimum}
  end

  # Call Solana EscrowProgram.release_to_beneficiary via Node.js port
  defp call_release_instruction(transfer, spl_amount) do
    program_id    = Application.get_env(:bharat_core, :solana_escrow_program)
    reserve_pool  = Application.get_env(:bharat_core, :solana_reserve_pool)
    keypair_json  = Application.get_env(:bharat_core, :relayer_solana_keypair)

    # destination_address is 32 raw bytes stored in DB (Solana pubkey)
    beneficiary_pubkey = Base58.encode(transfer.destination_address)

    # transfer.lock_tx_hash used as transfer_id bytes32 on EVM → same id in Solana
    transfer_id_hex = String.trim_leading(transfer.lock_tx_hash || transfer.nonce_hash, "0x")

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
```

**New file:** `apps/bharat_adapters/lib/bharat_adapters/blockchain/solana_port_client.ex`

Elixir port to Node.js process for Solana tx signing:

```elixir
defmodule BharatAdapters.Blockchain.SolanaPortClient do
  @moduledoc """
  Elixir port to Node.js for Solana transaction signing.
  Node.js handles @solana/web3.js keypair + transaction building.
  Communicates via stdio JSON (line-delimited).
  """

  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def call(method, payload_json) do
    GenServer.call(__MODULE__, {:call, method, payload_json}, 30_000)
  end

  @impl true
  def init(_) do
    port = Port.open(
      {:spawn, "node #{solana_signer_path()}"},
      [:binary, :use_stdio, {:line, 65536}, :exit_status]
    )
    {:ok, %{port: port, pending: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:call, method, payload_json}, from, state) do
    id = state.next_id
    msg = Jason.encode!(%{id: id, method: method, payload: Jason.decode!(payload_json)})
    Port.command(state.port, msg <> "\n")
    {:noreply, %{state |
      pending: Map.put(state.pending, id, from),
      next_id: id + 1
    }}
  end

  @impl true
  def handle_info({_port, {:data, {:eol, line}}}, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            Logger.warning("SolanaPortClient: unknown response id #{id}")
            {:noreply, state}
          {from, pending} ->
            result = if Map.has_key?(response, "error"),
              do: {:error, response["error"]},
              else: {:ok, response}
            GenServer.reply(from, result)
            {:noreply, %{state | pending: pending}}
        end

      {:error, _} ->
        Logger.error("SolanaPortClient: invalid JSON from Node: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.error("SolanaPortClient: Node.js process exited with code #{code}")
    {:stop, :node_exited, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp solana_signer_path do
    Application.get_env(:bharat_core, :solana_signer_script,
      "apps/bharat_adapters/priv/solana_signer.js")
  end
end
```

**New file:** `apps/bharat_adapters/priv/solana_signer.js`

Node.js script for tx building + signing:

```javascript
const { Connection, Keypair, PublicKey, Transaction, TransactionInstruction,
        SystemProgram } = require("@solana/web3.js");
const readline = require("readline");
const BN = require("bn.js");

const RPC_URL = process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com";
const connection = new Connection(RPC_URL, "finalized");

const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on("line", async (line) => {
  let msg;
  try {
    msg = JSON.parse(line.trim());
  } catch (e) {
    process.stdout.write(JSON.stringify({ id: null, error: "invalid json" }) + "\n");
    return;
  }

  const { id, method, payload } = msg;

  try {
    let result;
    if (method === "release") {
      result = await handleRelease(payload);
    } else {
      throw new Error(`unknown method: ${method}`);
    }
    process.stdout.write(JSON.stringify({ id, signature: result }) + "\n");
  } catch (e) {
    process.stdout.write(JSON.stringify({ id, error: e.message }) + "\n");
  }
});

async function handleRelease(payload) {
  const {
    program_id, reserve_pool, beneficiary_pubkey,
    transfer_id_hex, amount, evm_sender, source_zone, keypair_json
  } = payload;

  const keypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(keypair_json))
  );

  const programId       = new PublicKey(program_id);
  const reservePool     = new PublicKey(reserve_pool);
  const beneficiary     = new PublicKey(beneficiary_pubkey);

  // Derive EscrowState PDA — must match seeds in Rust program
  const transferIdBytes = Buffer.from(transfer_id_hex, "hex");
  const [escrowPda, bump] = await PublicKey.findProgramAddress(
    [Buffer.from("escrow"), transferIdBytes],
    programId
  );

  // Build instruction data:
  // discriminator(8) + transfer_id(32) + amount(u64 LE, 8) + evm_sender(20) + source_zone(32)
  const disc = Buffer.from("e92d3d4b5f4e1a2b", "hex"); // sha256("global:release_to_beneficiary")[0..7]
  const amountBuf = Buffer.alloc(8);
  new BN(amount).toArrayLike(Buffer, "le", 8).copy(amountBuf);
  const evmSenderBuf = Buffer.from(evm_sender.replace("0x", ""), "hex");
  const sourceZoneBuf = Buffer.alloc(32);
  Buffer.from(source_zone).copy(sourceZoneBuf);

  const data = Buffer.concat([disc, transferIdBytes, amountBuf, evmSenderBuf, sourceZoneBuf]);

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: keypair.publicKey, isSigner: true,  isWritable: true  },  // relayer
      { pubkey: escrowPda,         isSigner: false, isWritable: true  },  // escrow_state PDA
      { pubkey: reservePool,       isSigner: false, isWritable: true  },  // reserve pool
      { pubkey: beneficiary,       isSigner: false, isWritable: true  },  // beneficiary token acct
      { pubkey: TOKEN_PROGRAM_ID,  isSigner: false, isWritable: false },  // token program
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data,
  });

  const tx = new Transaction();
  tx.add(ix);
  tx.feePayer = keypair.publicKey;
  const { blockhash } = await connection.getLatestBlockhash("finalized");
  tx.recentBlockhash = blockhash;

  tx.sign(keypair);
  const sig = await connection.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    preflightCommitment: "finalized",
  });

  await connection.confirmTransaction(sig, "finalized");
  return sig;
}

const TOKEN_PROGRAM_ID = new PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
```

Install Node deps:
```bash
cd apps/bharat_adapters/priv
npm init -y
npm install @solana/web3.js bn.js
```

---

## Step 10 — Contract.ex Extension

**`apps/bharat_adapters/lib/bharat_adapters/blockchain/contract.ex`** — add one function:

```elixir
# keccak256("TokensLockedForZone(bytes32,address,uint256,address,string,bytes32,bytes)")
@tokens_locked_for_zone_topic "0x..."   # compute with cast_sig tool

# Build lockForZone() calldata for MetaMask
def build_evm_escrow_lock_tx(token_address, amount, transfer_id, destination_zone, destination_address_bytes) do
  # destination_address_bytes is 32-byte binary (Solana pubkey)
  zone_bytes = :binary.copy(<<0>>, max(0, 32 - byte_size(destination_zone))) <> destination_zone
  
  # lockForZone(address token, uint256 amount, string destinationZone, bytes32 destinationAddress, bytes metadata)
  # ABI encoding: static head + dynamic tail for string + bytes
  calldata = encode_call(
    "lockForZone(address,uint256,string,bytes32,bytes)",
    encode_lock_for_zone_args(token_address, amount, destination_zone, destination_address_bytes)
  )

  %{
    to:   evm_escrow_address(),
    data: "0x" <> Base.encode16(calldata, case: :lower),
    gas:  "0x493E0"   # ~300K gas
  }
end

defp encode_lock_for_zone_args(token, amount, dest_zone, dest_addr_bytes) do
  # Static head: token(32) + amount(32) + zoneOffset(32) + destAddr(32) + metaOffset(32) = 160 bytes
  zone_enc = encode_bytes_elem(dest_zone)
  meta_enc = encode_bytes_elem(<<>>)   # empty metadata for POC
  zone_offset = 160
  meta_offset = zone_offset + byte_size(zone_enc)

  IO.iodata_to_binary([
    addr(token),
    uint(amount),
    uint(zone_offset),
    dest_addr_bytes,         # bytes32 — static, no offset needed
    uint(meta_offset),
    zone_enc,
    meta_enc
  ])
end

defp evm_escrow_address do
  Application.get_env(:bharat_core, :evm_escrow_contract) ||
    raise "evm_escrow_contract not configured"
end
```

Also add `get_evm_escrow_logs/2` for the indexer:

```elixir
# keccak256 of TokensLockedForZone event — compute and hardcode
@tokens_locked_for_zone_topic "0x<compute_this>"

def get_evm_escrow_logs(from_block, to_block) do
  params = %{
    fromBlock: "0x" <> Integer.to_string(from_block, 16),
    toBlock:   "0x" <> Integer.to_string(to_block, 16),
    address:   evm_escrow_address(),
    topics:    [@tokens_locked_for_zone_topic]
  }
  Ethereumex.HttpClient.eth_get_logs(params)
end
```

---

## Step 11 — EVMEscrowIndexer

Extend the existing `BlockchainIndexer` OR create a parallel `EVMEscrowIndexer`:

**New file:** `apps/bharat_core/lib/bharat_core/indexer/evm_escrow_indexer.ex`

Copy `BlockchainIndexer` structure, change:
- `Contract.get_logs` → `Contract.get_evm_escrow_logs`
- `EventParser.parse` → parse `TokensLockedForZone` log
- `TransferServer.on_confirmed` — need to pass `destination_address` too

```elixir
defmodule BharatCore.Indexer.EVMEscrowIndexer do
  use GenServer
  require Logger

  alias BharatAdapters.Blockchain.Contract
  alias BharatCore.Bridge.TransferServer
  alias BharatData.{Transfers, IndexerCheckpoints}

  @confirmation_depth 12
  @poll_interval_ms   3_000
  @chain              "amoy_evm_escrow"

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :start)
    {:ok, %{pending: %{}, current_block: 0}}
  end

  @impl true
  def handle_info(:start, state) do
    last = IndexerCheckpoints.get_last_block(@chain)
    {:ok, current} = Contract.current_block_number()
    from = if last == 0, do: max(0, current - 1000), else: last + 1
    backfill(from, current)
    IndexerCheckpoints.update_last_block_for_chain(@chain, current)
    schedule_poll()
    {:noreply, %{state | current_block: current}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp poll(state) do
    case Contract.current_block_number() do
      {:ok, latest} when latest > state.current_block ->
        case Contract.get_evm_escrow_logs(state.current_block + 1, latest) do
          {:ok, logs} ->
            state = Enum.reduce(logs, state, fn raw, acc ->
              case parse_lock_for_zone(raw) do
                {:ok, event} ->
                  put_in(acc.pending[event.transfer_id], {event, event.block_number})
                :skip -> acc
              end
            end)
            state = promote_confirmed(state, latest)
            IndexerCheckpoints.update_last_block_for_chain(@chain, latest)
            %{state | current_block: latest}
          {:error, e} ->
            Logger.error("EVMEscrowIndexer getLogs failed: #{inspect(e)}")
            state
        end
      _ -> state
    end
  end

  defp promote_confirmed(state, current_block) do
    {to_confirm, still_pending} =
      Enum.split_with(state.pending, fn {_k, {_ev, block}} ->
        current_block - block >= @confirmation_depth
      end)

    Enum.each(to_confirm, fn {_k, {event, block}} ->
      Logger.info("EVMEscrowIndexer: confirmed #{event.transfer_id} at block #{block}")
      # Create/update transfer in DB with destination info
      Transfers.confirm_evm_escrow_lock(event)
      TransferServer.on_confirmed(event.transfer_id, block)
    end)

    %{state | pending: Map.new(still_pending)}
  end

  defp parse_lock_for_zone(raw_log) do
    # TokensLockedForZone(bytes32 indexed transferId, address indexed token, uint256 amount,
    #                     address sender, string destinationZone, bytes32 destinationAddress, bytes metadata)
    # topics[0] = event sig, topics[1] = transferId (indexed), topics[2] = token (indexed)
    # data = ABI-encoded: amount(32) + sender(32) + zoneOffset(32) + destAddr(32) + metaOffset(32) + ...
    try do
      [_sig, transfer_id_hex, _token_hex | _] = raw_log["topics"]
      data = Base.decode16!(String.trim_leading(raw_log["data"], "0x"), case: :mixed)

      <<amount_bin::binary-32,
        _sender_padded::binary-32,
        _zone_offset::binary-32,
        dest_addr::binary-32,
        _rest::binary>> = data

      amount = :binary.decode_unsigned(amount_bin)
      transfer_id_raw = Base.decode16!(String.trim_leading(transfer_id_hex, "0x"), case: :mixed)

      {:ok, %{
        transfer_id:         transfer_id_raw,
        amount:              amount,
        destination_address: dest_addr,
        block_number:        String.to_integer(String.trim_leading(raw_log["blockNumber"], "0x"), 16)
      }}
    rescue
      _ -> :skip
    end
  end

  defp backfill(from, to) when from > to, do: :ok
  defp backfill(from, to) do
    batch = min(from + 8, to)
    case Contract.get_evm_escrow_logs(from, batch) do
      {:ok, logs} ->
        Enum.each(logs, fn raw ->
          case parse_lock_for_zone(raw) do
            {:ok, event} -> Transfers.confirm_evm_escrow_lock(event)
            :skip -> :ok
          end
        end)
      {:error, e} -> Logger.error("EVMEscrowIndexer backfill failed: #{inspect(e)}")
    end
    backfill(batch + 1, to)
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```

---

## Step 12 — TransferController Extension

**`apps/bharat_web/lib/bharat_web/controllers/transfer_controller.ex`**

In `do_create/4`, add `destination_address` parsing for `evm_to_solana`:

```elixir
defp do_create(conn, wallet, direction, params) do
  # Parse Solana destination address: base58 string → 32 raw bytes
  destination_address =
    if direction == "evm_to_solana" do
      pubkey_b58 = params["destination_address"] ||
        (conn |> put_status(:bad_request) |> json(%{error: "destination_address required for evm_to_solana"}) |> halt())
      Base58.decode!(pubkey_b58)  # add :b58 hex to mix.exs deps
    end

  destination_zone = if direction == "evm_to_solana", do: "sol:devnet", else: nil

  attrs = %{
    wallet:              wallet,
    token_address:       params["token_address"],
    amount:              parse_amount(params["amount"]),
    direction:           direction,
    compliance_status:   "approved",
    destination_zone:    destination_zone,
    destination_address: destination_address,
    instruction_payload: params["instruction_payload"],
  }
  # ... rest same as existing
end
```

---

## Step 13 — Application Supervisor

**`apps/bharat_relayer/lib/bharat_relayer/application.ex`** — add new workers:

```elixir
children = [
  ...existing...,
  BharatRelayer.SolanaRelayWorker,       # new
  BharatAdapters.Blockchain.SolanaPortClient,  # new — must start before SolanaRelayWorker
]
```

**`apps/bharat_core/lib/bharat_core/application.ex`** — add new indexers:

```elixir
children = [
  ...existing...,
  BharatCore.Indexer.EVMEscrowIndexer,  # new
  BharatCore.Indexer.SolanaIndexer,      # new
]
```

---

## Step 14 — mix.exs Dependencies

**Root `mix.exs`** — add to deps:

```elixir
{:b58, "~> 1.0"},     # Base58 encoding/decoding for Solana addresses
```

**`apps/bharat_adapters/priv/package.json`** — Node.js deps (already shown in Step 9).

---

## Step 15 — Frontend (Minimal)

**Install:**
```bash
cd frontend
npm install @solana/wallet-adapter-react @solana/wallet-adapter-react-ui \
            @solana/wallet-adapter-wallets @solana/wallet-adapter-base \
            @solana/web3.js@1 bs58
```

**`frontend/app/providers.tsx`** — wrap with Solana providers (code in approach doc §5.9).

**`frontend/app/bridge/page.tsx`** — add:
- Direction selector showing `evm_to_solana` option
- When `evm_to_solana` selected: show Phantom connect button + `destination_address` field (auto-filled from connected Solana wallet pubkey)
- POST to `/api/transfers` with `{ direction: "evm_to_solana", destination_address: <base58_pubkey>, ... }`

---

## Implementation Order Summary

| Order | Step | Effort | Blocking? |
|-------|------|--------|-----------|
| 1 | DB migration | 30m | Yes — run first |
| 2 | EVMEscrow.sol | 2h | Yes — need address for config |
| 3 | Solana EscrowProgram | 4h | Yes — need program ID for config |
| 4 | Config + .env | 30m | Yes — everything else needs it |
| 5 | Transfer schema | 1h | Yes — indexers + FSM need it |
| 6 | SolanaRpc adapter | 1h | Yes — indexer + worker need it |
| 7 | SolanaPortClient + solana_signer.js | 3h | Yes — worker needs it |
| 8 | EVMEscrowIndexer | 2h | No — parallel with SolanaIndexer |
| 9 | SolanaIndexer | 2h | No — parallel with EVMEscrowIndexer |
| 10 | SolanaRelayWorker | 2h | Needs SolanaPortClient |
| 11 | TransferServer FSM | 1h | Needs schema |
| 12 | Contract.ex extension | 1h | Needs config |
| 13 | TransferController | 1h | Needs FSM |
| 14 | Application supervisor | 30m | Needs all workers |
| 15 | Frontend | 3h | Needs API ready |
| **Total** | | **~24h** | |

---

## Quick Smoke Test After Each Step

```bash
# After Step 2 — EVMEscrow.sol compiles
forge build

# After Step 3 — Anchor compiles
cd contracts/solana && anchor build

# After Steps 5-6 — schema compiles
mix compile

# After Step 7 — Node.js signer works standalone
echo '{"id":1,"method":"release","payload":{...}}' | node apps/bharat_adapters/priv/solana_signer.js

# After Step 14 — full system starts
mix run --no-halt

# Full E2E test:
# 1. Call POST /api/transfers {direction: "evm_to_solana", amount: "1000000000000", destination_address: "<phantom_pubkey>"}
# 2. Sign EVMEscrow.lockForZone() in MetaMask (Amoy)
# 3. Wait ~30s
# 4. Check Solana devnet explorer — wINRX should appear in Phantom wallet
```
