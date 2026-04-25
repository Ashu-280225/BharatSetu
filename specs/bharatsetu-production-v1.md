# BharatSetu — Production Bridge Specification v1.0

**Status:** Draft — Under Review  
**Date:** 2026-04-25  
**Authors:** Ashutosh + Claude  
**Supersedes:** `specs/bharatsetu-poc-v1.md`

---

## 1. Executive Summary

BharatSetu is a production-grade, multi-chain, regulated bridge for tokenised carbon credits and supply-chain assets. It connects EVM chains (Ethereum, Polygon), non-EVM chains (Solana, Hyperledger), and future chains through a hub-and-spoke validator network governed by a Regulator node. The system targets 6,000 TPS, 30-second bridge SLA, OFAC compliance, and full data residency within Indian jurisdiction.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Client Layer                                                               │
│  Browser / Mobile / Supply-chain operator (warehouse, logistics, delivery)  │
│  RainbowKit + wagmi (EVM)  ·  Phantom (Solana)  ·  Enterprise SDK (HLF)    │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │ HTTPS + WSS
┌────────────────────────────────────▼────────────────────────────────────────┐
│  API Gateway Layer                                                          │
│  Phoenix (Elixir) · Rate limiting · JWT auth · OFAC screening plug         │
│  REST /api/v2  ·  WebSocket /socket  ·  gRPC (validator comms)             │
└──────┬──────────────────┬──────────────────────┬───────────────────────────┘
       │                  │                      │
┌──────▼──────┐  ┌────────▼────────┐  ┌──────────▼──────────┐
│  Transfer   │  │  Validator      │  │  Compliance Service  │
│  Processor  │  │  Coordinator    │  │  KYC · OFAC · Audit  │
│  (Kafka)    │  │  (Hub node)     │  │  Log                 │
└──────┬──────┘  └────────┬────────┘  └──────────────────────┘
       │                  │
┌──────▼──────────────────▼───────────────────────────────────────────────────┐
│  Validator Network (3-of-5 BLS, Hub-and-Spoke)                             │
│  V1 · V2 · V3 · V4 · V5  (open set, registered Ethereum addresses)        │
│  Each validator: independent chain RPC · AWS KMS signing · liveness check  │
└──────┬──────────────────────────────────────────────────────────────────────┘
       │  BLS aggregate signature (1 sig on-chain after quorum)
┌──────▼────────────────────────────────────────────────────────────────────┐
│  Relayer Pool (3 relayers, load-balanced, run by validators)              │
│  R1 · R2 · R3  — each monitors queue, submits destination tx              │
└──────┬──────────────────────────────────────────────────────────────────────┘
       │
┌──────▼────────────────────────────────────────────────────────────────────┐
│  Chain Adapter Layer                                                       │
│  EVMAdapter · SolanaAdapter · HyperledgerAdapter · [pluggable]            │
└──────┬──────────────────────────────────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────────────────────────────────┐
│  Supported Chains                                                           │
│  Ethereum Mainnet  ·  Polygon PoS  ·  Solana  ·  Hyperledger Fabric       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Chain Support

### 3.1 Supported Chains at Launch

| Chain | Type | Role | Finality Model | Confirmation Depth |
|-------|------|------|---------------|-------------------|
| Ethereum Mainnet | EVM | Source + Destination | Probabilistic | 12 blocks (~2.5 min) |
| Polygon PoS | EVM | Source + Destination | Probabilistic | 128 blocks (~4 min) |
| Solana | Non-EVM | Source + Destination | Optimistic (1 slot) | 32 slots (~13s) |
| Hyperledger Fabric | Permissioned | Source + Destination | Instant (PBFT) | 1 block |

### 3.2 Chain Addition Process

- Only **Regulator node** can add/remove chains.
- Addition requires: chain adapter implementation, deployed bridge contracts, validator quorum approval (3-of-5).
- Chain added to `ChainRegistry` contract — all validators must register endpoint for new chain within 48h or face liveness penalty.

### 3.3 Mixed Finality Strategy

