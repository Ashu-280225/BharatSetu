# EVM ↔ Non-EVM Interoperability — BharatSetu Approach

**Date:** 2026-05-01  
**Status:** Design Proposal  
**Scope:** Ethereum/Polygon (EVM) ↔ Solana (non-EVM) bridge via zone-chain-escrow architecture

---

## 1. Context: Where We Are

BharatSetu POC v2 already bridges **two EVM chains** (Anvil CBDC ledger ↔ Polygon Amoy) using:
- MPT receipt proofs for trustless verification
- BlockHashOracle (2-of-3 relayer threshold) for block hash finality
- StablecoinBridge / CBDCVault for lock-and-mint
- Elixir FSM (TransferServer) for state orchestration
- PostgreSQL-checkpointed crash recovery

EVM ↔ EVM works because both sides speak the same proof format (RLP-encoded receipts, Merkle Patricia Trie, keccak256). Solana is fundamentally different — it has no concept of MPT proofs, uses Ed25519 keys (not secp256k1), and its account model bears no resemblance to EVM storage slots.

This document designs the extension: **EVM ↔ non-EVM (Solana)** interoperability.

---

## 2. Why This Approach (Architecture Rationale)

### 2.1 Why Not Direct EVM→Solana Proof Verification?

Solana programs cannot natively verify Ethereum MPT proofs because:
1. **Different hash functions**: Ethereum uses keccak256; Solana uses SHA-256/SHA-512 internally. Keccak256 is extremely expensive as a Solana program.
2. **No receipt concept**: Solana has no transaction receipt with a receiptsRoot. Finality is slot-based, not block-hash-based.
3. **Account model mismatch**: EVM has contract storage (key-value in MPT); Solana has Program Derived Addresses (PDAs) with flat byte buffers. Cannot map one to the other.
4. **Proof size**: MPT proofs can be 1–4 KB. Solana transaction size limit is 1232 bytes. Cannot fit in one transaction.

### 2.2 Why Zone + Chain + Escrow Architecture?

This mirrors **Cosmos IBC** (already in our production roadmap) but without requiring Tendermint/IBC on both sides:

```
[EVM Zone] ←→ [Intermediate Chain / Hub] ←→ [Solana Zone]
```

- **Zone** = a blockchain participating in the network (Ethereum, Polygon, Solana, Anvil CBDC ledger)
- **Chain** = the channel/path between two zones. Carries lock/unlock proofs and acknowledgements.
- **Escrow** = a program/contract on each zone that holds assets temporarily during in-flight transfers

The hub (our existing Elixir relayer cluster) acts as the **chain** — it is the trusted coordinator between zones. The zones themselves don't need to know about each other's proof formats. The hub translates.

### 2.3 Why Hub-and-Spoke (Not Direct Bilateral)?

If we did bilateral EVM↔Solana proofs:
- N chains → N² bilateral integrations
- Each pair needs custom proof format adapters

Hub-and-spoke:
- N chains → N integrations (each chain only talks to the hub)
- Hub contains all cross-chain translation logic
- Matches our existing BharatSetu architecture (Elixir hub already orchestrates Anvil + Amoy + Sepolia)

---

## 3. Architecture

### 3.1 Big Picture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         BharatSetu Hub (Elixir)                      │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │TransferServer│  │ EVMIndexer   │  │SolanaIndexer │  │Relayers  │ │
│  │FSM (per tx) │  │(eth_getLogs) │  │(websocket    │  │R1,R2,R3  │ │
│  │             │  │              │  │ subscription)│  │          │ │
│  └─────────────┘  └──────────────┘  └──────────────┘  └──────────┘ │
│                              │ Phoenix.PubSub                        │
└──────────────────────────────┼──────────────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
        ▼                      ▼                      ▼
┌──────────────┐      ┌──────────────┐      ┌──────────────────┐
│  EVM Zone    │      │  CBDC Zone   │      │  Solana Zone     │
│  (Polygon    │      │  (Anvil)     │      │  (Devnet/        │
│   Amoy/      │      │              │      │   Mainnet-beta)  │
│   Sepolia)   │      │ CBDCVault.sol│      │                  │
│              │      │ MockCBDC.sol │      │ EscrowProgram    │
│EVMEscrow.sol │      │              │      │ (Rust/Anchor)    │
│(new)         │      │              │      │                  │
└──────────────┘      └──────────────┘      └──────────────────┘
```

### 3.2 Zone Definitions

| Zone ID | Chain | Proof Mechanism | Asset Standard |
|---------|-------|-----------------|---------------|
| `evm:amoy` | Polygon Amoy | MPT receipt proof + BlockHashOracle | ERC-20 |
| `evm:sepolia` | Ethereum Sepolia | MPT receipt proof | ERC-20 |
| `cbdc:anvil` | Anvil (private) | MPT receipt proof (local) | MockCBDC (ERC-20) |
| `sol:devnet` | Solana Devnet | Log subscription + PDA state | SPL Token |

### 3.3 Chain (Channel) Definition

A **channel** is a bidirectional path between two zones. The hub maintains channel state:

```elixir
# In bharat_data: channels table
%Channel{
  id: "evm:amoy<>sol:devnet",
  zone_a: "evm:amoy",
  zone_b: "sol:devnet",
  escrow_a: "0xABCD...",        # EVMEscrow contract address
  escrow_b: "SolEscrow111...",  # Solana PDA address
  status: :active,
  created_at: ...
}
```

### 3.4 Escrow Architecture

**EVM side** — `EVMEscrow.sol` (new contract):
```solidity
// Lock tokens for cross-chain transfer to any zone (not just another EVM chain)
function lockForZone(
    address token,
    uint256 amount,
    bytes32 transferId,
    string calldata destinationZone,   // "sol:devnet"
    bytes calldata destinationAddress, // Solana public key (32 bytes)
    bytes calldata metadata            // arbitrary instruction payload
) external;

function unlockFromZone(
    address token,
    address recipient,
    uint256 amount,
    bytes32 transferId
) external onlyRelayer;

event TokensLockedForZone(
    bytes32 indexed transferId,
    address indexed token,
    uint256 amount,
    string destinationZone,
    bytes destinationAddress,
    bytes metadata
);
```

**Solana side** — `EscrowProgram` (Rust/Anchor):
```rust
// PDA-based escrow — program owns tokens during transfer
// Account structure:
//   EscrowState PDA: seeds = ["escrow", transfer_id]
//   Escrow Token Account: SPL token account owned by EscrowState PDA

