# BharatSetu — POC v1 Specification

**Version:** 1.0  
**Status:** Implemented (retrospective spec)  
**Date:** 2026-04-20  
**Authors:** Ashutosh + Claude (co-development)

---

## 1. Goal

Build a trustless cross-chain bridge for carbon credit tokens between two EVM testnets:
- **Polygon Amoy** — tCCS (Test Carbon Credit Standard) token
- **Ethereum Sepolia** — wCCC (Wrapped Carbon Credit Certificate) token

Users lock tCCS on Amoy and receive wCCC on Sepolia (and vice versa), with no custodian holding funds. A server-side relayer observes on-chain events and executes the cross-chain mint/unlock.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Browser (Next.js 14)                                           │
│  RainbowKit + wagmi + viem                                      │
│  Pages: / (landing) · /bridge · /dashboard · /history          │
└──────────────────────────┬──────────────────────────────────────┘
                           │ REST + WebSocket (Phoenix)
┌──────────────────────────▼──────────────────────────────────────┐
│  Elixir Umbrella App (Phoenix 1.7)                              │
│  ├── bharat_web      — HTTP API + WebSocket channels            │
│  ├── bharat_core     — Business logic, indexers, relayer        │
│  ├── bharat_data     — PostgreSQL via Ecto                      │
│  ├── bharat_adapters — Blockchain RPC, KYC (mock), Pricing      │
│  └── bharat_relayer  — Cross-chain relay worker                 │
└──────────────┬──────────────────────────────┬───────────────────┘
               │ eth_getLogs (poll 3s)         │ eth_sendRawTransaction
┌──────────────▼──────────┐      ┌────────────▼──────────────────┐
│  Polygon Amoy           │      │  Ethereum Sepolia             │
│  LockBridge.sol         │      │  MintBridge.sol (= wCCC ERC20)│
│  - lockTokens()         │      │  - mintOnProof()              │
│  - unlock()             │      │  - burnAndBridge()            │
└─────────────────────────┘      └───────────────────────────────┘
```

---

## 3. Token Contracts

### 3.1 LockBridge.sol (Polygon Amoy)

**Purpose:** Escrow contract. Holds tCCS tokens locked by users. Releases them when relayer calls `unlock()`.

**State:**
```solidity
address public owner;
address public relayer;
bool public paused;
```

**Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `lockTokens(address token, uint256 amount, bytes32 transferId)` | public | Transfers tCCS from user into contract. Emits `TokensLocked`. |
| `unlock(address to, address token, uint256 amount, bytes32 transferId)` | onlyRelayer | Releases escrowed tCCS to recipient. Emits `TokensUnlocked`. |
| `pause()` / `unpause()` | onlyOwner | Emergency halt. |
| `setRelayer(address r)` | onlyOwner | Update relayer address. |

**Events:**
```solidity
event TokensLocked(address indexed wallet, address indexed token, uint256 amount, bytes32 nonceHash, bytes32 transferId);
event TokensUnlocked(address indexed wallet, address indexed token, uint256 amount, bytes32 nonceHash, bytes32 transferId);
```

**Guards:**
- `lockTokens`: reverts if paused, amount=0, or `transferFrom` returns false
- `unlock`: reverts if `msg.sender != relayer`, paused, or `transfer` returns false

### 3.2 MintBridge.sol (Ethereum Sepolia)

**Purpose:** ERC20 token contract for wCCC. Mints on lock proof, burns on bridge-back.

**State:**
```solidity
address public owner;
address public relayer;
bool public paused;
mapping(bytes32 => bool) public usedNonces;  // replay protection
```

**Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `mintOnProof(address to, bytes32 nonceHash, uint256 amount)` | onlyRelayer | Mints wCCC to recipient. Checks `usedNonces[nonceHash]`. |
| `burnAndBridge(uint256 amount, bytes32 transferId)` | public | Burns wCCC. Emits `TokensBurned`. Checks `usedNonces[transferId]`. |
| `pause()` / `unpause()` | onlyOwner | Emergency halt. |
| `setRelayer(address r)` | onlyOwner | Update relayer address. |

**Events:**
```solidity
event TokensMinted(address indexed wallet, uint256 amount, bytes32 nonceHash);
event TokensBurned(address indexed wallet, uint256 amount, bytes32 nonceHash, bytes32 transferId);
```

**Guards:**
- `mintOnProof`: reverts if `usedNonces[nonceHash]` already set
- `burnAndBridge`: reverts if `usedNonces[transferId]` already set (double-spend prevention)

---

## 4. Transfer State Machine

```
         POST /transfers
              │
           [init]  ←── InitTimeoutWorker expires after 10min if no lock_tx
              │
         user submits lock/burn tx on-chain
              │
           [locked]  ←── frontend calls POST /transfers/:id/lock
              │
         BlockchainIndexer / SepoliaIndexer confirms N blocks
              │
         [confirmed]
              │
         BharatRelayer.Worker mints/unlocks on destination chain
              │
          [minted]
              │
         destination indexer confirms mint/unlock event
              │
         [completed]

         Any state → [failed] on:
           - relay exhausts 3 attempts
           - user cancels (init + no lock_tx only)
           - init timeout (10 min, no tx submitted)
