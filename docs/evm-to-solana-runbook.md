# EVM → Solana Bridge: Intern Runbook

**Flow:** Lock INRX on Polygon Amoy → release wINRX to beneficiary on Solana Devnet

---

## Prerequisites — Install Everything First

### 1. Elixir + Mix
- Download from: https://elixir-lang.org/install.html
- Verify: `elixir --version` (need 1.16+)

### 2. PostgreSQL
- Download from: https://www.postgresql.org/download/
- Start it and create a user:
  ```sql
  CREATE USER postgres WITH PASSWORD 'postgres' SUPERUSER;
  ```

### 3. Node.js
- Download from: https://nodejs.org (v18 or higher)
- Verify: `node --version`

### 4. Foundry (for Solidity)
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```
- Verify: `forge --version`, `cast --version`

### 5. Solana CLI
```bash
sh -c "$(curl -sSfL https://release.solana.com/stable/install)"
```
- Verify: `solana --version`
- Set to devnet:
  ```bash
  solana config set --url devnet
  ```

### 6. Anchor CLI (Solana smart contracts)
```bash
cargo install --git https://github.com/coral-xyz/anchor avm --locked
avm install 0.29.0
avm use 0.29.0
```
- Verify: `anchor --version`

### 7. Rust (required by Anchor)
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### 8. Wallets
- **MetaMask** browser extension — add Polygon Amoy network:
  - RPC URL: `https://rpc-amoy.polygon.technology`
  - Chain ID: `80002`
  - Currency: `MATIC`
- **Phantom** browser extension — switch to Devnet in settings

### 9. Get testnet funds
- Amoy MATIC: https://faucet.polygon.technology
- Solana Devnet SOL: `solana airdrop 2 <your-wallet-address>`

---

## Part 1 — Clone & Install Dependencies

```bash
git clone <repo-url>
cd BharatSetu

# Elixir dependencies
mix deps.get

# Node.js dependencies (Solana tx signer)
cd apps/bharat_adapters/priv
npm install
cd ../../..
```

---

## Part 2 — Database Setup

```bash
# Create database and run all migrations
mix ecto.setup
```

If database already exists:
```bash
mix ecto.migrate
```

Expected output: migrations 001 through 009 run successfully.

---

## Part 3 — Deploy EVMEscrow Contract (Polygon Amoy)

### 3.1 Set up deployer wallet
Export your MetaMask private key (never share this):
```bash
export DEPLOYER_KEY=0x<your-private-key>
export RELAYER_ADDRESS=0x<your-relayer-address>   # can be same wallet for POC
export AMOY_RPC_URL=https://rpc-amoy.polygon.technology
```

### 3.2 Compile and deploy
```bash
cd contracts

forge build

forge script script/DeployEVMEscrow.s.sol \
  --rpc-url $AMOY_RPC_URL \
  --broadcast \
  --private-key $DEPLOYER_KEY
```

### 3.3 Save the deployed address
Output will look like:
```
EVMEscrow deployed: 0xAbCd1234...
```
**Copy this address — you need it later as `EVM_ESCROW_CONTRACT`.**

### 3.4 Compute function selector and event topic
```bash
# 4-byte selector for lockForZone
cast sig "lockForZone(address,uint256,string,bytes32,bytes)"
# Example output: 0x1a2b3c4d

# Event topic for TokensLockedForZone
cast keccak "TokensLockedForZone(bytes32,address,uint256,address,string,bytes32,bytes)"
# Example output: 0xabcdef...
```

### 3.5 Update contract.ex with real values
Open `apps/bharat_adapters/lib/bharat_adapters/blockchain/contract.ex`:

**Line ~36** — replace placeholder topic:
```elixir
@tokens_locked_for_zone_topic "0x<output from cast keccak above>"
```

**Around line 600** — in `build_evm_escrow_lock_tx`, replace placeholder selector:
```elixir
# Replace this line:
selector = <<0xAB, 0xCD, 0xEF, 0x12>>

# With actual 4 bytes from cast sig output (e.g. 0x1a2b3c4d):
selector = <<0x1a, 0x2b, 0x3c, 0x4d>>
```

---

## Part 4 — Deploy Solana EscrowProgram (Devnet)

### 4.1 Generate Solana keypair (if you don't have one)
```bash
solana-keygen new --outfile ~/.config/solana/id.json
solana airdrop 2   # get devnet SOL for fees
```

### 4.2 Get your Solana public key
```bash
solana address
# Example: 7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU
```

### 4.3 Update RELAYER_PUBKEY in Rust program
Open `contracts/solana/programs/escrow/src/lib.rs`, line 9:
```rust
const RELAYER_PUBKEY: &str = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU";
```

### 4.4 Build and deploy
```bash
cd contracts/solana

anchor build
anchor deploy --provider.cluster devnet
```

Output will show:
```
Program Id: <NEW_PROGRAM_ID>
```
**Copy this Program ID.**