pub struct EscrowState {
    pub transfer_id: [u8; 32],      // matches EVM transferId
    pub source_zone: String,         // "evm:amoy"
    pub source_address: Vec<u8>,     // EVM sender address (20 bytes)
    pub beneficiary: Pubkey,         // Solana recipient
    pub amount: u64,
    pub mint: Pubkey,                // SPL token mint
    pub status: EscrowStatus,        // Locked | Released | Refunded
    pub created_at: i64,
}

// Instructions:
// - initialize_escrow(transfer_id, amount, beneficiary, source_zone, source_address)
// - release_to_beneficiary(transfer_id) — relayer-signed
// - refund_to_source(transfer_id) — timeout fallback
// - lock_for_evm(amount, transfer_id, destination_zone, destination_address) — Solana→EVM
```

---

## 4. Transfer Flows

### 4.1 EVM → Solana (Forward)

```
[User - EVM]                [Hub - Elixir]                [Solana]

1. Call EVMEscrow.lockForZone(
     token=INRX,
     amount=100,
     transferId=0xABC,
     destinationZone="sol:devnet",
     destinationAddress=<solana_pubkey_32_bytes>
   )

2. EVMIndexer detects TokensLockedForZone
   ↓ confirms at ≥12 blocks
   
3. TransferServer FSM:
   init → locked → confirmed
   
4. Relayers R1,R2,R3:
   - Decode event from EVM
   - Translate: amount, destinationAddress, transferId
   - Call Solana EscrowProgram.release_to_beneficiary()
     (or initialize escrow first if mint-based)
   
   NOTE: No MPT proof to Solana (can't verify).
   Trust model: hub relayer cluster (2-of-3)
   
5. SolanaIndexer confirms release on Solana

6. FSM: confirmed → released → completed

7. Phoenix Channel broadcasts completion to frontend
```

**Trust model for EVM→Solana:** The hub relayer cluster is the trust anchor. We cannot send MPT proofs to Solana efficiently. Mitigation: 2-of-3 threshold signing on the Solana release instruction (multisig relayer PDA).

### 4.2 Solana → EVM (Reverse)

```
[User - Solana]              [Hub - Elixir]              [EVM]

1. Call EscrowProgram.lock_for_evm(
     amount=100,
     transferId=<uuid>,
     destinationZone="evm:amoy",
     destinationAddress=<eth_address_20_bytes>
   )
   → SPL tokens locked in escrow PDA

2. SolanaIndexer detects lock event
   (Solana log subscription: "Program log: BHARAT_LOCK ...")
   ↓ confirms at ≥32 slots (Solana finality ~400ms/slot)
   
3. TransferServer FSM:
   init → locked → confirmed
   
4. Relayers:
   - Verify Solana PDA state (read escrow account)
   - Build Solana "proof": escrow PDA account data + slot number
   - Call EVMEscrow.unlockFromZone(token, recipient, amount, transferId)
   
5. EVMIndexer confirms unlock on EVM

6. FSM: confirmed → unlocked → completed
```

**Trust model for Solana→EVM:** Two options:
- **Option A (Simple, current):** Hub relayer 2-of-3 multisig on EVM unlock. Hub reads Solana PDA state and collectively authorizes.
- **Option B (Stronger, future):** Deploy an ed25519 signature verifier on EVM (EIP-665 precompile exists). Solana relayers sign the escrow state with their ed25519 keys; EVM contract verifies the aggregate signature. Eliminates trust in hub software — only trust in hub key management.

---

## 5. Problems We Will Face

### 5.1 Proof Format Incompatibility (Critical)

**Problem:** Solana has no MPT receipts. Our entire POC v2 security model depends on `StablecoinBridge.executeWithProof()` verifying an MPT receipt proof. This cannot be replicated on Solana side.

**Mitigation (brief):**
- EVM→Solana: relayer cluster is the proof. Solana program checks that ≥2 of 3 authorized relayer PDAs have signed the release. No cryptographic proof of EVM state, but economic/social trust in relayer cluster.
- Solana→EVM: EVM contract reads relayer-attested escrow state. Future: ed25519 aggregate signature verification on EVM using Solana validator signatures (validators sign confirmed slots).

**What we lose:** The MPT proof model is "verify anything without trusting the relayer." In EVM↔Solana, we partially trust the relayer cluster. This is acceptable for POC but must be hardened for production.

**Full Solution:**

*POC (now):* Replace MPT proof with **2-of-3 relayer multisig PDA** on Solana.

```rust
// In EscrowProgram — release instruction checks multisig
#[derive(Accounts)]
pub struct ReleaseToBeneficiary<'info> {
    #[account(mut, seeds = [b"escrow", escrow_state.transfer_id.as_ref()], bump)]
    pub escrow_state: Account<'info, EscrowState>,
    
    // Multisig PDA: created from R1+R2+R3 pubkeys at deploy time
    #[account(address = RELAYER_MULTISIG_PDA)]
    pub relayer_authority: AccountInfo<'info>,
    
    // Requires signature from relayer_authority
    pub signer: Signer<'info>,
}