Each chain has a `FinalityOracle` component inside its adapter:

```
Ethereum / Polygon  → wait N blocks (probabilistic, configurable per chain)
Solana              → wait for "confirmed" commitment level (1 slot + supermajority vote)
Hyperledger Fabric  → instant (PBFT consensus = instant finality, 1 block)
```

**Rule:** Transfer moves to `confirmed` only after the weakest-finality chain in the pair reaches its threshold. The `FinalityOracle` returns `{:final, block}` or `{:pending, estimated_ms}`.

Target: worst-case finality < 30s. Ethereum is the bottleneck (12 blocks). For ETH↔Polygon, run parallel confirmation — move to `confirmed` after both independently confirm.

---

## 4. Token Model

### 4.1 Supported Standards

| Standard | Description | Example |
|----------|-------------|---------|
| ERC-20 | Fungible token | tCCS, wCCC |
| ERC-1155 | Multi-token (fungible + NFT in one contract) | Carbon credit batches, project-specific NFTs |
| SPL Token | Solana fungible token | Solana-side representation |
| Hyperledger Chaincode Asset | Permissioned chain asset | Enterprise supply-chain token |

### 4.2 Token Registry

- All bridgeable tokens must be registered in `TokenRegistry` contract by Regulator.
- Per-token config: `name`, `symbol`, `decimals`, `max_transfer_size`, `source_chain`, `destination_chains[]`.
- Unregistered tokens are rejected at API layer before any chain interaction.

### 4.3 Supply Invariant

For every bridged token:

```
total_locked_on_source == total_minted_on_destination
```

Enforced by:
1. `LockBridge` escrows exact amount before relayer mints.
2. `MintBridge` mints exact amount from lock event — no rounding, no fees deducted from amount.
3. Fees collected separately in `FeeVault`, not from bridged amount.

### 4.4 Token Metadata

Configurable per deployment:
- `name`: string
- `symbol`: string
- `decimals`: uint8
- `uri` (ERC-1155): IPFS or HTTPS metadata URI
- `max_transfer_bytes`: 256KB hard cap on transfer payload size

---

## 5. Transfer Lifecycle

### 5.1 State Machine

```
[init]
   │
   ├── InitTimeoutWorker (10 min, no tx) ──────────────────────► [expired]
   │
   │  user submits source chain tx
   ▼
[submitted]
   │
   ├── OFAC / KYC check fails ──────────────────────────────────► [blocked]
   │
   │  source chain reaches finality
   ▼
[source_confirmed]
   │
   │  validator quorum (3-of-5) signs attestation
   ▼
[attested]
   │
   │  relayer submits destination tx
   ▼
[relay_submitted]
   │
   ├── relay fails 3 times ─────────────────────────────────────► [relay_failed]
   │                                                                    │
   │                                                            user retries ──► [attested]
   │
   │  destination chain confirms
   ▼
[destination_confirmed]
   │
   │  final audit log written
   ▼
[completed]
```

### 5.2 SLA Targets

| Stage | Target | Max |
|-------|--------|-----|
| init → source_confirmed | Chain-dependent (see §3.3) | 25s |
| source_confirmed → attested | < 2s (BLS signing round) | 5s |
| attested → relay_submitted | < 1s | 3s |
| relay_submitted → completed | Chain-dependent | 25s |
| **End-to-end** | **< 30s** | **60s** |

---

## 6. Validator Network

### 6.1 Overview

- **Model:** Hub-and-spoke. Regulator node is coordinator hub.
- **Quorum:** 3-of-5 BLS signatures required.
- **Set:** Open — any Ethereum address can register as validator subject to Regulator approval.
- **Signing:** BLS12-381 — validators produce individual BLS signatures, coordinator aggregates into one before on-chain submission. One aggregated sig = cheaper gas vs N ECDSA sigs.

### 6.2 Validator Registration

```
POST /api/v2/validators/register
{
  "eth_address": "0x...",
  "bls_public_key": "0x...",
  "chains": ["ethereum", "polygon", "solana"]
}
```

