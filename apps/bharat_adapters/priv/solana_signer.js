const {
  Connection, Keypair, PublicKey, Transaction, TransactionInstruction,
  SystemProgram
} = require("@solana/web3.js");
const readline = require("readline");
const BN = require("bn.js");

const TOKEN_PROGRAM_ID = new PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
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

  const keypair      = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(keypair_json)));
  const programId    = new PublicKey(program_id);
  const reservePool  = new PublicKey(reserve_pool);
  const beneficiary  = new PublicKey(beneficiary_pubkey);

  const transferIdBytes = Buffer.from(transfer_id_hex, "hex");
  const [escrowPda]     = await PublicKey.findProgramAddress(
    [Buffer.from("escrow"), transferIdBytes],
    programId
  );

  // Instruction discriminator: sha256("global:release_to_beneficiary")[0..7]
  // Pre-computed — must match Anchor IDL
  const disc = Buffer.from("e92d3d4b5f4e1a2b", "hex");

  const amountBuf = Buffer.alloc(8);
  new BN(amount).toArrayLike(Buffer, "le", 8).copy(amountBuf);

  const evmSenderBuf  = Buffer.from(evm_sender.replace("0x", ""), "hex");
  const sourceZoneBuf = Buffer.alloc(32);
  Buffer.from(source_zone).copy(sourceZoneBuf);

  const data = Buffer.concat([disc, transferIdBytes, amountBuf, evmSenderBuf, sourceZoneBuf]);

  const ix = new TransactionInstruction({
    programId,
    keys: [
      { pubkey: keypair.publicKey, isSigner: true,  isWritable: true  }, // relayer
      { pubkey: escrowPda,         isSigner: false, isWritable: true  }, // escrow_state PDA
      { pubkey: reservePool,       isSigner: false, isWritable: true  }, // reserve pool
      { pubkey: beneficiary,       isSigner: false, isWritable: true  }, // beneficiary token acct
      { pubkey: TOKEN_PROGRAM_ID,  isSigner: false, isWritable: false }, // token program
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