// Hub builds a Solana tx signed by ≥2 relayer keypairs via squads-protocol multisig
// or native SPL Governance multisig
```

*Production (future):* **ZK light client** — generate a Groth16/Plonk proof that:
1. A specific Ethereum block was finalized (uses sync committee signatures — EIP-4881)
2. A specific receipt exists in that block's receiptsRoot (MPT path)
3. That receipt contains a `TokensLockedForZone` log

Submit this ZK proof to a Solana verifier program (Groth16 verifier exists as Solana program — `light-protocol/groth16-verifier`). Eliminates relayer trust entirely. Cost: ~$0.002 per proof on Solana, 2–5 min proof generation. Acceptable for large transfers.

Migration path: POC uses multisig → production upgrades to ZK verifier without changing escrow state structure (just swap the `release` instruction authority check).

### 5.2 Key Format Mismatch

**Problem:** 
- EVM addresses: 20-byte secp256k1-derived, hex-encoded `0x...`
- Solana addresses: 32-byte ed25519 public keys, base58-encoded

**Mitigation (brief):**
- Pass Solana address as `bytes` (32 bytes) in EVM contract, not as a string
- Hub translates: `bytes32 solanaAddress` ↔ `Pubkey` (Solana's native type)
- Store mapping in DB: `address_mappings` table (evm_address, solana_address, user_id, verified_at)
- Frontend: user must connect both EVM wallet (MetaMask/wagmi) and Solana wallet (Phantom/Solana wallet adapter)

New frontend work: add Solana wallet adapter alongside existing wagmi. Users sign with both wallets to prove ownership.

**Full Solution:**

*Contract layer:* `EVMEscrow.sol` accepts `bytes32 destinationAddress`. No string parsing on-chain, no gas wasted on encoding.

```solidity
// EVMEscrow.sol
event TokensLockedForZone(
    bytes32 indexed transferId,
    address indexed token,
    uint256 amount,
    string destinationZone,
    bytes32 destinationAddress,  // raw 32 bytes — Solana pubkey
    bytes metadata
);
```

*Hub translation layer:*
```elixir
# apps/bharat_core/lib/bharat_core/bridge/zone_translator.ex
defmodule BharatCore.Bridge.AddressCodec do
  # bytes32 from EVM event → Base58 string for Solana RPC calls
  def evm_bytes_to_solana(<<bytes::binary-size(32)>>) do
    Base58.encode(bytes)  # use :b58 hex library
  end

  # Solana Base58 pubkey → bytes32 for EVM contract calls
  def solana_to_evm_bytes(base58_str) do
    Base58.decode!(base58_str)  # always 32 bytes for valid Solana pubkey
  end
  
  # EVM hex address (20 bytes) → padded bytes32 for Solana storage
  def evm_address_to_bytes32("0x" <> hex) do
    <<0::96, Base.decode16!(hex, case: :mixed)::binary>>
  end
end
```

*Address mapping verification flow:*
```
1. User opens bridge UI
2. Frontend: connect MetaMask → get evm_address
3. Frontend: connect Phantom → get solana_address
4. Frontend calls POST /api/address-mappings/verify with:
   {
     evm_address: "0x...",
     solana_address: "ABC...",
     evm_signature: sign("Link EVM:0x... to Solana:ABC..."),   // MetaMask personal_sign
     solana_signature: sign("Link EVM:0x... to Solana:ABC...")  // Phantom signMessage
   }