- Regulator node approves registration.
- Validator address added to `ValidatorSet` contract on each chain they support.
- Validator must maintain liveness (see §6.4) within 48h of registration.

### 6.3 Attestation Flow

```
1. Source chain event confirmed by FinalityOracle
2. TransferProcessor publishes {transfer_id, event_hash, source_chain, amount, nonce}
   to Kafka topic: bridge.attestation.requests
3. All 5 validators independently:
   a. Pull event from their own chain RPC node
   b. Verify: event exists, block depth reached, amount matches, nonce unused
   c. Sign attestation with BLS key via AWS KMS
   d. POST signed attestation to Coordinator (Regulator hub)
4. Coordinator collects signatures
5. On receiving 3rd valid signature:
   a. Aggregate 3 BLS sigs into 1
   b. Publish to Kafka: bridge.attestation.ready
   c. Relayer pool picks up and submits destination tx
```

### 6.4 Liveness Requirement

- Validator must respond to attestation request within **10 seconds**.
- Miss > 5% of attestations in a 24h window → Regulator marks validator `degraded`.
- Miss > 20% → removed from active set, replaced from waitlist.
- No staking/slashing in v1. Liveness enforced by Regulator administrative control.

### 6.5 Key Management

- Each validator holds a **BLS12-381 key pair** stored in **AWS KMS** (key never exported).
- Signing call: validator sends hash to KMS API → KMS returns BLS signature.
- AWS KMS CloudTrail logs all signing operations → feeds into audit log.

### 6.6 Validator Identity Contract

```solidity
// Per-chain ValidatorSet.sol
struct Validator {
    address ethAddress;
    bytes blsPublicKey;    // BLS12-381 compressed pubkey
    bool active;
    uint256 registeredAt;
}

mapping(address => Validator) public validators;
address[] public activeSet;  // max 5 in v1

function addValidator(address v, bytes calldata blsKey) external onlyRegulator;
function removeValidator(address v) external onlyRegulator;
function isQuorum(bytes[] calldata blsSigs, bytes32 msgHash) external view returns (bool);
```

---

## 7. Relayer Network

### 7.1 Configuration

- **3 relayers**, each operated by a validator node.
- Load-balanced via Kafka consumer group — each relayer pulls from `bridge.attestation.ready` topic.
- Exactly-once delivery: Kafka consumer group ensures one relayer processes each attested transfer.

### 7.2 Relayer Responsibilities

1. Consume attested transfer from Kafka.
2. Build destination chain tx (mint/unlock/SPL transfer/chaincode invoke).
3. Sign via AWS KMS (relayer key = separate from validator BLS key).
4. Submit to destination chain.
5. Monitor for confirmation.
6. On success: publish to `bridge.relay.completed`.
7. On failure: increment `relay_attempts`, publish to `bridge.relay.retry` (max 3).

### 7.3 Gas Strategy

- **EVM chains:** EIP-1559 fixed gas — `maxFeePerGas` and `maxPriorityFeePerGas` set per-chain in config, updated by Regulator. No dynamic oracle in v1.
- **Solana:** Fixed compute unit price, configurable per cluster.
- **Hyperledger:** No gas — endorsement policy covers execution.
- Relayer gas costs reimbursed from `FeeVault` at end of each epoch (daily).

### 7.4 Stuck Transfer Handling

- Transfer stuck in `relay_submitted` > 5 min → relayer re-checks tx on destination chain.
- If tx dropped from mempool → resubmit with higher gas (1.2× bump).
- If tx confirmed but event not indexed → force re-index from block.
- After 3 failed attempts → state → `relay_failed`, alert fired to Datadog.

---

## 8. Smart Contracts

### 8.1 Design Principles

- **Immutable** — no proxy pattern. Correctness over upgradeability.
- **Per-chain validator set** — each chain has its own `ValidatorSet` contract.
- **On-chain quorum verification** — bridge contracts verify BLS aggregate signature.
- **No transfer caps** in v1. Daily volume tracked off-chain for monitoring only.
- **Regulator address** controls pause, validator management, fee config.

