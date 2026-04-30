# BharatSetu — POC v2 Specification: CBDC ↔ Stablecoin Hub-and-Spoke Bridge

**Version:** 1.0
**Status:** In Development
**Date:** 2026-04-29
**Authors:** Ashutosh + Claude
**Supersedes:** Nothing — parallel to `specs/bharatsetu-poc-v1.md`

---

## 1. Goal

Demonstrate a Hub-and-Spoke interoperability bridge that converts simulated CBDC (digital fiat) on a permissioned ledger into a stablecoin on a public blockchain, using:

- **Lock-and-Mint** mechanism for atomicity
- **Automated compliance gate** (KYC tier check + OFAC blocklist) before any asset lock
- **Decentralized relayer network** — 3 independent relayers, 2-of-3 threshold required to mint
- **Multi-sig on-chain enforcement** — StablecoinBridge verifies 2-of-3 ECDSA signatures on-chain before minting

### Chains

| Role | Chain | Notes |
|------|-------|-------|
| CBDC (permissioned ledger) | Anvil local node | Simulates Corda / Hyperledger Fabric |
| Stablecoin (public chain) | Polygon Amoy testnet | Same as POC v1 |

### Tokens

| Token | Symbol | Chain | Purpose |
|-------|--------|-------|---------|
| Digital Rupee | INRDC | Anvil | Simulated CBDC |
| India Rupee Stablecoin | INRX | Polygon Amoy | Minted stablecoin on public chain |

---

## 2. Architecture

```
┌───────────────────────────────────────────────────────────────────────┐
│  Browser (Next.js 14)                                                 │
│  RainbowKit + wagmi + viem                                            │
│  New: CBDC direction toggle, compliance status badge                  │
└────────────────────────────┬──────────────────────────────────────────┘
                             │ REST + WebSocket (Phoenix)
┌────────────────────────────▼──────────────────────────────────────────┐
│  Elixir Umbrella App (Phoenix 1.7) — extended from POC v1             │
│  ├── bharat_web      — HTTP API + WebSocket channels                  │
│  │   └── NEW: ComplianceCheck plug on POST /transfers                 │
│  ├── bharat_core     — Business logic, indexers                       │
│  │   ├── NEW: ComplianceEngine (KYC tier + OFAC blocklist)           │
│  │   ├── NEW: AnvilIndexer (watches CBDCVault for CBDCLocked events)  │
│  │   └── NEW: HubRouter (collects 2-of-3 relayer approvals)          │
│  ├── bharat_data     — PostgreSQL via Ecto                            │
│  │   └── NEW: compliance_status, source_chain, dest_chain on transfers│
│  ├── bharat_adapters — Blockchain RPC                                 │
│  │   └── NEW: Anvil RPC functions + CBDCVault + StablecoinBridge ABI  │
│  └── bharat_relayer  — Cross-chain relay workers                      │
│      └── CHANGED: R1, R2, R3 (3 workers) + threshold approval logic   │
└──────────────┬──────────────────────────┬─────────────────────────────┘
               │ JSON-RPC (poll 3s)       │ JSON-RPC (send tx)
┌──────────────▼──────────┐      ┌────────▼──────────────────────────┐
│  Anvil Local (port 8545) │      │  Polygon Amoy testnet             │
│  MockCBDC.sol (INRDC)   │      │  StablecoinBridge.sol (INRX ERC20)│
│  CBDCVault.sol          │      │  - mintWithApprovals()            │
│  - lockCBDC()           │      │    verifies 2-of-3 ECDSA sigs     │
│  - unlockCBDC()         │      │  - burnAndBridge()                │
└─────────────────────────┘      └───────────────────────────────────┘
```

---

## 3. Conversion Flow (CBDC → Stablecoin)

```
1. User requests to convert 1000 INRDC → 1000 INRX

2. [Compliance Gate — synchronous, before transfer created]
   ComplianceEngine checks:
   a. KYC tier ≥ 1 (from users.kyc_tier in DB, default 0 = unverified)
   b. Wallet NOT in OFAC blocklist (hardcoded list in ComplianceEngine)
   If fails → 403 response, transfer NOT created

3. [Transfer created] POST /transfers with direction: "cbdc_to_stablecoin"
   DB row: state=init, compliance_status="approved", source_chain="anvil", dest_chain="amoy"

4. [Asset Lock] User calls CBDCVault.lockCBDC(amount, transferId) on Anvil
   Contract emits: CBDCLocked(wallet, amount, nonceHash, transferId)
   Frontend calls POST /transfers/:id/lock with tx_hash

5. [Event Detection] AnvilIndexer polls Anvil every 3s
   Detects CBDCLocked event → after 3 blocks confirmation → state=confirmed

6. [Decentralized Relay — 2-of-3 threshold]
   Relayers R1, R2, R3 each independently:
   a. Detect state=confirmed transfer
   b. Verify the CBDCLocked event on Anvil (re-read logs)
   c. Sign approval: ECDSA sign(keccak256(transferId ++ nonceHash ++ amount ++ dest_wallet))
   d. Submit to HubRouter: HubRouter.submit_approval(transfer_id, relayer_idx, signature)

7. [Hub threshold reached — 2 of 3 approved]
   HubRouter collects signatures, at 2/3 → R1 calls:
   StablecoinBridge.mintWithApprovals(to, amount, nonceHash, [sig1, sig2])
   Contract verifies 2 of 3 registered validator addresses signed → mints INRX

8. [Confirmation] AmoyIndexer (from POC v1 infrastructure) detects Minted event
   state=minted → state=completed
```