5. Hub verifies both signatures → stores in address_mappings table
6. Transfer API checks address_mappings.verified_at before initiating cross-zone transfer
```

*Verification code in hub:*
```elixir
defmodule BharatCore.Auth.CrossChainVerifier do
  def verify_address_mapping(evm_address, solana_address, evm_sig, solana_sig) do
    message = "Link EVM:#{evm_address} to Solana:#{solana_address}"
    
    with :ok <- verify_evm_sig(message, evm_address, evm_sig),   # existing SIWE-style verify
         :ok <- verify_solana_sig(message, solana_address, solana_sig) do
      {:ok, :verified}
    end
  end
  
  defp verify_solana_sig(message, pubkey_b58, signature_b58) do
    # ed25519 verify: use :crypto.verify(:eddsa, :ed25519, message, sig, pubkey)
    pubkey = Base58.decode!(pubkey_b58)
    sig = Base58.decode!(signature_b58)
    msg_bytes = message |> :erlang.binary_to_list() |> :erlang.list_to_binary()
    case :crypto.verify(:eddsa, :ed25519, msg_bytes, sig, [pubkey, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_solana_signature}
    end
  end
end
```

`:crypto.verify(:eddsa, :ed25519, ...)` is native in Erlang/OTP 24+. No external deps needed.

### 5.3 Solana Indexer (No eth_getLogs Equivalent)

**Problem:** Our EVMIndexer/AnvilIndexer use `eth_getLogs` with topic filters. Solana has no equivalent. Solana uses account-based indexing or websocket log subscriptions.

**Mitigation (brief):** New `SolanaIndexer` GenServer using `getSignaturesForAddress` polling + websocket fallback.

**Full Solution:**

Two-track indexing — websocket for real-time, HTTP polling for crash recovery (mirrors how existing `BlockchainIndexer` handles reorgs):

```elixir
defmodule BharatAdapters.Blockchain.SolanaIndexer do
  use GenServer
  require Logger

  @poll_interval_ms 1_000
  @finality_slots 32

  def init(opts) do
    program_id = Keyword.fetch!(opts, :program_id)
    state = %{
      program_id: program_id,
      last_signature: load_checkpoint("solana_devnet"),  # from IndexerCheckpoint
      ws_pid: nil
    }
    # Track 1: HTTP polling (crash-safe, always runs)
    schedule_poll()
    # Track 2: Websocket subscription (low-latency, reconnects on drop)
    {:ok, ws_pid} = start_ws_subscription(program_id)
    {:ok, %{state | ws_pid: ws_pid}}
  end

  # HTTP polling — runs every 1s regardless of websocket state
  def handle_info(:poll, state) do
    sigs = fetch_new_signatures(state.program_id, state.last_signature)
    
    confirmed = sigs
      |> Enum.filter(&finalized?(&1.slot))      # slot + 32 elapsed
      |> Enum.map(&parse_escrow_event/1)
      |> Enum.reject(&is_nil/1)
    
    Enum.each(confirmed, &dispatch_event/1)
    
    new_last = List.first(sigs, %{signature: state.last_signature}).signature
    save_checkpoint("solana_devnet", new_last)   # IndexerCheckpoint upsert
    schedule_poll()
    {:noreply, %{state | last_signature: new_last}}
  end

  # Websocket message — fast path, deduped by FSM transfer_id
  def handle_info({:ws_log, log_notification}, state) do
    case parse_anchor_log(log_notification) do
      {:ok, event} -> dispatch_event(event)   # may arrive before HTTP poll — FSM dedupes
      :skip -> :ok
    end
    {:noreply, state}
  end

  # Websocket dropped — reconnect with exponential backoff
  def handle_info({:ws_down, reason}, state) do
    Logger.warning("SolanaIndexer WS dropped: #{inspect(reason)}, reconnecting...")
    Process.send_after(self(), :reconnect_ws, backoff(state))
    {:noreply, %{state | ws_pid: nil}}
  end

  defp fetch_new_signatures(program_id, until_sig) do
    # POST /  method: getSignaturesForAddress
    # params: [program_id, {limit: 100, until: until_sig, commitment: "finalized"}]
    BharatAdapters.Blockchain.SolanaRpc.get_signatures_for_address(
      program_id, until: until_sig, commitment: "finalized"
    )
  end

  defp finalized?(slot) do
    # Check current slot — if current_slot >= event_slot + 32, treat as final
    {:ok, current_slot} = BharatAdapters.Blockchain.SolanaRpc.get_slot("finalized")
    current_slot >= slot + @finality_slots
  end

  defp parse_anchor_log(notification) do
    # Anchor emits base64-encoded discriminated events in program logs:
    # "Program log: BHARAT_LOCK <base64>"
    # Decode → match discriminator (first 8 bytes = sha256("event:EscrowLocked")[0..7])
    # Deserialize remaining bytes as Borsh-encoded EscrowLocked struct
    with "Program log: BHARAT_" <> rest <- notification,
         [type, b64] <- String.split(rest, " ", parts: 2),
         {:ok, raw} <- Base.decode64(b64),
         {:ok, event} <- BharatAdapters.Blockchain.AnchorEventParser.parse(type, raw) do
      {:ok, event}
    else
      _ -> :skip
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
```

*Anchor event discriminators* — deterministic, computed at compile time:
```elixir
defmodule BharatAdapters.Blockchain.AnchorEventParser do
  # Discriminator = first 8 bytes of SHA256("event:<EventName>")
  @escrow_locked_disc :crypto.hash(:sha256, "event:EscrowLocked") |> binary_part(0, 8)
  @escrow_released_disc :crypto.hash(:sha256, "event:EscrowReleased") |> binary_part(0, 8)

  def parse("LOCK", <<@escrow_locked_disc, rest::binary>>) do
    # Borsh decode: transfer_id(32), amount(u64), beneficiary(32), source_zone(string)
    {:ok, decode_escrow_locked(rest)}
  end
  def parse("RELEASE", <<@escrow_released_disc, rest::binary>>) do
    {:ok, decode_escrow_released(rest)}
  end
  def parse(_, _), do: {:error, :unknown_event}
end
```

*Reconnect with backoff* — websocket drops treated as non-fatal; HTTP polling continues during outage:
```elixir
defp backoff(%{ws_retries: n}), do: min(1_000 * :math.pow(2, n) |> round(), 30_000)
```

Solana public RPC rate limits (~100 req/s) can be hit under load. Use a dedicated RPC node (QuickNode/Helius) in production — add `SOLANA_RPC_URL` to `runtime.exs`.

### 5.4 Amount Precision Mismatch

**Problem:**
- EVM ERC-20: 18 decimal places (1 INRX = 1e18 wei)
- Solana SPL Token: configurable decimals, typically 6 or 9

1 INRX (EVM) = 1_000_000_000_000_000_000 (18 decimals)  
1 INRX (Solana) = 1_000_000 (6 decimals)

**Mitigation (brief):** Hub normalizes amounts. Minimum transfer enforced at API.

**Full Solution:**

```elixir
defmodule BharatCore.Bridge.AmountNormalizer do
  # Use integer arithmetic only — never floats for financial amounts
  
  def evm_to_solana(amount_wei, evm_decimals \\ 18, spl_decimals \\ 6) do
    diff = evm_decimals - spl_decimals  # 12
    divisor = Integer.pow(10, diff)     # 1_000_000_000_000
    
    spl_amount = div(amount_wei, divisor)
    dust = rem(amount_wei, divisor)     # leftover wei that can't cross
    
    {spl_amount, dust}
    # caller must refund dust to user on EVM side, or reject if spl_amount == 0
  end
  
  def solana_to_evm(amount_spl, spl_decimals \\ 6, evm_decimals \\ 18) do
    diff = evm_decimals - spl_decimals
    multiplier = Integer.pow(10, diff)
    amount_spl * multiplier  # exact, no loss
  end
  
  # Minimum transfer: 1 SPL unit = 1_000_000_000_000 wei (0.000001 INRX)
  def min_evm_amount(spl_decimals \\ 6, evm_decimals \\ 18) do
    Integer.pow(10, evm_decimals - spl_decimals)
  end
end
```

*Dust handling in EVMEscrow.sol:*
```solidity
function lockForZone(address token, uint256 amount, ...) external {
    uint256 PRECISION_FACTOR = 1e12;  // 18 - 6 decimals
    require(amount >= PRECISION_FACTOR, "Amount below minimum (1e12 wei)");
    
    // Round down to SPL-representable amount, refund dust immediately
    uint256 transferable = (amount / PRECISION_FACTOR) * PRECISION_FACTOR;
    uint256 dust = amount - transferable;
    
    IERC20(token).transferFrom(msg.sender, address(this), transferable);
    if (dust > 0) {
        IERC20(token).transferFrom(msg.sender, msg.sender, 0); // no-op, dust stays in user wallet
        // Actually: only pull transferable amount, user keeps dust
    }
    
    emit TokensLockedForZone(transferId, token, transferable, destinationZone, destinationAddress, metadata);
}
```

Frontend shows: "You will receive X.XXXXXX wINRX (dust < 0.000001 INRX returned)" before confirmation.

*No floating point anywhere in the stack.* Elixir `Decimal` library if display formatting needed.

### 5.5 Transaction Finality Difference

**Problem:**
- Ethereum/Polygon: finality at ~12 blocks (~24s on Amoy)
- Solana: optimistic confirmation ~400ms, finalized at ~32 slots (~13s)

Solana is faster but has different fork risk. Solana forks are rarer but when they occur, "confirmed" transactions can roll back.

**Mitigation (brief):** Wait for `finalized` commitment on Solana→EVM path. Track `solana_slot` + `solana_commitment` in DB.

**Full Solution:**

*Finality state machine for Solana-sourced transfers:*

```
EVM-sourced:    init → evm_locked(12 blocks) → confirmed → sol_released → completed
Solana-sourced: init → sol_locked(slot N) → sol_finalized(slot N+32) → evm_unlocked → completed
```

Two-stage Solana confirmation check in `SolanaIndexer`:

```elixir
defp check_finality(signature, lock_slot) do
  # Stage 1: transaction exists and is "confirmed" (optimistic, ~0.4s)
  # Stage 2: transaction slot is below the "finalized" slot (~13s, 32 slots back)
  
  {:ok, finalized_slot} = SolanaRpc.get_slot("finalized")
  
  cond do
    finalized_slot >= lock_slot + 32 ->
      :finalized   # safe to trigger EVM release
      
    finalized_slot >= lock_slot ->
      :confirmed   # wait — slot confirmed but not yet finalized checkpoint
      
    true ->
      :pending     # still processing
  end
end
```

*Why not use Solana's `"finalized"` commitment on `getTransaction` directly?*  
Solana RPC nodes sometimes lag their own finalized slot by a few slots under load. Checking `current_finalized_slot >= lock_slot + 32` is more reliable than trusting the commitment label on a single RPC call.

*Transfer schema columns:*
```sql
ALTER TABLE transfers ADD COLUMN solana_slot BIGINT;
ALTER TABLE transfers ADD COLUMN solana_finalized_at TIMESTAMP;
-- solana_commitment column not needed — we only act on finalized, never on confirmed
```

*Frontend UX:* Show a two-step progress bar for Solana→EVM:
- Step 1: "Solana transaction confirmed (~1s)"
- Step 2: "Waiting for Solana finality (~13s)"
- Step 3: "Releasing on EVM (~25s)"

Total: ~40s end-to-end, faster than EVM→EVM (~50s). Surface this as a feature, not a delay.

### 5.6 Solana Program Size & Complexity Limits

**Problem:** Solana programs have:
- Max 10MB deployed size (OK for Anchor programs)
- Max 1232 bytes per transaction
- Compute unit limit per transaction (~200K CU default, 1.4M max with request)
- Cannot pass large proofs in a single transaction

MPT proofs (1-4KB) cannot fit in one Solana transaction.

**Mitigation (brief):** No MPT proofs sent to Solana. Relayer multisig fits in 192 bytes.

**Full Solution:**

*Transaction size budget for `release_to_beneficiary`:*

| Field | Size |
|-------|------|
| Instruction discriminator | 8 bytes |
| transfer_id | 32 bytes |
| 3 relayer signatures (multisig) | 192 bytes |
| Account metas (6 accounts) | 6 × 32 = 192 bytes |
| Other headers | ~50 bytes |
| **Total** | **~474 bytes** ✓ well within 1232 |

*Compute unit budget:* Anchor release instruction does:
- 1 account deserialization (~3K CU)
- 1 multisig signature check (~5K CU per sig × 3 = 15K CU)
- 1 SPL token transfer (~5K CU)
- **Total: ~23K CU** — far below 200K default limit

Set explicit CU limit in relayer tx to 50K (safety margin) and request priority fee during congestion:

```typescript
// In Node.js relayer (signed tx submission)
const modifyComputeUnits = ComputeBudgetProgram.setComputeUnitLimit({ units: 50_000 });
const addPriorityFee = ComputeBudgetProgram.setComputeUnitPrice({ microLamports: 1_000 });
// prepend both instructions to release transaction
```

*If future ZK proof verification is added (Groth16):* Groth16 on Solana uses ~800K CU. Must request extended CU limit with `setComputeUnitLimit({ units: 1_400_000 })` and pay higher priority fee. Still one transaction — ZK verifier programs are optimized for this.

### 5.7 SPL Token vs ERC-20: Mint Authority

**Problem:**
- EVM: `StablecoinBridge` has MINTER_ROLE on INRX token. It calls `mint()` on success.
- Solana: Mint authority is a single Pubkey or a multisig. The EscrowProgram PDA needs to be the mint authority for a wrapped token, OR it holds a reserve of pre-minted tokens.

**Two models for Solana side:**
- **Lock-and-mint (preferred for trustlessness):** EscrowProgram PDA is mint authority of wINRX (wrapped INRX SPL token). On EVM lock → Hub signals → EscrowProgram mints wINRX to beneficiary. Reverse: burn wINRX → Hub signals → EVMEscrow releases INRX.
- **Reserve pool:** Pre-mint a large supply of wINRX, lock in EscrowProgram. On EVM lock → release from reserve. Simpler but requires pre-funded reserve.

**Recommendation:** Lock-and-mint for production. Reserve pool for POC (simpler to deploy).

**Full Solution:**

*POC — Reserve Pool setup:*
```bash
# Deploy wINRX SPL token, mint 1M to EscrowProgram's token account
spl-token create-token --decimals 6
spl-token create-account <MINT>
spl-token mint <MINT> 1000000 <ESCROW_TOKEN_ACCOUNT>
# Transfer mint authority to null (freeze supply) OR keep for top-ups
spl-token authorize <MINT> mint --disable
```

EscrowProgram holds the reserve. Release instruction transfers from reserve to beneficiary. No minting logic needed in program for POC.

*Production — Lock-and-Mint:*
```rust
// EscrowProgram owns mint authority via PDA
// Mint authority = PDA derived from program_id + "mint_authority"

#[derive(Accounts)]
pub struct ReleaseToBeneficiary<'info> {
    #[account(mut)]
    pub winrx_mint: Account<'info, Mint>,
    
    #[account(mut)]
    pub beneficiary_token_account: Account<'info, TokenAccount>,
    
    // PDA is the mint authority — program signs via invoke_signed
    #[account(seeds = [b"mint_authority"], bump)]
    pub mint_authority: AccountInfo<'info>,
    
    pub token_program: Program<'info, Token>,
}