### 8.2 EVM Contract Suite

#### BridgeCore.sol (deployed on each EVM chain)

```solidity
contract BridgeCore {
    ValidatorSet public validatorSet;
    FeeVault public feeVault;
    TokenRegistry public tokenRegistry;
    bool public paused;
    address public regulator;

    mapping(bytes32 => bool) public processedNonces;

    // Lock fungible token (ERC-20)
    function lockERC20(
        address token,
        uint256 amount,
        bytes32 transferId,
        uint64 destinationChainId
    ) external whenNotPaused;

    // Lock multi-token (ERC-1155)
    function lockERC1155(
        address token,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data,    // max 256KB
        bytes32 transferId,
        uint64 destinationChainId
    ) external whenNotPaused;

    // Mint on destination — requires BLS aggregate sig from 3-of-5 validators
    function mintWithAttestation(
        address to,
        address token,
        uint256 amount,
        bytes32 transferId,
        bytes calldata blsAggSig,    // aggregated BLS signature
        bytes[] calldata blsPubKeys  // participating validator pubkeys
    ) external whenNotPaused;

    // Unlock escrowed tokens — same attestation requirement
    function unlockWithAttestation(
        address to,
        address token,
        uint256 amount,
        bytes32 transferId,
        bytes calldata blsAggSig,
        bytes[] calldata blsPubKeys
    ) external whenNotPaused;

    // Regulator only
    function pause() external onlyRegulator;
    function unpause() external onlyRegulator;
}
```

#### FeeVault.sol

```solidity
contract FeeVault {
    address public regulator;
    uint256 public fixedFeeWei;   // fee per transfer, in native token

    // Collect fee at transfer initiation
    function collectFee(bytes32 transferId) external payable;

    // Distribute to validators — called by Regulator at epoch end
    function distributeToValidators(
        address[] calldata validators,
        uint256[] calldata amounts
    ) external onlyRegulator;

    // Withdraw treasury balance
    function withdrawTreasury(address to, uint256 amount) external onlyRegulator;
}
```

#### TokenRegistry.sol

```solidity
contract TokenRegistry {
    struct TokenConfig {
        bool active;
        uint8 standard;          // 0=ERC20, 1=ERC1155
        uint256 maxTransferBytes;
        uint64[] supportedChains;
        string name;
        string symbol;
        uint8 decimals;
        string uri;              // for ERC-1155
    }
    mapping(address => TokenConfig) public tokens;

    function registerToken(address token, TokenConfig calldata config) external onlyRegulator;
    function deactivateToken(address token) external onlyRegulator;
    function isSupported(address token, uint64 chainId) external view returns (bool);
}
```

### 8.3 Non-EVM Contracts

#### Solana Program (Rust)

- `lock_spl`: Lock SPL token, emit `TokensLocked` log entry.
- `mint_with_attestation`: Verify 3-of-5 BLS sigs (ed25519 on Solana), mint SPL token.
- `burn_and_bridge`: Burn SPL, emit `TokensBurned`.
- `unlock_with_attestation`: Verify sigs, release escrowed SPL.

#### Hyperledger Chaincode (Go)

- `LockAsset(assetId, amount, transferId, destinationChain)`: Escrow asset.
- `MintWithAttestation(...)`: Verify endorsements from validators, mint asset.
- Validators on HLF = endorsing peers registered in channel policy.

---

## 9. Fee Model

- **Fixed fee per transfer** — configured per token per chain pair by Regulator.
- Fee paid in **native chain token** (ETH on Ethereum, MATIC on Polygon, SOL on Solana).
- Collected in `FeeVault` at transfer initiation.

**Distribution (per epoch = 24h):**
```
Total collected fees
  ├── 60% → Validator pool (split equally among active validators who met liveness SLA)
  ├── 30% → Regulator treasury
  └── 10% → Relayer gas reimbursement pool
```

---

## 10. Compliance

### 10.1 OFAC Screening

