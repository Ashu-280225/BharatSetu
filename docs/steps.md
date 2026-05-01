# Manual Steps — Complete Beginner Guide

These are the tasks the code cannot do automatically. You must do them by hand.
Each step explains **what it is**, **why you need it**, and **exactly how to do it**.

---

## Background: Two Things You Need to Understand First

### What is a "contract topic hash"?
When a Solidity smart contract fires an event (like `AssetLocked`), Ethereum identifies
that event by a unique ID called a **topic hash**. It is computed by hashing the event's
function signature. If we change the signature (we added two new parameters to `AssetLocked`),
the hash changes. Our Elixir code has the old hash hardcoded — we must update it to the new one.

### What is a "discriminator"?
Solana programs (written in Rust/Anchor) identify each instruction and event with an 8-byte
fingerprint called a **discriminator**. It is the first 8 bytes of `sha256("event:EventName")`.
Our Elixir indexer uses these to recognize which event arrived. We added 3 new events — we need
their discriminators so the indexer can recognize them.

---

## PART 1 — Ethereum / Solidity (EVM Side)

### Step 1: Install Foundry (if not installed)

Foundry is the tool that compiles and deploys Solidity contracts.

```bash
# Run this in any terminal
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify it worked:
```bash
cast --version
# Should print something like: cast 0.2.0 (...)
```

---

### Step 2: Compute the new AssetLocked topic hash

We changed `AssetLocked` event in `contracts/src/AssetVault.sol` — added `destinationZone` and
`destinationAddress` parameters. The topic hash must be recomputed.

```bash
cd contracts

cast keccak "AssetLocked(address,address,uint256,bytes32,bytes32,string,bytes32,bytes)"
```

You will get output like:
```
0x3f7a92c1d4e8b5f6...
```

Copy that value. Now open:
```
apps/bharat_adapters/lib/bharat_adapters/blockchain/contract.ex
```

Find this line (around line 22):
```elixir
@asset_locked_topic "0x0000000000000000000000000000000000000000000000000000000000000000"
```

Replace the `0x000...` with the value you just copied:
```elixir
@asset_locked_topic "0x<paste_your_hash_here>"
```

Save the file.

---

### Step 3: Compile the updated AssetVault contract

```bash
cd contracts
forge build
```

If it says `Compiler run successful` — done.

If you see errors, the most common fix:
- `EmptyPayload` error check was removed — the `instructionPayload` can now be empty for NFT transfers.
  This is already handled in our code change. If forge still complains, check the error message carefully.

---

### Step 4: Deploy the updated AssetVault contract

> **WARNING:** This replaces the old contract. The old contract address will no longer work.
> Make sure no live funds are locked in the old contract before doing this.

First, set your environment variables (create a `.env` file in `contracts/` if it doesn't exist):
```bash
# contracts/.env
PRIVATE_KEY=0x<your_deployer_wallet_private_key>
AMOY_RPC_URL=https://rpc-amoy.polygon.technology
```

Then deploy:
```bash
cd contracts
source .env

forge create src/AssetVault.sol:AssetVault \
  --rpc-url $AMOY_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <your_admin_wallet_address>
```

You will see output like:
```
Deployed to: 0xAbCd1234...
Transaction hash: 0x...
```

Copy the `Deployed to:` address.

---

### Step 5: Update the contract address in config

Open your config file (likely `config/dev.exs` or `.env` in the project root).

Find the line with `asset_vault_contract` and update it:
```elixir
asset_vault_contract: "0x<new_address_from_step_4>"
```

---

## PART 2 — Solana Programs (Rust)

> **What is a Solana program?**
> It is like a smart contract but on the Solana blockchain. Written in Rust using a framework
> called Anchor. Our bridge needs 4 new "instructions" (functions) in the Solana program.

### Step 6: Install Rust and Anchor (if not installed)

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# Install Solana CLI
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"

# Install Anchor
cargo install --git https://github.com/coral-xyz/anchor avm --locked
avm install latest
avm use latest

# Verify
anchor --version
# Should print: anchor-cli 0.30.x
```