// In release instruction:
token::mint_to(
    CpiContext::new_with_signer(
        ctx.accounts.token_program.to_account_info(),
        MintTo {
            mint: ctx.accounts.winrx_mint.to_account_info(),
            to: ctx.accounts.beneficiary_token_account.to_account_info(),
            authority: ctx.accounts.mint_authority.to_account_info(),
        },
        &[&[b"mint_authority", &[bump]]],  // PDA signs via program
    ),
    amount_spl,
)?;
```

*Reverse flow (Solana→EVM):* User burns wINRX via `lock_for_evm` instruction:
```rust
// Burns wINRX from user, records EscrowState for hub to process
token::burn(
    CpiContext::new(ctx.accounts.token_program.to_account_info(), Burn {
        mint: ctx.accounts.winrx_mint.to_account_info(),
        from: ctx.accounts.user_token_account.to_account_info(),
        authority: ctx.accounts.user.to_account_info(),
    }),
    amount,
)?;
// Emit EscrowLocked event → SolanaIndexer picks it up → hub calls EVMEscrow.unlockFromZone
```

*Mint authority upgrade authority:* After deploy, set `mint.freeze_authority = None` and `mint.mint_authority = escrow_pda`. The upgrade authority of the Solana program itself should be set to a governance multisig, not a hot wallet.

### 5.8 Hub Becomes Single Point of Failure

**Problem:** In EVM↔EVM, the MPT proof means even if the hub is down, the proof remains valid forever and can be submitted manually. In EVM↔Solana, the hub relayer cluster is the trust anchor. If all 3 relayers are down, transfers are stuck.

**Mitigation (brief):** Timeout + permissionless refund on both chains. Users self-serve after 1 hour.

**Full Solution:**

*EVM — permissionless refund after timeout:*
```solidity
// EVMEscrow.sol
uint256 public constant TIMEOUT = 1 hours;