- Every transfer: source wallet + destination wallet checked against OFAC SDN list before `init` record created.
- Screening provider: TBD (integration point in `ComplianceService`).
- Blocked wallet → transfer state → `blocked`, funds not moved, event logged.
- Re-screening on retry.

### 10.2 KYC

- Required for all users (no threshold exemption in v1).
- KYC provider: TBD — `KYCAdapter` interface already in codebase, replace mock.
- KYC status cached per wallet address, TTL = 24h.
- Expired KYC → transfer blocked until re-verified.

### 10.3 Audit Log

- Every state transition written to **immutable append-only audit table** in CockroachDB.
- Fields: `transfer_id`, `from_state`, `to_state`, `actor` (user/validator/relayer), `timestamp`, `chain_tx_hash`, `block_number`.
- Log exported daily to S3 (India region) for regulatory compliance.
- Block explorer integration: all on-chain events indexable by public explorer.

### 10.4 Data Residency

- All user data (wallet address, KYC status, transfer history) stored in CockroachDB cluster hosted in **India region** (AWS ap-south-1).
- No PII sent to external services outside India without explicit compliance approval.
- Audit logs stored in S3 ap-south-1 with object lock (WORM).

---

## 11. Data Architecture

### 11.1 Primary Database

**CockroachDB** (distributed PostgreSQL-compatible):
- Multi-region active-active (India primary + DR replica).
- Ecto-compatible — minimal code change from current Postgres.
- Handles 6000 TPS with horizontal scaling (add nodes).

**Core tables:**

```sql
transfers          -- transfer records, state machine
transfer_events    -- append-only audit log
validators         -- registered validator set
chain_configs      -- per-chain RPC endpoints, confirmation depths
token_registry     -- registered bridgeable tokens
indexer_checkpoints-- per-chain last processed block
fee_collections    -- per-transfer fee records
ofac_screenings    -- screening results cache
```

### 11.2 Message Bus

**Apache Kafka** — decouples indexers, validators, relayers:

| Topic | Producer | Consumer |
|-------|----------|----------|
| `bridge.events.raw` | Chain indexers | Transfer processor |
| `bridge.attestation.requests` | Transfer processor | All 5 validators |
| `bridge.attestation.ready` | Validator coordinator | Relayer pool |
| `bridge.relay.completed` | Relayer | Audit logger |
| `bridge.relay.retry` | Relayer | Retry worker |
| `bridge.alerts` | Any component | Datadog forwarder |

### 11.3 Event Indexing

Self-hosted indexers (current approach) — one `ChainIndexer` GenServer per supported chain. Each runs independently, checkpointed in DB. No external dependency on The Graph.

---

## 12. API Contract v2

**Base URL:** `https://api.bharatsetu.in/api/v2`  
**Auth:** JWT Bearer (SIWE for EVM, wallet-signed message for Solana)  
**Rate limit:** 100 req/min per wallet, 1000 req/min per validator

### Core Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/auth/challenge` | — | Get SIWE nonce |
| POST | `/auth/verify` | — | Exchange signature for JWT |
| GET | `/config` | — | Chain configs, contract addresses |
| GET | `/prices` | — | Live token prices |
| GET | `/health` | — | System health |
| POST | `/transfers` | JWT + KYC | Initiate transfer |
| GET | `/transfers` | JWT | List user transfers |
| GET | `/transfers/:id` | JWT | Get transfer |
| POST | `/transfers/:id/lock` | JWT + KYC | Confirm source tx |
| DELETE | `/transfers/:id` | JWT + KYC | Cancel (init only) |
| POST | `/transfers/:id/retry` | JWT + KYC | Retry relay-failed |
| POST | `/validators/register` | Regulator | Register validator |
| DELETE | `/validators/:address` | Regulator | Remove validator |
| POST | `/validators/attest` | Validator | Submit BLS attestation |
| GET | `/tokens` | — | List registered tokens |
| POST | `/tokens` | Regulator | Register token |

### Transfer Request v2