### 4.5 Update Program ID in source files
**`contracts/solana/Anchor.toml`** — replace placeholder:
```toml
[programs.localnet]
escrow = "<NEW_PROGRAM_ID>"
```

**`contracts/solana/programs/escrow/src/lib.rs`** — line 12:
```rust
declare_id!("<NEW_PROGRAM_ID>");
```

### 4.6 Rebuild after updating ID
```bash
anchor build
anchor deploy --provider.cluster devnet
```

### 4.7 Get instruction discriminator
After build, Anchor generates an IDL. Get the real discriminator:
```bash
cat contracts/solana/target/idl/escrow.json | python3 -c "
import json, sys, hashlib
idl = json.load(sys.stdin)
for ix in idl['instructions']:
    if ix['name'] == 'releaseToBeneficiary':
        h = hashlib.sha256(f'global:{ix[\"name\"]}'.encode()).digest()[:8]
        print('Discriminator:', h.hex())
"
```

Update `apps/bharat_adapters/priv/solana_signer.js`, line ~50:
```javascript
const disc = Buffer.from("<8-byte-hex-from-above>", "hex");
```

---

## Part 5 — Create wINRX Token on Devnet

```bash
# Create the wINRX SPL token mint (6 decimals)
spl-token create-token --decimals 6
# Output: Creating token <MINT_ADDRESS>

# Create reserve pool token account (owned by program)
spl-token create-account <MINT_ADDRESS>
# Output: Creating account <RESERVE_POOL_ADDRESS>

# Mint 1,000,000 wINRX into reserve pool
spl-token mint <MINT_ADDRESS> 1000000 <RESERVE_POOL_ADDRESS>
```

**Save both addresses.**

> **Note:** For the reserve pool to be controlled by the Solana program (PDA),
> you need to set the delegate authority to the escrow PDA. For POC, you can
> use your own account as authority and the relayer will sign transfers directly.

---

## Part 6 — Configure Environment Variables

Create `.env` file in project root:

```bash
# ── Solana ────────────────────────────────────────────────────────────────
SOLANA_RPC_URL=https://api.devnet.solana.com
SOLANA_ESCROW_PROGRAM_ID=<Program ID from Part 4>
SOLANA_RESERVE_POOL_PUBKEY=<RESERVE_POOL_ADDRESS from Part 5>
WINRX_MINT_PUBKEY=<MINT_ADDRESS from Part 5>

# Solana relayer keypair — export from ~/.config/solana/id.json
# Run: cat ~/.config/solana/id.json
RELAYER_SOLANA_KEYPAIR_JSON=[1,23,45,67,...]   # paste the full JSON array

# ── EVM ───────────────────────────────────────────────────────────────────
EVM_ESCROW_CONTRACT=0x<EVMEscrow address from Part 3>
RELAYER_ADDRESS=0x<your relayer EVM wallet>
RELAYER_PRIVATE_KEY=0x<relayer EVM private key>

# ── Existing config (should already be set) ───────────────────────────────
POLYGON_HTTP_URL=https://rpc-amoy.polygon.technology
DATABASE_URL=postgresql://postgres:postgres@localhost/bharat_setu_dev
SECRET_KEY_BASE=<run: mix phx.gen.secret>
GUARDIAN_SECRET=<any long random string>
```

**How to get the keypair JSON:**
```bash
cat ~/.config/solana/id.json
# Paste the full array like: [174,47,154,16,202,...]
```

---

## Part 7 — Verify Config Is Loaded

```bash
iex -S mix

# Check Solana config is set
Application.get_env(:bharat_core, :solana_escrow_program)
# Should return your Program ID string, not nil
```

---

## Part 8 — Start the Server

```bash
# Terminal 1 — start Phoenix server
mix phx.server

# Or interactively:
iex -S mix phx.server
```

Watch for these lines in logs (all should start without errors):
```
[info] BharatCore.Indexer.EVMEscrowIndexer starting — polling Amoy
[info] BharatCore.Indexer.SolanaIndexer starting — polling devnet
[info] BharatRelayer.SolanaRelayWorker starting
[info] BharatAdapters.Blockchain.SolanaPortClient started (Node.js port alive)
```

---

## Part 9 — Run the E2E Transfer Test

### 9.1 Get a JWT token
```bash
curl -X POST http://localhost:4000/api/auth \
  -H "Content-Type: application/json" \
  -d '{"wallet": "0x<your-MetaMask-address>"}'
# Save the token from response
```

### 9.2 Create the transfer
```bash
curl -X POST http://localhost:4000/api/transfers \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-jwt-token>" \
  -d '{
    "direction": "evm_to_solana",
    "token_address": "0x<INRX_token_address_on_Amoy>",
    "amount": "1000000000000000",
    "destination_address": "<your-Phantom-wallet-pubkey-base58>"
  }'
```

Response:
```json
{
  "data": {
    "id": "uuid-here",
    "state": "init",
    "unsigned_tx": {
      "to": "0x<EVMEscrow>",
      "data": "0x...",
      "gas": "0x493E0"
    }
  }
}
```