---

### Step 7: Locate or create the Solana program

Our existing Solana escrow program lives at:
```
apps/bharat_adapters/priv/solana_signer.js   ← the JS caller
```

But the actual Rust program needs to be in a separate folder. Check if it exists:
```bash
ls programs/
```

If it doesn't exist yet, create a new Anchor project:
```bash
anchor init solana_escrow
cd solana_escrow
```

---

### Step 8: Add 4 new instructions to the Rust program

Open `programs/solana_escrow/src/lib.rs` (or wherever the Rust program is).

You need to add 4 new instruction handlers. Each one is a Rust function. Here is exactly
what each one must do — copy these into the program:

#### Instruction 1: `mint_wrapped_nft`
Called when an NFT is locked on EVM and we need to create a copy on Solana.

```rust
pub fn mint_wrapped_nft(
    ctx: Context<MintWrappedNft>,
    transfer_id: [u8; 32],
    token_id: u64,
    metadata: String,
) -> Result<()> {
    // 1. Verify this transfer_id has not been processed before (idempotency)
    require!(!ctx.accounts.escrow_state.processed, ErrorCode::AlreadyProcessed);

    // 2. Mark as processed
    ctx.accounts.escrow_state.processed = true;
    ctx.accounts.escrow_state.transfer_id = transfer_id;

    // 3. Mint the wrapped NFT to beneficiary using Metaplex
    //    (use mpl_token_metadata CPI here)
    //    emit the NftMinted event so the indexer picks it up

    emit!(NftMinted { transfer_id, token_id });
    Ok(())
}
```

#### Instruction 2: `burn_wrapped_nft`
Called after original NFT is released on EVM — burns the Solana copy.

```rust
pub fn burn_wrapped_nft(
    ctx: Context<BurnWrappedNft>,
    transfer_id: [u8; 32],
    token_id: u64,
) -> Result<()> {
    require!(!ctx.accounts.burn_state.processed, ErrorCode::AlreadyProcessed);
    ctx.accounts.burn_state.processed = true;

    // Burn the NFT token account
    // emit NftBurned event

    emit!(NftBurned { transfer_id, token_id });
    Ok(())
}
```

#### Instruction 3: `lock_tokens` (for reverse token flow)
Called when user wants to send tokens from Solana back to EVM.

```rust
pub fn lock_tokens(
    ctx: Context<LockTokens>,
    transfer_id: [u8; 32],
    amount: u64,
    destination_evm: [u8; 20],  // EVM wallet address bytes
) -> Result<()> {
    require!(!ctx.accounts.lock_state.processed, ErrorCode::AlreadyProcessed);
    ctx.accounts.lock_state.processed = true;
    ctx.accounts.lock_state.transfer_id = transfer_id;
    ctx.accounts.lock_state.amount = amount;

    // Transfer SPL tokens from user to escrow vault
    // emit TokensLocked so the indexer triggers EVM side

    emit!(TokensLocked { transfer_id, amount, destination_evm });
    Ok(())
}
```

#### Instruction 4: `cancel_lock`
Called by relayer if a lock times out — returns tokens to user.

```rust
pub fn cancel_lock(
    ctx: Context<CancelLock>,
    transfer_id: [u8; 32],
) -> Result<()> {
    require!(!ctx.accounts.lock_state.cancelled, ErrorCode::AlreadyCancelled);
    ctx.accounts.lock_state.cancelled = true;

    // Return tokens from escrow back to original sender
    Ok(())
}
```

---

### Step 9: Add the 4 Anchor event structs

In the same `lib.rs`, add these event definitions. Anchor uses `#[event]` to emit logs
that our indexer reads:

```rust
#[event]
pub struct NftMinted {
    pub transfer_id: [u8; 32],
    pub token_id: u64,
}

#[event]
pub struct NftBurned {
    pub transfer_id: [u8; 32],
    pub token_id: u64,
}

#[event]
pub struct TokensLocked {
    pub transfer_id: [u8; 32],
    pub amount: u64,
    pub destination_evm: [u8; 20],
}

#[event]
pub struct NftLocked {
    pub transfer_id: [u8; 32],
    pub token_id: u64,
}
```

---

### Step 10: Compute the 4 discriminators

After defining the events, compute their discriminators. Anchor uses
`sha256("event:<EventName>")` and takes the first 8 bytes.

Run this Python snippet (no install needed, Python is standard):

```bash
python3 - <<'EOF'
import hashlib

events = ["EscrowReleased", "TokensLocked", "NftLocked", "NftMinted"]
for name in events:
    h = hashlib.sha256(f"event:{name}".encode()).digest()
    hex_bytes = ", ".join(f"0x{b:02X}" for b in h[:8])
    elixir = "<<" + ", ".join(f"0x{b:02X}" for b in h[:8]) + ">>"
    print(f"{name}: {elixir}")
EOF
```

Output will look like:
```
EscrowReleased: <<0x98, 0x3A, 0x6D, 0x2E, 0xB7, 0x5C, 0x11, 0xAF>>
TokensLocked:   <<0x1B, 0x44, 0xA2, 0x9F, 0xC3, 0x87, 0x5E, 0xD0>>
NftLocked:      <<0x4C, 0x81, 0x37, 0xBB, 0xE9, 0x02, 0xDA, 0x56>>
NftMinted:      <<0x7F, 0xA3, 0xC5, 0x18, 0x6D, 0x44, 0x9B, 0x2C>>
```

Now open:
```
apps/bharat_core/lib/bharat_core/indexer/solana_indexer.ex
```

Find these lines (around line 84):
```elixir
@disc_escrow_released  <<0x98, 0x3A, ...>>
@disc_tokens_locked    <<0x1B, 0x44, ...>>
@disc_nft_locked       <<0x4C, 0x81, ...>>
@disc_nft_minted       <<0x7F, 0xA3, ...>>
```

Replace each with the actual values from the Python output above.

> **Important:** The `EscrowReleased` discriminator must match the EXISTING Rust program's
> event — not a new one. Run the Python script on the name already in the Rust code.
> If the existing program uses a different event name, use that name in the Python script.

---

### Step 11: Build and deploy the Solana program

```bash
cd solana_escrow   # or wherever your Anchor project is

# Build
anchor build

# This creates target/deploy/solana_escrow.so (the compiled program)
```

Deploy to devnet:
```bash
# Make sure your Solana CLI is pointed at devnet
solana config set --url devnet

# Check your wallet has devnet SOL (for deploy fee)
solana balance

# If balance is 0, airdrop some:
solana airdrop 2

# Deploy
anchor deploy
```

Output will show:
```
Program Id: <new_program_address>
```

---

### Step 12: Update the Solana program ID in config

Take the `Program Id` from Step 11 and update your config:

In `config/dev.exs` or `.env`:
```
SOLANA_ESCROW_PROGRAM=<new_program_id_from_step_11>
```

In Elixir config:
```elixir
solana_escrow_program: System.get_env("SOLANA_ESCROW_PROGRAM")
```

---

## PART 3 — JavaScript Signer (Solana Port Client)

The file `apps/bharat_adapters/priv/solana_signer.js` handles sending transactions
to Solana. Currently it only knows the `release` method. We need to add 3 more.

### Step 13: Add new methods to solana_signer.js

Open `apps/bharat_adapters/priv/solana_signer.js`.

Find this block (around line 27):
```javascript
if (method === "release") {
  result = await handleRelease(payload);
} else {
  throw new Error(`unknown method: ${method}`);
}
```