---

## 4. Smart Contracts

### 4.1 MockCBDC.sol (Anvil)

ERC20 representing digital fiat. Owner can mint for testing.

```solidity
// SPDX-License-Identifier: MIT
// Functions: mint(address to, uint256 amount) onlyOwner
// Symbol: INRDC, Decimals: 18
```

### 4.2 CBDCVault.sol (Anvil)

Permissioned escrow. Simulates the Central Bank's secure lockbox.

**Events:**
```solidity
event CBDCLocked(address indexed wallet, uint256 amount, bytes32 nonceHash, bytes32 transferId);
event CBDCUnlocked(address indexed wallet, uint256 amount, bytes32 transferId);
```

**Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `lockCBDC(uint256 amount, bytes32 transferId)` | public, whenNotPaused | Transfers INRDC from user. nonceHash = keccak256(msg.sender ++ transferId) |
| `unlockCBDC(address to, uint256 amount, bytes32 transferId)` | onlyAdmin | Returns INRDC (reverse flow) |
| `setAdmin(address a)` | onlyOwner | Update admin |
| `pause()` / `unpause()` | onlyOwner | Emergency halt |

**State:** `address public cbdcToken`, `address public admin`, `bool public paused`, `mapping(bytes32 => bool) public processedTransfers`

### 4.3 StablecoinBridge.sol (Polygon Amoy)

ERC20 stablecoin with on-chain multi-sig enforcement for minting.

**Events:**
```solidity
event Minted(address indexed to, uint256 amount, bytes32 nonceHash);
event TokensBurned(address indexed wallet, uint256 amount, bytes32 transferId);
event ValidatorAdded(address indexed validator);
event ValidatorRemoved(address indexed validator);
```

**Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `mintWithApprovals(address to, uint256 amount, bytes32 nonceHash, bytes[] calldata signatures)` | public, whenNotPaused | Verifies ≥threshold unique validator signatures, then mints |
| `burnAndBridge(uint256 amount, bytes32 transferId)` | public, whenNotPaused | Burns INRX. Emits TokensBurned for reverse flow |
| `addValidator(address v)` | onlyOwner | Register validator address |
| `removeValidator(address v)` | onlyOwner | Deregister validator |
| `setThreshold(uint256 t)` | onlyOwner | Update sig threshold (default 2) |

**State:** `address[] public validators`, `uint256 public threshold`, `mapping(bytes32 => bool) public usedNonces`, `mapping(address => bool) public isValidator`

**Signature verification:**
```solidity
bytes32 message = keccak256(abi.encodePacked(to, amount, nonceHash));
bytes32 ethHash = ECDSA.toEthSignedMessageHash(message);
address signer = ECDSA.recover(ethHash, signatures[i]);
require(isValidator[signer], "not a validator");
```

---

## 5. Transfer State Machine

Same GenServer pattern as POC v1. Compliance check happens **before** TransferServer starts (synchronous in API controller), so FSM states are unchanged:

```
[init] → [locked] → [confirmed] → [minted] → [completed]
  ↓                    ↓               ↓
[failed]           [failed]        [failed]
```

New DB fields (not FSM states):
- `compliance_status`: `"approved"` | `"rejected"` — set at transfer creation
- `source_chain`: `"anvil"` | `"amoy"` | `"sepolia"`
- `dest_chain`: `"anvil"` | `"amoy"` | `"sepolia"`

New direction value: `"cbdc_to_stablecoin"` | `"stablecoin_to_cbdc"` (alongside existing `"amoy_to_sepolia"`, `"sepolia_to_amoy"`)

---

## 6. ComplianceEngine

**Module:** `BharatCore.Compliance.Engine`

```elixir
# Returns :ok or {:error, reason}
check(wallet :: String.t()) :: :ok | {:error, :ofac_blocked | :kyc_required}
```

**OFAC check:** Hardcoded `@ofac_blocklist` MapSet of wallet addresses. Extensible.

**KYC check:** Reads `users.kyc_tier` from DB. Tier 0 = unverified (blocked). Tier ≥ 1 = allowed.

**Plug:** `BharatWeb.Plugs.RequireCompliance` — wraps `ComplianceEngine.check(wallet)`, returns 403 with reason on failure.

---