### 9.3 Sign the transaction in MetaMask
1. Open MetaMask → make sure you're on **Polygon Amoy**
2. First approve INRX spending: call `approve(EVMEscrow_address, amount)` on the INRX token
3. Then sign the `unsigned_tx` returned above

You can use this in browser console:
```javascript
const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();
const tx = await signer.sendTransaction({
  to: "0x<EVMEscrow>",
  data: "0x<data from unsigned_tx>",
  gasLimit: 300000
});
console.log("TX Hash:", tx.hash);
```

### 9.4 Submit the tx hash
```bash
curl -X POST http://localhost:4000/api/transfers/<id>/confirm_lock \
  -H "Authorization: Bearer <jwt>" \
  -H "Content-Type: application/json" \
  -d '{"tx_hash": "0x<MetaMask-tx-hash>"}'
```

### 9.5 Watch it complete
```bash
# Poll transfer state
curl http://localhost:4000/api/transfers/<id> \
  -H "Authorization: Bearer <jwt>"
```

State progression:
```
init → locked → confirmed → minted → completed
```

Timeline:
- `locked` — immediate after Step 9.4
- `confirmed` — ~30s (12 Amoy block confirmations)
- `minted` — ~60s (SolanaRelayWorker picks up + submits release tx)
- `completed` — ~90s (SolanaIndexer confirms on-chain event)

### 9.6 Verify on Solana
Check Phantom wallet — wINRX balance should appear.

Or check Solana Explorer:
```
https://explorer.solana.com/address/<your-Phantom-pubkey>?cluster=devnet
```

---

## Troubleshooting

### "solana_escrow_program not configured" on startup
`.env` not loaded. Make sure your shell loads it:
```bash
export $(cat .env | xargs)
mix phx.server
```

### SolanaPortClient crashes immediately
Node.js can't find the script. Check path:
```bash
node apps/bharat_adapters/priv/solana_signer.js
# Should wait for stdin input, not crash
```

### "below minimum" error on transfer create
Amount too small. Use at least `1000000000000` (10^12 wei = 1 INRX with 6-decimal SPL rounding).

### EVMEscrowIndexer not finding events
- Confirm `EVM_ESCROW_CONTRACT` matches deployed address
- Confirm `@tokens_locked_for_zone_topic` in `contract.ex` is the correct keccak hash
- Check Amoy RPC is responsive: `curl -X POST $POLYGON_HTTP_URL -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'`

### SolanaRelayWorker "release failed"
- Check `RELAYER_SOLANA_KEYPAIR_JSON` is valid JSON array
- Check relayer has devnet SOL for fees: `solana balance`
- Check Node.js discriminator matches deployed program IDL

### "already released" error on Solana
Transfer already processed — idempotent, safe to ignore.

### Database migration fails
```bash
mix ecto.drop
mix ecto.setup
```

---

## File Map (What We Built)

```
contracts/
  src/EVMEscrow.sol                          ← Solidity lock contract
  script/DeployEVMEscrow.s.sol               ← Foundry deploy script
  solana/
    Anchor.toml
    programs/escrow/src/
      lib.rs                                 ← Anchor program entry
      state.rs                               ← EscrowState account
      instructions/release.rs                ← release_to_beneficiary
      instructions/refund.rs                 ← mark_refunded

apps/
  bharat_data/
    priv/repo/migrations/
      008_add_solana_fields_to_transfers.exs
      009_add_last_sig_to_indexer_checkpoints.exs
    lib/bharat_data/schemas/transfer.ex      ← added 4 Solana fields
    lib/bharat_data/transfers.ex             ← added Solana queries
    lib/bharat_data/schemas/indexer_checkpoint.ex  ← added last_sig
    lib/bharat_data/indexer_checkpoints.ex   ← added sig-based fns

  bharat_adapters/
    lib/.../blockchain/solana_rpc.ex         ← Solana JSON-RPC adapter
    lib/.../blockchain/solana_port_client.ex ← Elixir→Node port
    priv/solana_signer.js                    ← Node.js tx builder/signer
    priv/package.json

  bharat_core/
    lib/.../indexer/solana_indexer.ex        ← polls devnet for EscrowReleased
    lib/.../indexer/evm_escrow_indexer.ex    ← polls Amoy for TokensLockedForZone
    lib/.../bridge/transfer_server.ex        ← added evm_to_solana FSM path
    lib/.../bridge/transfer_supervisor.ex    ← passes destination fields through
    lib/.../application.ex                   ← added 2 new indexers

  bharat_relayer/
    lib/.../solana_relay_worker.ex           ← polls DB, submits Solana release
    lib/.../application.ex                   ← added SolanaPortClient + worker

  bharat_web/
    lib/.../controllers/transfer_controller.ex ← parses Solana destination_address

config/config.exs                            ← Solana env vars added
```