struct Lock {
    address token;
    uint256 amount;
    address sender;
    uint256 lockedAt;
    bool released;
}
mapping(bytes32 => Lock) public locks;

function refundAfterTimeout(bytes32 transferId) external {
    Lock storage lock = locks[transferId];
    require(!lock.released, "Already released");
    require(block.timestamp >= lock.lockedAt + TIMEOUT, "Not timed out yet");
    
    lock.released = true;  // re-entrancy guard
    IERC20(lock.token).transfer(lock.sender, lock.amount);
    emit RefundIssued(transferId, lock.sender, lock.amount);
}
```

No relayer needed. Any caller can trigger. User calls from frontend if stuck.

*Solana — permissionless refund:*
```rust
// EscrowProgram refund_to_source instruction
// Anyone can call after timeout; refunds to original depositor
pub fn refund_to_source(ctx: Context<RefundToSource>) -> Result<()> {
    let escrow = &mut ctx.accounts.escrow_state;
    let clock = Clock::get()?;
    
    require!(escrow.status == EscrowStatus::Locked, EscrowError::NotLocked);
    require!(
        clock.unix_timestamp >= escrow.created_at + 3600,  // 1 hour
        EscrowError::NotTimedOut
    );
    
    escrow.status = EscrowStatus::Refunded;
    
    // Transfer SPL tokens back to depositor
    token::transfer(
        CpiContext::new_with_signer(..., &[&[b"escrow", escrow.transfer_id.as_ref(), &[bump]]]),
        escrow.amount,
    )?;
    
    emit!(EscrowRefunded { transfer_id: escrow.transfer_id, amount: escrow.amount });
    Ok(())
}
```

*Hub-side: FSM timeout handler:*
```elixir
# TransferServer — periodic timeout check (already has crash recovery)
defp check_timeout(%{state: :locked, locked_at: locked_at, transfer_type: :cross_zone} = transfer) do
  if DateTime.diff(DateTime.utc_now(), locked_at, :second) > 3600 do
    # Hub attempts refund (belt-and-suspenders with on-chain timeout)
    # If hub is down, user can call on-chain directly
    TransferServer.transition(transfer.id, :timeout_refund)
  end
end
```

*Dashboard UX:* Show "Refund Available" button after 1 hour if status still `:locked`. Button calls `POST /api/transfers/:id/refund` which triggers hub refund OR shows user the on-chain refund call data if hub is unreachable.

*Hub HA (prevents SPOF in practice):* Run R1, R2, R3 on separate VMs/regions. All three independently poll and process. If any one is alive, transfers complete. Hub only fully fails if all 3 crash simultaneously.

### 5.9 Frontend: Dual Wallet Requirement

**Problem:** User needs both an EVM wallet (MetaMask) and a Solana wallet (Phantom) connected simultaneously. Current frontend only has wagmi (EVM only).

**Mitigation (brief):** Add `@solana/wallet-adapter-react` alongside wagmi.

**Full Solution:**

*Provider setup (`apps/frontend/app/providers.tsx`):*
```tsx
'use client';
import { WagmiProvider } from 'wagmi';
import { RainbowKitProvider } from '@rainbow-me/rainbowkit';
import { ConnectionProvider, WalletProvider } from '@solana/wallet-adapter-react';
import { WalletModalProvider } from '@solana/wallet-adapter-react-ui';
import { PhantomWalletAdapter, BackpackWalletAdapter } from '@solana/wallet-adapter-wallets';
import { wagmiConfig, solanaRpcUrl } from '@/lib/config';

const solanaWallets = [new PhantomWalletAdapter(), new BackpackWalletAdapter()];

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <ConnectionProvider endpoint={solanaRpcUrl}>
        <WalletProvider wallets={solanaWallets} autoConnect>
          <WalletModalProvider>
            <RainbowKitProvider>
              {children}
            </RainbowKitProvider>
          </WalletModalProvider>
        </WalletProvider>
      </ConnectionProvider>
    </WagmiProvider>
  );
}
```

*Bridge form — conditional wallet requirement:*
```tsx
// apps/frontend/app/bridge/page.tsx
const { address: evmAddress } = useAccount();             // wagmi
const { publicKey: solanaAddress } = useWallet();          // solana adapter
const direction = useTransferDirection();                   // "evm_to_sol" | "sol_to_evm" | "evm_to_evm"

const isCrossZone = direction.includes('sol');
const evmReady = !!evmAddress;
const solanaReady = !!solanaAddress;
const canSubmit = isCrossZone ? (evmReady && solanaReady) : evmReady;

// UI shows wallet connect buttons contextually:
// EVM→EVM: only "Connect EVM Wallet"
// EVM→Solana: "Connect EVM Wallet" + "Connect Solana Wallet"
// Solana→EVM: "Connect Solana Wallet" + "Connect EVM Wallet" (for receiving)
```

*Address mapping verification flow in UI:*
```tsx
// After both wallets connected, verify mapping before first cross-zone transfer
async function verifyAddressMapping() {
  const message = `Link EVM:${evmAddress} to Solana:${solanaAddress.toBase58()}`;
  
  const evmSig = await signMessageAsync({ message });        // wagmi
  const solanaSig = await signMessage(Buffer.from(message)); // solana adapter
  
  await api.post('/address-mappings/verify', {
    evm_address: evmAddress,
    solana_address: solanaAddress.toBase58(),
    evm_signature: evmSig,
    solana_signature: Buffer.from(solanaSig).toString('base64'),
  });
}
```

*Package additions:*
```json
{
  "@solana/wallet-adapter-base": "^0.9.23",
  "@solana/wallet-adapter-react": "^0.15.35",
  "@solana/wallet-adapter-react-ui": "^0.9.35",
  "@solana/wallet-adapter-wallets": "^0.19.32",
  "@solana/web3.js": "^1.95.4"
}
```

Note: `@solana/web3.js` v2 (breaking API change) is not yet supported by wallet adapter. Use v1 for now.

### 5.10 Address Verification / Replay Protection

**Problem:** On EVM, `msg.sender` proves the caller owns the key. On Solana, the program sees a signed transaction from a Pubkey. Cross-chain: how does EVM contract know the Solana address is really controlled by the person locking funds on EVM?

**Mitigation (brief):** Dual-signature address mapping. User signs linking message with both wallets. Hub verifies both before allowing transfer.

**Full Solution:**

Three attack vectors addressed:

**Attack 1: Redirected destination** — Alice locks on EVM, specifies Bob's Solana address as destination.  
Fix: Require verified `address_mappings` entry where `evm_address = msg.sender` AND `solana_address = destinationAddress`. If no mapping exists or mapping belongs to a different user, reject at API layer.

```elixir
# BharatWeb.TransferController (before creating transfer)
defp validate_cross_zone_mapping(evm_address, solana_address) do
  case Repo.get_by(AddressMapping, evm_address: evm_address, solana_address: solana_address) do
    nil -> {:error, :no_verified_mapping}
    %{verified_at: nil} -> {:error, :mapping_not_verified}
    %{verified_at: _} -> :ok
  end