```

**State transitions:**

| From | To | Trigger |
|------|----|---------|
| init | locked | `POST /transfers/:id/lock` with tx_hash |
| init | failed | `DELETE /transfers/:id` (cancel) OR InitTimeoutWorker |
| locked | confirmed | BlockchainIndexer / SepoliaIndexer (after confirmation_depth blocks) |
| confirmed | minted | Relayer submits mint/unlock tx |
| minted | completed | Destination indexer confirms mint/unlock event |
| confirmed | failed | Relayer exhausts 3 relay_attempts |
| failed | confirmed | `POST /transfers/:id/retry` (relay-failed only) |

---

## 5. API Contract

**Base URL:** `http://localhost:4000/api/v1`  
**Auth:** JWT Bearer token (obtained via SIWE flow)

### 5.1 Authentication

#### `POST /auth/challenge`
```json
// Request
{ "wallet": "0xC792..." }

// Response 200
{ "nonce": "abc123", "domain": "localhost", "expiry": "2026-04-20T12:00:00Z" }
```

#### `POST /auth/verify`
```json
// Request
{ "message": "<EIP-4361 message string>", "signature": "0x..." }

// Response 200
{ "token": "<JWT>", "wallet": "0xC792..." }
```

### 5.2 Config

#### `GET /config` (public)
```json
{
  "data": {
    "lock_bridge": "0x461a...",
    "mint_bridge": "0x1ea3...",
    "tccs_token": "0x...",
    "amoy_chain_id": 80002,
    "sepolia_chain_id": 11155111
  }
}
```

### 5.3 Transfers

#### `POST /transfers` (auth + KYC)
```json
// Request
{ "token_address": "0x...", "amount": "100", "direction": "amoy_to_sepolia" }

// Response 201
{ "data": { "id": "uuid", "state": "init" } }
```

#### `GET /transfers` (auth)
```json
// Response 200
{ "data": [ ...Transfer[] ] }
```

#### `GET /transfers/:id` (auth)
```json
// Response 200
{ "data": Transfer }
```

#### `POST /transfers/:id/lock` (auth + KYC)
```json
// Request
{ "tx_hash": "0x5e29..." }

// Response 200
{ "data": { "id": "uuid", "state": "locked" } }

// Error 409 — already locked or completed
{ "error": "transfer already locked" }
```

#### `DELETE /transfers/:id` (auth + KYC)
```json
// Response 200
{ "data": { "id": "uuid", "state": "failed" } }

// Error 409 — not cancellable (already has lock_tx_hash or not in init)
{ "error": "transfer cannot be cancelled" }
```

#### `POST /transfers/:id/retry` (auth + KYC)
```json
// Response 200
{ "data": { "id": "uuid", "state": "confirmed" } }

// Error 409 — not relay-failed
{ "error": "transfer is not relay-failed" }
```

### 5.4 Prices

#### `GET /prices` (public)
```json
// Response 200
{ "data": { "BCT": 1.23, "NCT": 0.87, "GS": 2.10 } }
```

### 5.5 Health

#### `GET /health` (public)
```json
// Response 200
{ "status": "ok" }
```

---

## 6. Transfer Schema

