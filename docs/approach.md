# BharatSetu — Implementation Approach

Maps `updated_flow.md` vocabulary (Zone, Channel, Hub) to actual code.

---

## Vocabulary → Code Mapping

| Doc Term | Code Location | Notes |
|---|---|---|
| **Zone A** | EVM side — `EVMEscrow.sol`, `LockBridge.sol`, `evm_escrow_indexer.ex`, `sepolia_indexer.ex` | Source chain for token flows |
| **Zone B** | Solana side — `solana_indexer.ex`, `solana_relay_worker.ex`, Solana programs | Destination chain; wraps/mints |
| **Hub** | `BharatRelayer` app — `hub_router.ex`, `worker.ex`, `transfer_server.ex` | Regulator/relayer node; owns TxnPool |
| **Channel** | `direction` field on `Transfer` schema + `TransferServer` direction routing | Channel = direction + zone pair |
| **TxnPool** | `transfers` DB table (polled by workers every 5s) | State written by Hub, read by relayer workers |
| **Escrow (Zone A)** | `EVMEscrow.sol` — `lockTokens()` / `releaseTokens()` | Holds original ERC-20/721 |
| **Escrow (Zone B)** | Solana vault program — `lock_spl` / `burn_wrapped` instructions | For reverse flow |
| **Consensus** | `HubRouter` 2-of-3 threshold (`@threshold 2`) | Zone B consensus before Hub commits |
| **State commit** | `Transfers.update_state/3` → DB + `Phoenix.PubSub` broadcast | Written on both zones via Hub |
| **Unique TxID** | `nonce_hash` (sha256 of wallet+transfer_id) | Channel-scoped, globally unique |

---

## Token Flow (Zone A → Zone B)

```
User
  │  initiate(token, amount, dest_wallet)
  ▼
TransferController          ← sets direction = "evm_to_solana", source_zone = "evm"
  │  spawns TransferServer (Hub FSM)
  ▼
TransferServer :init        ← builds unsigned lockTokens() tx, broadcasts to frontend
  │  nonce_hash = sha256(wallet ++ transfer_id)   ← unique channel+zone scoped ID
  ▼
EVMEscrow.sol (Zone A)      ← user signs → lockTokens(token, amount, nonce_hash, dest_zone, dest_address)
  │  emits TokensLocked event
  ▼
EVMEscrowIndexer            ← Zone A state watcher; confirms ≥12 blocks
  │  calls TransferServer.on_confirmed/2
  ▼
TxnPool state = "confirmed" ← Hub records lock, sets state
  ▼
SolanaRelayWorker (Hub)     ← validates Zone A state, triggers Zone B action
  │  calls Solana program: mintWrapped(dest_wallet, amount, nonce_hash)
  ▼
Solana program (Zone B)     ← mints wrapped token (wETH-sol) to dest_wallet
  │  wrappedValue derived from locked ETH in Zone A vault
  ▼
SolanaIndexer               ← Zone B consensus / confirmation watcher
  │  calls TransferServer.on_solana_released/3
  ▼
TransferServer :complete    ← state commit: writes "completed" to DB (both zone records)
                            ← PubSub broadcast to frontend
```

**Rollback path:** any failure → `Transfers.update_state(id, "failed", ...)` → `EVMEscrow.releaseTokens()` on Zone A (to be wired into `init_timeout_worker.ex`)

---

## Reverse Token Flow (Zone B → Zone A)

```
User
  │  initiate(spl_token, amount, dest_wallet)
  ▼
TransferController          ← checks token version: original SPL or wrapped?
  │  direction = "solana_to_evm"
  ▼
TransferServer :init        ← builds Solana lock/burn instruction
  ▼
Solana program (Zone B)
  ├─ if wrapped token → burn after mint confirmation from Zone A  (step 6 in doc)
  └─ if original SPL  → lock in Solana escrow vault
  │  emits event
  ▼
SolanaIndexer               ← validates Zone B state; triggers Hub
  │  TransferServer.on_confirmed (from Solana side)
  ▼
TxnPool state = "confirmed"
  ▼
Worker / HubRouter (Hub)    ← triggers Zone A action
  │  calls EVMEscrow.releaseTokens(dest_wallet, amount, nonce_hash)   [unlock original ETH]
  ▼
EVMEscrowIndexer            ← Zone A confirmation watcher
  │  on confirmed → if wrapped was burned: finalize burn on Zone B
  ▼
TransferServer :complete    ← state commit to both zones + PubSub
```

---

## NFT / Asset Flow (Zone A → Zone B)

```
User
  │  initiate(nft_contract, token_id, dest_wallet)
  ▼
TransferController          ← transfer_type = "asset_to_instruction", direction = "evm_to_solana"
  │  spawns TransferServer (Hub FSM)
  ▼
TransferServer :init        ← builds unsigned lockNFT() tx
  │  receipt = nonce_hash; NFT metadata + description stored in instruction_payload
  ▼
AssetVault.sol (Zone A)     ← user signs → lockNFT(token_contract, token_id, nonce_hash, dest_zone, dest_addr)
  │  emits NFTLocked(nonce_hash, metadata_uri) event
  ▼
EVMEscrowIndexer            ← Zone A state watcher; confirms on-chain lock
  │  calls TransferServer.on_confirmed/2
  ▼
TxnPool state = "confirmed" ← Hub records lock + receipt
  ▼
HubRouter (Hub)             ← validates Zone A state, triggers Zone B mint
  │  execute_for_type → asset_to_instruction branch
  │  calls Solana program: mintWrappedNFT(dest_wallet, token_id, metadata, nonce_hash)
  ▼
Solana program (Zone B)     ← mints wrapped NFT (via Metaplex CPI) to dest_wallet
  │  wrapped NFT carries original metadata + source chain reference      [To build]
  ▼
SolanaIndexer               ← Zone B consensus / confirmation watcher
  │  TransferServer.on_solana_released/3
  ▼
TransferServer :complete    ← state commit to both zones + PubSub broadcast
```