end
```

**Attack 2: Signature replay** — Eve captures Alice's `(evm_sig, solana_sig)` pair from one mapping attempt and replays it to create a mapping for a different address pair.  
Fix: Include both addresses in the signed message. Signature is only valid for that exact `(evm_address, solana_address)` pair:
```
message = "BharatSetu address link v1\nEVM: 0xAlice\nSolana: AliceSolPubkey\nTimestamp: 1746057600"
```
Include timestamp (unix seconds, 5-min validity window) to prevent long-term replay.

**Attack 3: Transfer ID collision** — attacker constructs a `transferId` that collides with a legitimate transfer to double-claim funds.  
Fix (EVM): `transferId = keccak256(abi.encode(msg.sender, nonce, block.chainId))` — include `msg.sender` so attacker cannot precompute the ID of another user's transfer.

```solidity
// EVMEscrow.sol
mapping(address => uint256) public nonces;

function lockForZone(...) external {
    bytes32 transferId = keccak256(abi.encode(msg.sender, nonces[msg.sender]++, block.chainid));
    // transferId is now user-specific and sequential — no collision possible
    ...
}
```

Fix (Solana): PDA seeds include `transfer_id` — two transfers with different IDs get different PDAs. Anchor enforces uniqueness via `init` constraint (fails if PDA already exists).

**Attack 4: Front-running the refund** — relayer processes release, then user also calls `refundAfterTimeout` before release confirmation propagates.  
Fix: Already handled — `lock.released = true` set atomically before token transfer in EVM; `escrow.status = Released` checked as Anchor constraint before refund instruction executes.

---

## 6. Implementation Plan (Phased)

### Phase 1: Solana Escrow Program (Rust/Anchor)

**New files:**
```
contracts/solana/
├── programs/
│   └── escrow/
│       ├── src/
│       │   ├── lib.rs           # Program entry point
│       │   ├── instructions/
│       │   │   ├── initialize.rs
│       │   │   ├── release.rs
│       │   │   ├── refund.rs
│       │   │   └── lock_for_evm.rs
│       │   └── state/
│       │       └── escrow_state.rs
│       └── Anchor.toml
└── tests/
    └── escrow.ts                # Anchor tests (TypeScript)
```

**Key design decisions:**
- Use PDAs for escrow state: `seeds = [b"escrow", transfer_id]`
- Relayer authority: PDA or multisig of R1,R2,R3 Solana keypairs
- Use SPL Token program for token custody (not raw lamport escrow)

### Phase 2: EVMEscrow.sol (New Contract)

**New file:** `contracts/src/EVMEscrow.sol`

Generalizes existing `CBDCVault` and `LockBridge` to support arbitrary destination zones:
- Replaces hardcoded "mint on Sepolia" with "notify hub for zone X"
- Adds `destinationZone`, `destinationAddress`, `metadata` to lock events
- Adds `timeout` + `refundAfterTimeout()` for safety
- Keeps existing relayer-only `unlockFromZone()` for reverse flow

### Phase 3: SolanaIndexer (Elixir)

**New file:** `apps/bharat_adapters/lib/bharat_adapters/blockchain/solana_indexer.ex`

Behaviour parallel to `BlockchainIndexer`:
- `getSignaturesForAddress` polling every 1s (Solana is fast)
- Parse Anchor event logs (base64-encoded discriminated union)
- Checkpoint to `indexer_checkpoints` table (add `solana_devnet` chain variant)
- Detect `EscrowLocked`, `EscrowReleased`, `EscrowRefunded` events

### Phase 4: Hub Translation Layer

**New file:** `apps/bharat_core/lib/bharat_core/bridge/zone_translator.ex`

```elixir
defmodule BharatCore.Bridge.ZoneTranslator do
  # Translates cross-zone transfer intents:
  # - Amount normalization (18 dec ↔ 6 dec)
  # - Address format conversion (hex ↔ base58)
  # - Proof format selection (MPT proof vs. relayer attestation)
  
  def translate(:evm_to_solana, transfer), do: ...
  def translate(:solana_to_evm, transfer), do: ...
end
```

**Extend TransferServer FSM** to handle `sol_zone` transfer type — new states:
```
init → locked → sol_confirmed → hub_attested → sol_released → completed
```

### Phase 5: Relayer Extension

**Extend V2Worker** (or create `SolanaRelayWorker`):
- For EVM→Solana: call `EscrowProgram.release_to_beneficiary` (Solana instruction via `@solana/web3.js` through Elixir port/NIF or HTTP RPC)
- For Solana→EVM: call `EVMEscrow.unlockFromZone` (existing Req-based EVM calls)

**Solana RPC from Elixir:** Options:
1. **HTTP JSON-RPC** (Req library, same as current Anvil integration) — simplest
2. **Elixir port to Node.js** — run `@solana/web3.js` in a Node subprocess, communicate via stdio JSON
3. **Native NIF** (not recommended — complexity)

Recommendation: HTTP JSON-RPC for account reads; Elixir→Node port for signed transaction submission (keypair management is simpler in JS ecosystem).

### Phase 6: Frontend

- Add Solana wallet adapter
- Bridge form: detect direction, show appropriate wallet connect buttons
- Address mapping flow: sign verification messages in both wallets
- Show Solana explorer links for Solana-side transactions

---

## 7. Database Schema Changes

```sql
-- New: zone channel registry
CREATE TABLE channels (
  id VARCHAR PRIMARY KEY,           -- "evm:amoy<>sol:devnet"
  zone_a VARCHAR NOT NULL,
  zone_b VARCHAR NOT NULL,
  escrow_a VARCHAR NOT NULL,        -- contract/program address on zone A
  escrow_b VARCHAR NOT NULL,        -- contract/program address on zone B
  status VARCHAR NOT NULL DEFAULT 'active',
  inserted_at TIMESTAMP,
  updated_at TIMESTAMP
);