Replace with:
```javascript
if (method === "release") {
  result = await handleRelease(payload);
} else if (method === "mint_wrapped_nft") {
  result = await handleMintWrappedNft(payload);
} else if (method === "burn_wrapped_nft") {
  result = await handleBurnWrappedNft(payload);
} else if (method === "cancel_lock") {
  result = await handleCancelLock(payload);
} else {
  throw new Error(`unknown method: ${method}`);
}
```

Then add these 3 functions at the bottom of the file:

```javascript
async function handleMintWrappedNft(payload) {
  const { program_id, transfer_id_hex, token_id, beneficiary_pubkey, metadata, keypair_json } = payload;

  const keypair    = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(keypair_json)));
  const programId  = new PublicKey(program_id);
  const beneficiary = new PublicKey(beneficiary_pubkey);

  const transferIdBytes = Buffer.from(transfer_id_hex, "hex");

  // Discriminator for mint_wrapped_nft instruction
  // Compute: sha256("global:mint_wrapped_nft")[0..7]
  // python3 -c "import hashlib; print(hashlib.sha256(b'global:mint_wrapped_nft').digest()[:8].hex())"
  const disc = Buffer.from("REPLACE_WITH_COMPUTED_HEX", "hex");

  const tokenIdBuf = Buffer.alloc(8);
  new BN(token_id).toArrayLike(Buffer, "le", 8).copy(tokenIdBuf);

  const data = Buffer.concat([disc, transferIdBytes, tokenIdBuf]);

  const [escrowPda] = await PublicKey.findProgramAddress(
    [Buffer.from("nft_escrow"), transferIdBytes],
    programId
  );

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: keypair.publicKey, isSigner: true,  isWritable: true  },
      { pubkey: escrowPda,         isSigner: false, isWritable: true  },
      { pubkey: beneficiary,       isSigner: false, isWritable: true  },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data,
  });

  const tx = new Transaction();
  tx.add(ix);
  tx.feePayer = keypair.publicKey;
  const { blockhash } = await connection.getLatestBlockhash("finalized");
  tx.recentBlockhash  = blockhash;
  tx.sign(keypair);

  const sig = await connection.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    preflightCommitment: "finalized",
  });
  await connection.confirmTransaction(sig, "finalized");
  return sig;
}

async function handleBurnWrappedNft(payload) {
  const { program_id, transfer_id_hex, token_id, keypair_json } = payload;

  const keypair   = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(keypair_json)));
  const programId = new PublicKey(program_id);

  const transferIdBytes = Buffer.from(transfer_id_hex, "hex");

  // Discriminator: sha256("global:burn_wrapped_nft")[0..7]
  const disc = Buffer.from("REPLACE_WITH_COMPUTED_HEX", "hex");

  const tokenIdBuf = Buffer.alloc(8);
  new BN(token_id).toArrayLike(Buffer, "le", 8).copy(tokenIdBuf);

  const data = Buffer.concat([disc, transferIdBytes, tokenIdBuf]);

  const [escrowPda] = await PublicKey.findProgramAddress(
    [Buffer.from("nft_escrow"), transferIdBytes],
    programId
  );

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: keypair.publicKey, isSigner: true,  isWritable: true  },
      { pubkey: escrowPda,         isSigner: false, isWritable: true  },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data,
  });

  const tx = new Transaction();
  tx.add(ix);
  tx.feePayer = keypair.publicKey;
  const { blockhash } = await connection.getLatestBlockhash("finalized");
  tx.recentBlockhash  = blockhash;
  tx.sign(keypair);

  const sig = await connection.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    preflightCommitment: "finalized",
  });
  await connection.confirmTransaction(sig, "finalized");
  return sig;
}

async function handleCancelLock(payload) {
  const { program_id, transfer_id, keypair_json } = payload;

  const keypair   = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(keypair_json)));
  const programId = new PublicKey(program_id);

  const transferIdBytes = Buffer.from(transfer_id.replace(/-/g, ""), "hex");

  // Discriminator: sha256("global:cancel_lock")[0..7]
  const disc = Buffer.from("REPLACE_WITH_COMPUTED_HEX", "hex");

  const data = Buffer.concat([disc, transferIdBytes]);

  const [lockPda] = await PublicKey.findProgramAddress(
    [Buffer.from("lock"), transferIdBytes],
    programId
  );

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: keypair.publicKey, isSigner: true,  isWritable: true  },
      { pubkey: lockPda,           isSigner: false, isWritable: true  },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data,
  });

  const tx = new Transaction();
  tx.add(ix);
  tx.feePayer = keypair.publicKey;
  const { blockhash } = await connection.getLatestBlockhash("finalized");
  tx.recentBlockhash  = blockhash;
  tx.sign(keypair);

  const sig = await connection.sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    preflightCommitment: "finalized",
  });
  await connection.confirmTransaction(sig, "finalized");
  return sig;
}
```