**Rollback:** if Zone B mint fails → Hub calls `AssetVault.releaseNFT` to return original to sender.

---

## Reverse Asset Flow (Zone B → Zone A)

User holds wrapped NFT on Solana, wants original NFT back on EVM.

```
User
  │  initiate(wrapped_nft, dest_wallet)         ← Zone B → Zone A
  ▼
TransferController          ← transfer_type = "asset_to_instruction", direction = "solana_to_evm"
  │  spawns TransferServer (Hub FSM)
  ▼
TransferServer :init        ← builds Solana lock instruction for wrapped NFT
  │  nonce_hash = sha256(wallet ++ transfer_id)
  │  receipt generated: NFT metadata + description stored in instruction_payload
  ▼
Solana program (Zone B)     ← lockWrappedNFT(token_id, nonce_hash, dest_zone, dest_address)
  │  emits NFTLocked event with metadata receipt
  ▼
SolanaIndexer               ← validates Zone B lock state
  │  TransferServer.on_confirmed (from Solana side)
  ▼
TxnPool state = "confirmed" ← Hub records Zone B lock
  ▼
HubRouter (Hub)             ← validates Zone B state, triggers Zone A release
  │  execute_for_type → asset_to_instruction branch
  │  calls AssetVault.releaseNFT(dest_wallet, token_contract, token_id, nonce_hash)
  ▼
AssetVault.sol (Zone A)     ← releases original NFT to dest_wallet
  │  emits NFTReleased event
  ▼
EVMEscrowIndexer            ← Zone A confirmation watcher
  │  on confirmed → signals Hub: Zone A release done
  ▼
Hub → SolanaRelayWorker     ← triggers wrapped NFT burn on Zone B
  │  calls Solana program: burnWrappedNFT(token_id, nonce_hash)
  │  burn happens AFTER Zone A release confirmation (per doc step 6)
  ▼
SolanaIndexer               ← confirms burn on Zone B
  │  TransferServer.on_solana_released/3
  ▼
TransferServer :complete    ← state commit to both zones + PubSub broadcast
```

**Key difference from forward asset flow:** wrapped NFT locked first → original released on Zone A → burn confirmed on Zone B. Order matters — burn only after Zone A confirms release.

**Rollback:** if Zone A release fails → Hub unlocks wrapped NFT on Zone B (calls `unlockWrappedNFT`). Wired through `rollback_worker.ex`.

---

## What Needs to Be Built / Aligned

### 1. Zone/Channel as First-Class Fields

Currently `direction` string encodes zone+channel implicitly. Proposal:

```elixir
# Transfer schema additions
field :source_zone,   :string   # "evm" | "solana"
field :dest_zone,     :string   # "evm" | "solana"
field :channel_id,    :string   # "evm_solana_v1" — pluggable per usecase
```

`direction` stays for backwards compat but `source_zone`/`dest_zone` become the canonical routing key in `TransferServer`.

### 2. Zone B Consensus Module

`HubRouter` does threshold approval (2-of-3). Rename / extract into `BharatRelayer.ZoneConsensus` to match doc terminology. Same logic, clearer name.

### 3. Rollback Wiring

`init_timeout_worker.ex` exists but rollback to Zone A escrow not fully wired. On timeout/failure:
- Zone A: call `EVMEscrow.releaseTokens`
- Zone B: call Solana `cancelMint` if mint was in-flight
- Hub: set state = "rolled_back" (add to `@valid_states`)

### 4. Dual State Commit

Doc requires state written on both chains + Hub copy. Currently only DB (Hub) is written. Zone-level event emission:
- Zone A: `EVMEscrow` emits `TransferCommitted(nonce_hash, state)` on-chain
- Zone B: Solana program emits equivalent log
- Hub: already writes DB — add `zone_a_committed_at` / `zone_b_committed_at` timestamps to Transfer schema

### 5. Wrapped Token Version Check (Reverse Flow step 1)

Missing in `TransferController`. Before building lock tx, query Zone B to determine if token is original or wrapped:

```elixir
defp token_version(token_address, zone) do
  # query wrapped token registry on Hub
  BharatData.WrappedTokenRegistry.lookup(token_address, zone)
  # returns :original | :wrapped
end
```

---

## File Map for New Code

```
apps/bharat_relayer/lib/bharat_relayer/
  zone_consensus.ex          ← rename/extract from hub_router.ex
  rollback_worker.ex         ← wire EVMEscrow.releaseTokens on failure

apps/bharat_data/lib/bharat_data/schemas/
  transfer.ex                ← add source_zone, dest_zone, channel_id, zone_*_committed_at
  wrapped_token_registry.ex  ← new: tracks wrapped↔original token mapping per zone

apps/bharat_core/lib/bharat_core/bridge/
  transfer_server.ex         ← add source_zone/dest_zone routing; remove hardcoded direction strings

contracts/src/
  EVMEscrow.sol              ← add TransferCommitted event emission
```

---

## State Machine (all flows)

```
INIT → LOCKED → CONFIRMED → MINTED → COMPLETED
                                ↑
                           (Zone B consensus
                            via ZoneConsensus)
Any state → FAILED → ROLLED_BACK (new)
```

State written: Hub DB (always) + Zone A on-chain event + Zone B on-chain log.