```typescript
type Transfer = {
  id: string;                        // UUID v4
  wallet: string;                    // 0x address
  token_address: string;             // ERC20 token on source chain
  amount: string;                    // decimal string, no wei
  nonce_hash: string;                // keccak256(wallet ++ transferId)
  state: "init" | "locked" | "confirmed" | "minted" | "completed" | "failed";
  direction: "amoy_to_sepolia" | "sepolia_to_amoy";
  lock_tx_hash: string | null;       // source chain tx
  mint_tx_hash: string | null;       // destination chain tx
  failure_reason: string | null;
  relay_attempts: number;
  inserted_at: string;               // ISO 8601
  updated_at: string;
}
```

---

## 7. WebSocket Protocol

**Endpoint:** `ws://localhost:4000/socket/websocket?token=<JWT>`  
**Channel:** `transfer:<transfer_id>`

```json
// Server pushes on state change
{ "event": "state_update", "payload": { "state": "confirmed" } }

// Server pushes on init (amoy_to_sepolia)
{ "event": "await_lock", "payload": { "transfer_id": "uuid", "unsigned_tx": {...}, "nonce_hash": "0x..." } }

// Server pushes on init (sepolia_to_amoy)
{ "event": "await_burn", "payload": { "transfer_id": "uuid", "nonce_hash": "0x..." } }
```

---

## 8. Background Workers

| Worker | Schedule | Action |
|--------|----------|--------|
| `BlockchainIndexer` | every 3s | Poll Amoy for `TokensLocked` events, advance transfers to `confirmed` |
| `SepoliaIndexer` | every 3s | Poll Sepolia for `TokensBurned` events, advance transfers to `confirmed` |
| `BharatRelayer.Worker` | every 5s | Process `confirmed` transfers — mint on Sepolia or unlock on Amoy |
| `InitTimeoutWorker` | every 2min | Expire `init` transfers older than 10min with no `lock_tx_hash` |

**Confirmation depth:** 3 blocks (configurable via `CONFIRMATION_DEPTH` env var).  
**Relay max attempts:** 3. On exhaustion → state `failed`, `failure_reason` set.

---

## 9. Security Properties

| Property | Implementation |
|----------|---------------|
| Replay protection | `usedNonces[nonceHash]` in MintBridge; checked before every mint/burn |
| ERC20 transfer safety | All `transfer`/`transferFrom` return values checked; revert on false |
| Relayer exclusivity | `onlyRelayer` modifier on `mintOnProof` and `unlock` |
| Emergency pause | Both contracts pausable by owner |
| Secret management | `RELAYER_PRIVATE_KEY` in `.env` (gitignored), loaded via `runtime.exs` |
| JWT auth | Guardian-signed JWTs, cleared on 401 response |
| SIWE standard | EIP-4361 wallet authentication (off-chain signature, no gas) |
| Rate limiting | `RateLimit` plug on all API routes |

---

## 10. Frontend Pages

| Route | Auth required | Description |
|-------|--------------|-------------|
| `/` | No | Landing page — how it works, security guarantees, live BCT price |
| `/bridge` | Yes (redirect) | Main bridge UI — direction toggle, amount input, tx flow, real-time status |
| `/dashboard` | Yes (redirect) | Stats — total transfers, volume, BCT price, recent transfers table |
| `/history` | Yes (redirect) | Full transfer list — filter by state, explorer links, copy transfer ID |

---

## 11. Deployment (Dev)

**Prerequisites:** macOS or Ubuntu/Debian, or Windows with WSL2.  
**Single command:** `bash setup.sh` — installs all deps, runs DB migrations, starts all servers.  
**Dev restart:** `./dev.sh` — kills and restarts Phoenix + Next.js, loads `.env`.

**Services:**
| Service | Port |
|---------|------|
| Phoenix API | 4000 |
| Next.js frontend | 3000 |
| PostgreSQL | 5432 |

---

## 12. Out of Scope (v1)

- Mainnet deployment
- Trustless relayer (light client proofs / ZK)
- Multi-chain support beyond Amoy + Sepolia
- Validator node selection / decentralized relayer
- Token price oracle on-chain
- KYC integration (mock only)
- Fee collection
- Bridge liquidity management
- Monitoring / alerting