---

### Step 14: Compute instruction discriminators for JS file

For each new instruction, run:

```bash
python3 - <<'EOF'
import hashlib

instructions = ["mint_wrapped_nft", "burn_wrapped_nft", "cancel_lock"]
for name in instructions:
    h = hashlib.sha256(f"global:{name}".encode()).digest()
    print(f"{name}: {h[:8].hex()}")
EOF
```

Output:
```
mint_wrapped_nft: a1b2c3d4e5f6a7b8
burn_wrapped_nft: 1234abcd5678ef90
cancel_lock:      fedcba9876543210
```

In `solana_signer.js`, replace each `REPLACE_WITH_COMPUTED_HEX` with the matching hex
from the output above (only 16 hex characters = 8 bytes).

---

## PART 4 — Database Migration

### Step 15: Run the migration

We added 4 new columns to the `transfers` table. Run:

```bash
cd <project_root>
mix ecto.migrate
```

Expected output:
```
[info] == Running 20240101000010 BharatData.Repo.Migrations.AddZoneChannelFields.change/0 forward
[info] alter table transfers
[info] == Migrated 20240101000010 in 0.0s
```

---

## PART 5 — Verification Checklist

After completing all steps, verify everything is wired correctly:

### Checklist

- [ ] `@asset_locked_topic` in `contract.ex` is a real 66-char hex hash (not `0x0000...`)
- [ ] `@disc_*` constants in `solana_indexer.ex` match Python script output
- [ ] `REPLACE_WITH_COMPUTED_HEX` strings replaced in `solana_signer.js`
- [ ] `asset_vault_contract` config points to newly deployed contract address
- [ ] `solana_escrow_program` config points to newly deployed program ID
- [ ] `mix ecto.migrate` ran successfully
- [ ] `forge build` compiles without errors
- [ ] `anchor build` compiles without errors

---

## Summary Table

| Step | What | Tool | Time estimate |
|---|---|---|---|
| 1 | Install Foundry | Terminal | 5 min |
| 2 | Compute AssetLocked topic hash | `cast keccak` | 2 min |
| 3 | Compile updated contract | `forge build` | 2 min |
| 4 | Deploy AssetVault | `forge create` | 5 min |
| 5 | Update config with new address | Text editor | 2 min |
| 6 | Install Rust + Anchor | Terminal | 15 min |
| 7 | Locate/create Solana program | Terminal | 5 min |
| 8–9 | Add 4 instructions + events to Rust | Code editor | 2–4 hours |
| 10 | Compute Anchor discriminators | Python | 5 min |
| 11 | Build + deploy Solana program | `anchor deploy` | 10 min |
| 12 | Update config with program ID | Text editor | 2 min |
| 13–14 | Add 3 methods to solana_signer.js | Code editor | 30–60 min |
| 15 | Run DB migration | `mix ecto.migrate` | 2 min |

Total: **~4–6 hours** (mostly Step 8–9 Rust code writing)