```json
POST /api/v2/transfers
{
  "token_address": "0x...",
  "token_standard": "ERC20",      // ERC20 | ERC1155
  "token_id": null,               // required for ERC1155
  "amount": "100",
  "data": null,                   // optional payload, max 256KB, base64
  "source_chain": "polygon",
  "destination_chain": "ethereum",
  "destination_wallet": "0x..."   // can differ from source wallet
}
```

---

## 13. Chain Adapter Interface

All chain adapters implement this contract — makes adding new chains mechanical:

```elixir
@callback get_events(from_block :: integer, to_block :: integer) ::
  {:ok, [event()]} | {:error, term()}

@callback current_block() :: {:ok, integer} | {:error, term()}

@callback is_final?(block_number :: integer) :: {:ok, boolean} | {:error, term()}

@callback submit_tx(calldata :: binary, key_id :: String.t()) ::
  {:ok, tx_hash :: String.t()} | {:error, term()}

@callback get_tx_status(tx_hash :: String.t()) ::
  {:ok, :confirmed | :pending | :failed} | {:error, term()}
```

Implementations:
- `BharatAdapters.Chain.EVM` — Ethereum, Polygon
- `BharatAdapters.Chain.Solana` — Solana (via JSON RPC)
- `BharatAdapters.Chain.Hyperledger` — HLF (via Fabric SDK / REST gateway)

---

## 14. Observability

### 14.1 Monitoring — Datadog

**Key metrics:**

| Metric | Alert threshold |
|--------|----------------|
| `bridge.transfer.e2e_latency_p99` | > 30s |
| `bridge.relay.queue_depth` | > 100 |
| `bridge.validator.liveness_pct` | < 80% any validator |
| `bridge.transfer.relay_failed_rate` | > 1% |
| `bridge.ofac.blocked_count` | > 0 (immediate alert) |
| `bridge.chain.indexer_lag_blocks` | > 50 |
| `bridge.fee_vault.balance` | < 1 ETH |

### 14.2 Alerting

- P0 (page immediately): OFAC block, contract paused, quorum below 3, indexer lag > 100 blocks.
- P1 (alert within 5 min): E2E latency > 30s, relay failure rate > 1%.
- P2 (next business day): Validator liveness < 90%, fee vault low.

---

## 15. Non-Functional Requirements

| Requirement | Target |
|-------------|--------|
| Peak TPS | 6,000 |
| Bridge SLA (p99) | 30 seconds |
| API availability | 99.9% |
| Max transfer payload | 256 KB |
| Data residency | India (AWS ap-south-1) |
| Audit log retention | 7 years (regulatory) |
| RTO (recovery time objective) | 4 hours |
| RPO (recovery point objective) | 0 (CockroachDB sync replication) |

---

## 16. Out of Scope (v1 Production)

- Staking and economic slashing for validators
- DAO governance / on-chain parameter changes
- Contract upgradeability (proxy pattern)
- Optimistic fraud proof window
- ZK proof based trustless bridging
- Cosmos / Polkadot IBC integration
- Automated market maker / liquidity pool
- Bridge insurance fund
- On-chain gas oracle (dynamic gas pricing)
- Contract audit (required before mainnet — vendor TBD)
- KYC vendor selection and integration (adapter ready, vendor TBD)
- Multi-region Kafka cluster (single region v1)

---

## 17. Open Items (Need Decision Before Implementation)

| # | Item | Owner | Deadline |
|---|------|-------|----------|
| 1 | KYC vendor selection | Ashutosh | Before impl |
| 2 | OFAC screening provider | Ashutosh | Before impl |
| 3 | Validator initial set — who are V1..V5? | Ashutosh | Before testnet |
| 4 | Fixed fee amounts per chain pair | Ashutosh | Before impl |
| 5 | Contract audit firm | Ashutosh | Before mainnet |
| 6 | Liveness penalty X seconds — exact value | Team | Before validator impl |
| 7 | AWS account / KMS key policy | Infra | Before validator impl |
| 8 | CockroachDB cluster sizing | Infra | Before DB migration |