## 7. HubRouter

**Module:** `BharatRelayer.HubRouter`

GenServer. Collects relayer approvals per transfer. Triggers mint when threshold reached.

```elixir
# Called by each relayer worker
submit_approval(transfer_id, relayer_idx, signature) :: :ok | {:error, :already_submitted}

# Internal — called when threshold reached
trigger_mint(transfer_id, signatures) :: {:ok, tx_hash} | {:error, reason}
```

**State:** `%{approvals: %{transfer_id => [%{relayer: idx, sig: binary}]}}`, threshold: 2

**On threshold reached:** Calls `Contract.mint_with_approvals(to, amount, nonce_hash, signatures)` on Amoy. On success → `TransferServer.on_minted(transfer_id, tx_hash)`.

---

## 8. Relayer Workers (R1, R2, R3)

3 `BharatRelayer.Worker` GenServer processes. Each:
- Has its own private key (`RELAYER_1_PRIVATE_KEY`, `RELAYER_2_PRIVATE_KEY`, `RELAYER_3_PRIVATE_KEY`)
- Polls confirmed transfers every 5s
- For `cbdc_to_stablecoin`: re-reads CBDCLocked event from Anvil to verify, then signs and submits to HubRouter
- For `stablecoin_to_cbdc` (reverse): same 2-of-3 threshold for `unlockCBDC` on Anvil (future scope, POC does forward only)

**Registered names:** `BharatRelayer.Worker.R1`, `.R2`, `.R3`

---

## 9. AnvilIndexer

**Module:** `BharatCore.Indexer.AnvilIndexer`

Same pattern as `BlockchainIndexer` (POC v1). Uses `Req` to call Anvil JSON-RPC.

```
@poll_interval_ms 3_000
@confirmation_depth 3
@cbdc_locked_topic "0x..." # keccak256("CBDCLocked(address,uint256,bytes32,bytes32)")
```

Decoding: `topics[0]` = event sig, `topics[1]` = wallet (indexed), `data` = amount(32) ++ nonceHash(32) ++ transferId(32).

Checkpoint: `indexer_checkpoints` row with `chain = "anvil"`.

---

## 10. API Changes

### New direction values

`"cbdc_to_stablecoin"` | `"stablecoin_to_cbdc"` added alongside existing POC v1 directions.

### Updated POST /transfers

```json
// Request (cbdc_to_stablecoin)
{
  "token_address": "0x<MockCBDC address>",
  "amount": "1000",
  "direction": "cbdc_to_stablecoin"
}

// 403 if compliance fails
{ "error": "ofac_blocked" }
{ "error": "kyc_required" }
```

### GET /config — new fields

```json
{
  "data": {
    "cbdc_vault": "0x...",
    "stablecoin_bridge": "0x...",
    "mock_cbdc_token": "0x...",
    "anvil_chain_id": 31337,
    ...existing fields...
  }
}
```

---

## 11. Frontend Changes

- Direction toggle: add `CBDC → Stablecoin` option
- Detect Anvil chain (chainId 31337), prompt switch if needed
- On `cbdc_to_stablecoin` submit: ERC20 approve INRDC → lockCBDC() on Anvil → confirmLock
- Compliance status badge: show on `/history` — "Compliant" / "Blocked"
- New `source_chain` / `dest_chain` display in transfer history

---

## 12. Environment Variables (New)

| Var | Purpose |
|-----|---------|
| `ANVIL_HTTP_URL` | Anvil local RPC (default: `http://localhost:8545`) |
| `CBDC_VAULT_CONTRACT` | CBDCVault address on Anvil |
| `STABLECOIN_BRIDGE_CONTRACT` | StablecoinBridge address on Amoy |
| `MOCK_CBDC_TOKEN` | MockCBDC ERC20 address on Anvil |
| `RELAYER_1_PRIVATE_KEY` | Relayer R1 signing key |
| `RELAYER_2_PRIVATE_KEY` | Relayer R2 signing key |
| `RELAYER_3_PRIVATE_KEY` | Relayer R3 signing key |

Existing `RELAYER_PRIVATE_KEY` retained for POC v1 flows.

---

## 13. Deployment (Dev)

Anvil runs as a background process alongside Phoenix + Next.js.

```
anvil --port 8545 --chain-id 31337 &
# Deploy contracts
cd contracts && forge script script/DeployPOCv2.s.sol --rpc-url http://localhost:8545 --broadcast
# Start Phoenix + Next.js
./dev.sh
```

`setup.sh` updated to start Anvil and deploy POC v2 contracts automatically.

---

## 14. Out of Scope (v2 POC)

- Real Corda / Hyperledger Fabric integration
- BLS aggregate signatures (ECDSA multi-sig used instead)
- Reverse flow (stablecoin_to_cbdc) relay
- On-chain light client proofs (event + block confirmation used instead)
- Fee collection
- Validator slashing / liveness penalties
- Production deployment