-- New: cross-chain address mappings
CREATE TABLE address_mappings (
  id UUID PRIMARY KEY,
  user_id UUID REFERENCES users(id),
  evm_address VARCHAR(42) NOT NULL,
  solana_address VARCHAR(44) NOT NULL,  -- base58
  evm_signature TEXT NOT NULL,          -- proof of EVM key ownership
  solana_signature TEXT NOT NULL,       -- proof of Solana key ownership
  verified_at TIMESTAMP NOT NULL,
  inserted_at TIMESTAMP
);

-- Extend transfers table
ALTER TABLE transfers ADD COLUMN channel_id VARCHAR REFERENCES channels(id);
ALTER TABLE transfers ADD COLUMN source_zone VARCHAR;         -- "evm:amoy"
ALTER TABLE transfers ADD COLUMN destination_zone VARCHAR;    -- "sol:devnet"
ALTER TABLE transfers ADD COLUMN destination_address BYTEA;  -- raw bytes (32 for Solana, 20 for EVM)
ALTER TABLE transfers ADD COLUMN solana_slot BIGINT;
ALTER TABLE transfers ADD COLUMN solana_commitment VARCHAR;   -- "finalized" | "confirmed"

-- Extend indexer_checkpoints
-- Add chain variant: "solana_devnet" (existing enum or string column)
```

---

## 8. Trust Model Summary

| Transfer Direction | Source Proof | Destination Auth | Trust Level |
|-------------------|-------------|-----------------|-------------|
| EVM → EVM (existing) | MPT receipt proof | Smart contract verifies | Trustless (cryptographic) |
| EVM → Solana | EVM event (MPT) | Relayer 2-of-3 multisig on Solana | Semi-trusted (relayer cluster) |
| Solana → EVM | Solana PDA state read | Relayer 2-of-3 sig on EVM | Semi-trusted (relayer cluster) |
| Solana → EVM (future) | Ed25519 agg sig of finalized slot | EVM ed25519 precompile verify | Near-trustless |

**Semi-trusted is acceptable for** regulated CBDC/stablecoin corridors where:
1. Relayers are KYC'd entities (banks, licensed intermediaries)
2. Economic stake (slashing conditions) deters misbehavior
3. Timeouts + refunds limit maximum loss from relayer failure

---

## 9. Security Considerations

### 9.1 Replay Attacks
- EVM: `usedTransferIds` mapping in EVMEscrow prevents double-unlock
- Solana: `EscrowState.status` PDA prevents double-release (Anchor account constraint)
- Hub: FSM terminal states (`completed`, `refunded`) prevent re-processing

### 9.2 Man-in-the-Middle (Hub Compromise)
- If hub relayers collude (2-of-3), they can authorize false releases
- Mitigation: relayer keys held in HSM (Hardware Security Module) per relayer node
- Future: ZK proof of Solana account state submitted to EVM (eliminates relayer trust for Solana→EVM)

### 9.3 Timeout/Refund Race Condition
- Scenario: relayer submits release, simultaneously user triggers timeout refund
- EVM: `EVMEscrow.refundAfterTimeout` checks `block.timestamp > lockTimestamp + TIMEOUT`. If release already processed, `usedTransferIds[id] == true` → reverts. Refund fails safely.
- Solana: `EscrowState.status = Released` → `refund_to_source` instruction fails with constraint error

### 9.4 Address Mapping Spoofing
- Without verification, attacker locks on EVM and specifies a Solana address they don't control
- Mitigation: dual-signature verification at transfer initiation (not optional)
- The compliance gate (existing ComplianceEngine) should also verify `address_mappings` before allowing cross-zone transfers

### 9.5 SPL Token Mint Authority
- If EscrowProgram PDA is mint authority, a compromised relayer set cannot mint (they don't hold mint authority — the PDA does, and it only mints on `release` instruction with proper checks)
- Mint authority upgrade authority should be set to `None` after deploy (lock the mint)

---

## 10. Relation to Production Roadmap (Cosmos IBC)

Our `specs/bharatsetu-production-v1.md` and README mention Cosmos IBC as the long-term goal. This EVM↔Solana design is a stepping stone:

| This Design | IBC Equivalent |
|------------|---------------|
| Zone | IBC Zone |
| Channel (hub path) | IBC Channel |
| Escrow contract/program | IBC Escrow Module |
| Relayer cluster | IBC Relayer (Hermes) |
| Address mapping | IBC cross-chain accounts |
| Timeout + refund | IBC timeout acknowledgement |

When we migrate to IBC:
- Replace `SolanaIndexer` + relayer with Hermes relayer (supports Solana via ICS-02 light client, WIP in Cosmos ecosystem)
- Replace `EVMEscrow` with EVM IBC module (Polymer protocol / Succinct ZK-IBC)
- Channel state becomes IBC channel handshake (OPEN_INIT → OPEN_TRY → OPEN_ACK → OPEN_CONFIRM)

The hub-and-spoke architecture we build now maps directly to IBC hub-and-spoke. The migration is an upgrade, not a rewrite.

---

## 11. Minimal POC Scope

To prove the concept without building everything:

1. **EVMEscrow.sol** — lock INRX on Amoy with Solana destination address
2. **Solana EscrowProgram** (Anchor, devnet) — receive release from hub relayer, credit wINRX to beneficiary
3. **SolanaIndexer** — detect Solana lock events (for Solana→EVM)
4. **Hub translation** — ZoneTranslator + extend TransferServer FSM
5. **One relayer** (R1 only, no threshold for POC) — bridge EVM→Solana
6. **Frontend** — add Phantom wallet connect, show Solana explorer links

No dual-signature address verification in POC (manual address entry, accept trust assumption).

---

## 12. Key Dependencies

| Component | Library/Tool | Rationale |
|-----------|-------------|-----------|
| Solana program | Anchor 0.29+ | Rust framework, type-safe accounts, discriminated events |
| Solana RPC (Elixir) | Req (existing) | Simple HTTP JSON-RPC, same as Anvil integration |
| Solana tx signing | Node.js port (`@solana/web3.js`) | Keypair management, transaction serialization |
| Frontend Solana | `@solana/wallet-adapter-react` | Phantom, Backpack, Solflare support |
| Ed25519 on EVM (future) | EIP-665 precompile | `ecrecover`-equivalent for ed25519 — available on most EVM chains |
| ZK Solana light client (future) | Succinct SP1 / Risc0 | Generate ZK proof of Solana account state, verify on EVM |
