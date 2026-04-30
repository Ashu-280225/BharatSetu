"use client";

import { useState, useEffect } from "react";
import { useAccount, useSignMessage, useSendTransaction, usePublicClient, useChainId, useBalance, useSwitchChain } from "wagmi";
import { encodeFunctionData, formatUnits } from "viem";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { siweLogin, isLoggedIn } from "../../lib/siwe";
import { createTransfer, confirmLock, getTransfer, getConfig, cancelTransfer, retryTransfer, Transfer, BridgeConfig } from "../../lib/api";
import { subscribeToTransfer } from "../../lib/socket";

const ERC20_APPROVE_ABI = [{
  name: "approve", type: "function",
  inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }],
  outputs: [{ name: "", type: "bool" }],
}] as const;

const LOCK_BRIDGE_ABI = [{
  name: "lockTokens", type: "function",
  inputs: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "transferId", type: "bytes32" },
  ],
  outputs: [],
}] as const;

const BURN_BRIDGE_ABI = [{
  name: "burnAndBridge", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }],
  outputs: [],
}] as const;

const LOCK_CBDC_ABI = [{
  name: "lockCBDC", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }],
  outputs: [],
}] as const;

const LOCK_CBDC_INSTRUCTION_ABI = [{
  name: "lockCBDCWithInstruction", type: "function",
  inputs: [{ name: "amount", type: "uint256" }, { name: "transferId", type: "bytes32" }, { name: "instructionPayload", type: "bytes" }],
  outputs: [],
}] as const;

const LOCK_ASSET_ABI = [{
  name: "lockAsset", type: "function",
  inputs: [
    { name: "tokenContract", type: "address" },
    { name: "tokenId", type: "uint256" },
    { name: "transferId", type: "bytes32" },
    { name: "instructionPayload", type: "bytes" },
  ],
  outputs: [],
}] as const;

const ERC721_APPROVE_ABI = [{
  name: "approve", type: "function",
  inputs: [{ name: "to", type: "address" }, { name: "tokenId", type: "uint256" }],
  outputs: [],
}] as const;

type Direction = "amoy_to_sepolia" | "sepolia_to_amoy" | "cbdc_to_stablecoin" | "token_to_instruction" | "asset_to_instruction";
type BridgeMode = "evm" | "cbdc" | "token_instruction" | "asset_instruction";
type Step = "connect" | "login" | "form" | "pending" | "done" | "error";

const STEPS_FORWARD = [
  { key: "init",      label: "Approve & Lock",       desc: "Approve tCCS spend + lock tokens in bridge",          eta: null },
  { key: "locked",    label: "Awaiting Confirmation", desc: "Waiting for 12 block confirmations on Amoy",         eta: "~4 min" },
  { key: "confirmed", label: "Relayer Processing",    desc: "Relayer detected lock — minting wCCC on Sepolia",    eta: "~30 sec" },
  { key: "minted",    label: "Minted",                desc: "wCCC tokens minted on Sepolia",                      eta: null },
  { key: "completed", label: "Complete",              desc: "Bridge transfer finished",                           eta: null },
];

const STEPS_REVERSE = [
  { key: "init",      label: "Burn & Bridge",         desc: "Burn wCCC on Sepolia — no approval needed",          eta: null },
  { key: "locked",    label: "Awaiting Confirmation", desc: "Waiting for 3 block confirmations on Sepolia",       eta: "~45 sec" },
  { key: "confirmed", label: "Relayer Processing",    desc: "Relayer detected burn — unlocking tCCS on Amoy",    eta: "~30 sec" },
  { key: "minted",    label: "Tokens Released",       desc: "tCCS tokens released on Amoy",                      eta: null },
  { key: "completed", label: "Complete",              desc: "Bridge transfer finished",                           eta: null },
];

const STEPS_CBDC = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve INRDC + lock in CBDC Vault", eta: null },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",        eta: "~15 sec" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing approval — minting INRX on Amoy", eta: "~30 sec" },
  { key: "minted",    label: "Stablecoin Minted",       desc: "INRX tokens minted on Polygon Amoy",                      eta: null },
  { key: "completed", label: "Complete",                desc: "CBDC → Stablecoin conversion finished",                    eta: null },
];

const STEPS_TOKEN_INSTRUCTION = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve INRDC + lock with instruction payload", eta: null },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",                   eta: "~15 sec" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing — executing instruction on Amoy",            eta: "~30 sec" },
  { key: "minted",    label: "Instruction Executed",    desc: "Instruction executed on Polygon Amoy",                               eta: null },
  { key: "completed", label: "Complete",                desc: "Token → Instruction bridge finished",                                eta: null },
];

const STEPS_ASSET_INSTRUCTION = [
  { key: "init",      label: "Compliance Check + Lock", desc: "KYC/OFAC verified — approve ERC721 + lock asset with instruction",  eta: null },
  { key: "locked",    label: "Awaiting Confirmation",   desc: "Waiting for 3 block confirmations on local chain",                   eta: "~15 sec" },
  { key: "confirmed", label: "Hub Relay Processing",    desc: "2-of-3 relayers signing — executing asset instruction on Amoy",      eta: "~30 sec" },
  { key: "minted",    label: "Instruction Executed",    desc: "Asset instruction executed on Polygon Amoy",                         eta: null },
  { key: "completed", label: "Complete",                desc: "Asset → Instruction bridge finished",                                eta: null },
];

const STATE_ORDER = ["init", "locked", "confirmed", "minted", "completed"];

function stepStatus(stepKey: string, currentState: string): "done" | "active" | "inactive" {
  const si = STATE_ORDER.indexOf(stepKey);
  const ci = STATE_ORDER.indexOf(currentState);
  if (ci === -1 || currentState === "failed") return si === 0 ? "active" : "inactive";
  if (si < ci) return "done";
  if (si === ci) return "active";
  return "inactive";
}

function truncate(addr: string) {
  return addr ? `${addr.slice(0, 6)}…${addr.slice(-4)}` : "";
}

function chainInfo(id: number) {
  if (id === 80002)    return { name: "Polygon Amoy",     cls: "amoy",    symbol: "POL" };
  if (id === 11155111) return { name: "Ethereum Sepolia", cls: "sepolia", symbol: "ETH" };
  if (id === 31337)    return { name: "Anvil (CBDC)",     cls: "anvil",   symbol: "ETH" };
  return { name: `Chain ${id}`, cls: "unknown", symbol: "?" };
}

export default function BridgePage() {
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const { sendTransactionAsync } = useSendTransaction();
  const publicClient = usePublicClient();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  const [step, setStep]               = useState<Step>("connect");
  const [bridgeMode, setBridgeMode]   = useState<BridgeMode>("evm");
  const [direction, setDirection]     = useState<Direction>("amoy_to_sepolia");
  const [amount, setAmount]           = useState("");
  const [instructionPayload, setInstructionPayload] = useState("");
  const [assetContract, setAssetContract]           = useState("");
  const [assetTokenId, setAssetTokenId]             = useState("");
  const [transferId, setTransferId]   = useState<string | null>(null);
  const [transfer, setTransfer]       = useState<Transfer | null>(null);
  const [config, setConfig]           = useState<BridgeConfig | null>(null);
  const [error, setError]             = useState<string | null>(null);
  const [errorContext, setErrorContext] = useState<"login" | "tx">("tx");
  const [submitting, setSubmitting]   = useState(false);
  const [copied, setCopied]           = useState(false);

  useEffect(() => {
    let cancelled = false;
    const load = () => {
      getConfig()
        .then(({ data }) => { if (!cancelled) setConfig(data); })
        .catch(() => { if (!cancelled) setTimeout(load, 3000); }); // retry every 3s if Phoenix not ready
    };
    load();
    return () => { cancelled = true; };
  }, []);

  const isAnvilMode = direction === "cbdc_to_stablecoin" || direction === "token_to_instruction" || direction === "asset_to_instruction";

  const expectedChain =
    direction === "amoy_to_sepolia" ? (config?.amoy_chain_id ?? 80002) :
    isAnvilMode                     ? (config?.anvil_chain_id ?? 31337) :
    (config?.sepolia_chain_id ?? 11155111);

  const onWrongChain = step === "form" && !!config && chainId !== expectedChain;

  const tokenAddress = config
    ? (direction === "amoy_to_sepolia"                ? config.tccs_token
      : direction === "cbdc_to_stablecoin"            ? (config.mock_cbdc_token ?? "")
      : direction === "token_to_instruction"          ? (config.mock_cbdc_token ?? "")
      : direction === "asset_to_instruction"          ? undefined  // ERC721 — no ERC20 balance
      : config.mint_bridge) as `0x${string}`
    : undefined;

  const { data: balanceData } = useBalance({
    address: address,
    token: tokenAddress,
    query: { enabled: !!address && !!tokenAddress && !onWrongChain },
  });

  const balanceFormatted = balanceData
    ? parseFloat(formatUnits(balanceData.value, balanceData.decimals)).toFixed(4)
    : null;

  const amountNum = parseFloat(amount) || 0;
  const insufficientBalance = !!balanceData && amountNum > 0
    && amountNum > parseFloat(formatUnits(balanceData.value, balanceData.decimals));
  const chain = chainInfo(chainId);
  const steps = direction === "amoy_to_sepolia"      ? STEPS_FORWARD
    : direction === "cbdc_to_stablecoin"              ? STEPS_CBDC
    : direction === "token_to_instruction"            ? STEPS_TOKEN_INSTRUCTION
    : direction === "asset_to_instruction"            ? STEPS_ASSET_INSTRUCTION
    : STEPS_REVERSE;

  // Restore in-progress transfer
  useEffect(() => {
    if (!isConnected) { setStep("connect"); return; }
    if (!isLoggedIn()) { setStep("login"); return; }
    const savedId = localStorage.getItem("activeTransferId");
    if (savedId) {
      getTransfer(savedId).then(({ data: t }) => {
        setTransferId(savedId);
        setTransfer(t);
        setDirection(t.direction as Direction);
        setStep(t.state === "completed" || t.state === "failed" ? "done" : "pending");
        if (t.state === "completed" || t.state === "failed") localStorage.removeItem("activeTransferId");
      }).catch(() => { localStorage.removeItem("activeTransferId"); setStep("form"); });
    } else {
      setStep("form");
    }
  }, [isConnected]);

  // Real-time WebSocket updates
  useEffect(() => {
    if (!transferId) return;
    const token = localStorage.getItem("jwt") ?? "";
    return subscribeToTransfer(transferId, token, (event) => {
      const state = (event as { state?: string }).state;
      if (state) {
        setTransfer((prev) => prev ? { ...prev, state: state as Transfer["state"] } : null);
        if (state === "completed" || state === "failed") {
          setStep("done");
          localStorage.removeItem("activeTransferId");
        }
      }
    });
  }, [transferId]);

  const handleLogin = async () => {
    if (!address) return;
    try {
      await siweLogin(address, (msg) => signMessageAsync({ account: address, message: msg }));
      setStep("form");
    } catch (e) {
      const msg = (e as Error).message;
      setErrorContext("login");
      setError(msg === "Failed to fetch" ? "Cannot reach the backend server. Make sure it is running." : msg);
      setStep("error");
    }
  };

  const handleSubmit = async () => {
    if (!config) return;
    setSubmitting(true);
    setError(null);
    const log = (s: string, d?: unknown) => console.log(`[Bridge] ${s}`, d ?? "");
    const { lock_bridge, mint_bridge, tccs_token, cbdc_vault, asset_vault, mock_cbdc_token, mock_asset_contract } = config;

    try {
      const sourceToken = direction === "asset_to_instruction"
        ? (mock_asset_contract ?? "")
        : direction === "cbdc_to_stablecoin" || direction === "token_to_instruction"
          ? (mock_cbdc_token ?? "")
          : tccs_token;

      const extra = direction === "token_to_instruction"
        ? { instruction_payload: instructionPayload }
        : direction === "asset_to_instruction"
          ? { asset_contract: assetContract || (mock_asset_contract ?? ""), asset_token_id: assetTokenId, instruction_payload: instructionPayload }
          : undefined;

      const { data } = await createTransfer(sourceToken, amount, direction, extra);
      log("created", data.id);
      setTransferId(data.id);
      localStorage.setItem("activeTransferId", data.id);
      setTransfer({ id: data.id, state: "init", direction, wallet: address!, token_address: sourceToken, amount, nonce_hash: "", compliance_status: "approved", source_chain: null, dest_chain: null, transfer_type: null, instruction_payload: null, asset_contract: null, asset_token_id: null, lock_tx_hash: null, mint_tx_hash: null, failure_reason: null, inserted_at: "" });
      setStep("pending");

      const amountWei = BigInt(Math.floor(parseFloat(amount) * 10 ** 18));
      const transferIdBytes = `0x${data.id.replace(/-/g, "").padEnd(64, "0")}` as `0x${string}`;

      if (direction === "amoy_to_sepolia") {
        const fees = { gas: BigInt(120000), maxFeePerGas: BigInt(100_000_000_000), maxPriorityFeePerGas: BigInt(50_000_000_000) };
        const approveTx = await sendTransactionAsync({
          to: tccs_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [lock_bridge as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1 });
        const txHash = await sendTransactionAsync({
          to: lock_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_BRIDGE_ABI, functionName: "lockTokens", args: [tccs_token as `0x${string}`, amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "cbdc_to_stablecoin") {
        const fees = { gas: BigInt(150000) };
        const approveTx = await sendTransactionAsync({
          to: mock_cbdc_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [cbdc_vault as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1 });
        const txHash = await sendTransactionAsync({
          to: cbdc_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_CBDC_ABI, functionName: "lockCBDC", args: [amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "token_to_instruction") {
        const fees = { gas: BigInt(200000) };
        const payloadBytes = instructionPayload.startsWith("0x")
          ? instructionPayload as `0x${string}`
          : `0x${Buffer.from(instructionPayload).toString("hex")}` as `0x${string}`;
        const approveTx = await sendTransactionAsync({
          to: mock_cbdc_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [cbdc_vault as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1 });
        const txHash = await sendTransactionAsync({
          to: cbdc_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_CBDC_INSTRUCTION_ABI, functionName: "lockCBDCWithInstruction", args: [amountWei, transferIdBytes, payloadBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else if (direction === "asset_to_instruction") {
        const fees = { gas: BigInt(200000) };
        const tokenContract = (assetContract || mock_asset_contract) as `0x${string}`;
        const tokenId = BigInt(assetTokenId || 0);
        const payloadBytes = instructionPayload.startsWith("0x")
          ? instructionPayload as `0x${string}`
          : `0x${Buffer.from(instructionPayload).toString("hex")}` as `0x${string}`;
        const approveTx = await sendTransactionAsync({
          to: tokenContract,
          data: encodeFunctionData({ abi: ERC721_APPROVE_ABI, functionName: "approve", args: [asset_vault as `0x${string}`, tokenId] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx, confirmations: 1 });
        const txHash = await sendTransactionAsync({
          to: asset_vault as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_ASSET_ABI, functionName: "lockAsset", args: [tokenContract, tokenId, transferIdBytes, payloadBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);

      } else {
        const fees = { gas: BigInt(80000), maxFeePerGas: BigInt(5_000_000_000), maxPriorityFeePerGas: BigInt(1_000_000_000) };
        const txHash = await sendTransactionAsync({
          to: mint_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: BURN_BRIDGE_ABI, functionName: "burnAndBridge", args: [amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);
      }

      const { data: t } = await getTransfer(data.id);
      setTransfer(t);
    } catch (e) {
      console.error("[Bridge] ERROR", e);
      localStorage.removeItem("activeTransferId");
      setErrorContext("tx");
      const msg = (e as Error).message;
      setError(
        msg === "ofac_blocked" ? "This wallet is on the OFAC sanctions list and cannot use this bridge." :
        msg === "kyc_required" ? "KYC verification required. Your wallet has not been verified. Contact support." :
        msg
      );
      setStep("error");
    } finally {
      setSubmitting(false);
    }
  };

  const reset = () => {
    localStorage.removeItem("activeTransferId");
    setStep("form"); setTransfer(null); setTransferId(null);
    setAmount(""); setInstructionPayload(""); setAssetContract(""); setAssetTokenId("");
    setError(null);
  };

  const handleCancel = async () => {
    if (!transferId) return;
    try {
      await cancelTransfer(transferId);
      reset();
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const handleRetry = async () => {
    if (!transferId) return;
    try {
      await retryTransfer(transferId);
      setTransfer((prev) => prev ? { ...prev, state: "confirmed", failure_reason: null } : null);
      setStep("pending");
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const explorerBase = (dir: Direction, type: "lock" | "mint") => {
    if (type === "lock") return dir === "amoy_to_sepolia" ? "https://amoy.polygonscan.com/tx/" : "https://sepolia.etherscan.io/tx/";
    return dir === "amoy_to_sepolia" ? "https://sepolia.etherscan.io/tx/" : "https://amoy.polygonscan.com/tx/";
  };

  return (
    <div className="page">
      <div className="page-title">Cross-Chain Bridge</div>
      <div className="page-subtitle">Move carbon credits across blockchains, trustlessly</div>

      {/* ── Step 1: Connect ── */}
      {step === "connect" && (
        <div className="card">
          <div className="card-title">
            <span style={{ color: "var(--primary)" }}>01</span> Connect Wallet
          </div>
          <p className="text-muted text-sm" style={{ marginBottom: "1.25rem" }}>
            Connect your MetaMask or WalletConnect wallet to get started.
          </p>
          <ConnectButton />
        </div>
      )}

      {/* ── Step 2: Login ── */}
      {step === "login" && (
        <div className="card" style={{ textAlign: "center" }}>
          <div style={{ fontSize: "2rem", marginBottom: "0.5rem" }}>🔐</div>
          <div className="card-title" style={{ justifyContent: "center" }}>Authenticate</div>
          <p className="text-muted text-sm" style={{ marginBottom: "1.5rem" }}>
            Sign a free off-chain message to prove wallet ownership.<br />No gas, no transaction.
          </p>

          <div style={{
            display: "inline-flex", alignItems: "center", gap: "0.6rem",
            background: "var(--surface2)", border: "1px solid var(--border)",
            borderRadius: 10, padding: "0.6rem 1rem", marginBottom: "1.5rem",
          }}>
            <span style={{ width: 8, height: 8, borderRadius: "50%", background: "var(--primary)", display: "inline-block" }} />
            <span style={{ fontFamily: "monospace", fontSize: "0.88rem" }}>{truncate(address ?? "")}</span>
          </div>

          <div>
            <button className="btn-primary" style={{ width: "100%" }} onClick={handleLogin}>
              Sign with Ethereum
            </button>
            <p style={{ fontSize: "0.72rem", color: "var(--muted)", marginTop: "0.75rem" }}>
              EIP-4361 · SIWE standard · read-only signature
            </p>
          </div>
        </div>
      )}

      {/* ── Step 3: Form ── */}
      {step === "form" && (
        <div className="card">
          <div className="card-title">
            <span style={{ color: "var(--primary)" }}>03</span> Bridge Tokens
          </div>

          {/* Wallet status */}
          <div className="wallet-bar">
            <div className="wallet-address">{truncate(address ?? "")}</div>
            <div className={`chain-badge ${chain.cls}`}>
              <span className="chain-dot" />
              {chain.name}
            </div>
            <span className="text-muted text-sm" style={{ marginLeft: "auto", fontSize: "0.75rem" }}>
              {isLoggedIn() ? <span style={{ color: "var(--primary)" }}>● Authenticated</span> : "Not signed in"}
            </span>
          </div>

          {/* Bridge mode selector */}
          <div style={{ display: "flex", flexWrap: "wrap", gap: "0.5rem", marginBottom: "1rem" }}>
            {([
              { mode: "evm",               label: "EVM Bridge",          sub: "tCCS ↔ wCCC" },
              { mode: "cbdc",              label: "Token → Token",       sub: "INRDC → INRX" },
              { mode: "token_instruction", label: "Token → Instruction", sub: "CBDC + payload" },
              { mode: "asset_instruction", label: "Asset → Instruction", sub: "ERC721 + payload" },
            ] as { mode: BridgeMode; label: string; sub: string }[]).map(({ mode, label, sub }) => (
              <button
                key={mode}
                onClick={() => {
                  setBridgeMode(mode);
                  const dir: Direction =
                    mode === "evm"               ? "amoy_to_sepolia"
                    : mode === "cbdc"            ? "cbdc_to_stablecoin"
                    : mode === "token_instruction" ? "token_to_instruction"
                    : "asset_to_instruction";
                  setDirection(dir);
                }}
                style={{
                  flex: "1 1 calc(50% - 0.25rem)", padding: "0.45rem 0.5rem", borderRadius: 8,
                  fontSize: "0.78rem", fontWeight: 600, cursor: "pointer", textAlign: "center",
                  background: bridgeMode === mode ? "var(--primary)" : "var(--surface2)",
                  color: bridgeMode === mode ? "#000" : "var(--muted)",
                  border: `1px solid ${bridgeMode === mode ? "var(--primary)" : "var(--border)"}`,
                }}
              >
                <div>{label}</div>
                <div style={{ fontSize: "0.68rem", fontWeight: 400, opacity: 0.75 }}>{sub}</div>
              </button>
            ))}
          </div>

          {/* Direction toggle — EVM mode */}
          {bridgeMode === "evm" && (
            <div className="direction-toggle">
              <div className={`chain-box ${direction === "amoy_to_sepolia" ? "active" : ""}`}
                onClick={() => setDirection("amoy_to_sepolia")}>
                <div className="chain-name" style={{ color: direction === "amoy_to_sepolia" ? "var(--primary)" : "var(--text)" }}>
                  Polygon Amoy
                </div>
                <div className="chain-label">tCCS · {direction === "amoy_to_sepolia" ? "Source" : "Destination"}</div>
              </div>
              <button className="swap-btn" onClick={() => setDirection(d => d === "amoy_to_sepolia" ? "sepolia_to_amoy" : "amoy_to_sepolia")}>⇄</button>
              <div className={`chain-box ${direction === "sepolia_to_amoy" ? "active" : ""}`}
                onClick={() => setDirection("sepolia_to_amoy")}>
                <div className="chain-name" style={{ color: direction === "sepolia_to_amoy" ? "var(--primary)" : "var(--text)" }}>
                  Ethereum Sepolia
                </div>
                <div className="chain-label">wCCC · {direction === "sepolia_to_amoy" ? "Source" : "Destination"}</div>
              </div>
            </div>
          )}

          {/* Direction display — CBDC Token→Token mode */}
          {bridgeMode === "cbdc" && (
            <div className="direction-toggle">
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Anvil (CBDC Ledger)</div>
                <div className="chain-label">INRDC · Source · Permissioned</div>
              </div>
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
                <span style={{ fontSize: "1.3rem", color: "var(--primary)" }}>→</span>
                <span style={{ fontSize: "0.65rem", color: "var(--muted)" }}>2-of-3 Hub</span>
              </div>
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Polygon Amoy</div>
                <div className="chain-label">INRX · Destination · Public</div>
              </div>
            </div>
          )}

          {/* Direction display — Token→Instruction mode */}
          {bridgeMode === "token_instruction" && (
            <div className="direction-toggle">
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Anvil (CBDC Ledger)</div>
                <div className="chain-label">INRDC + Instruction · Source</div>
              </div>
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
                <span style={{ fontSize: "1.3rem", color: "var(--primary)" }}>→</span>
                <span style={{ fontSize: "0.65rem", color: "var(--muted)" }}>2-of-3 Hub</span>
              </div>
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Polygon Amoy</div>
                <div className="chain-label">Execute Instruction · Destination</div>
              </div>
            </div>
          )}

          {/* Direction display — Asset→Instruction mode */}
          {bridgeMode === "asset_instruction" && (
            <div className="direction-toggle">
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Anvil (CBDC Ledger)</div>
                <div className="chain-label">ERC721 Asset + Instruction · Source</div>
              </div>
              <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
                <span style={{ fontSize: "1.3rem", color: "var(--primary)" }}>→</span>
                <span style={{ fontSize: "0.65rem", color: "var(--muted)" }}>2-of-3 Hub</span>
              </div>
              <div className="chain-box active">
                <div className="chain-name" style={{ color: "var(--primary)" }}>Polygon Amoy</div>
                <div className="chain-label">Execute Asset Instruction · Destination</div>
              </div>
            </div>
          )}

          {/* Wrong chain warning + auto-switch */}
          {onWrongChain && (
            <div className="warning-banner" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <span>⚠ Switch to <strong>{direction === "amoy_to_sepolia" ? "Polygon Amoy" : "Ethereum Sepolia"}</strong></span>
              <button
                className="btn-secondary"
                style={{ padding: "0.3rem 0.9rem", fontSize: "0.8rem" }}
                onClick={() => switchChain({ chainId: expectedChain })}
              >
                Switch Network
              </button>
            </div>
          )}

          {/* Amount */}
          <div className="amount-wrap">
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div className="amount-label">Amount to bridge</div>
              {balanceFormatted !== null && (
                <div style={{ fontSize: "0.75rem", color: "var(--muted)" }}>
                  Balance: <span style={{ color: "var(--text)" }}>{balanceFormatted}</span>
                  {" "}
                  <button
                    className="btn-secondary"
                    style={{ padding: "0.1rem 0.5rem", fontSize: "0.7rem", marginLeft: 4 }}
                    onClick={() => setAmount(formatUnits(balanceData!.value, balanceData!.decimals))}
                  >
                    Max
                  </button>
                </div>
              )}
            </div>
            <input
              className={`amount-input${insufficientBalance ? " input-error" : ""}`}
              type="number"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0"
            />
            <span className="amount-token">
              {direction === "amoy_to_sepolia" ? "tCCS"
                : direction === "cbdc_to_stablecoin" || direction === "token_to_instruction" ? "INRDC"
                : direction === "asset_to_instruction" ? "N/A"
                : "wCCC"}
            </span>
          </div>
          {insufficientBalance && (
            <div style={{ color: "var(--red)", fontSize: "0.78rem", marginTop: "-0.75rem", marginBottom: "0.75rem" }}>
              Insufficient balance
            </div>
          )}

          {/* Asset fields — Asset→Instruction mode */}
          {bridgeMode === "asset_instruction" && (
            <div style={{ marginBottom: "1rem" }}>
              <div className="amount-label" style={{ marginBottom: "0.4rem" }}>Asset Contract (ERC721)</div>
              <input
                className="amount-input"
                style={{ fontSize: "0.82rem" }}
                type="text"
                value={assetContract}
                onChange={(e) => setAssetContract(e.target.value)}
                placeholder={config?.mock_asset_contract ?? "0x… (leave blank for MockAsset)"}
              />
              <div className="amount-label" style={{ marginTop: "0.75rem", marginBottom: "0.4rem" }}>Token ID</div>
              <input
                className="amount-input"
                type="number"
                value={assetTokenId}
                onChange={(e) => setAssetTokenId(e.target.value)}
                placeholder="0"
              />
            </div>
          )}

          {/* Instruction payload — Token→Instruction and Asset→Instruction */}
          {(bridgeMode === "token_instruction" || bridgeMode === "asset_instruction") && (
            <div style={{ marginBottom: "1rem" }}>
              <div className="amount-label" style={{ marginBottom: "0.4rem" }}>
                Instruction Payload
                <span style={{ fontWeight: 400, color: "var(--muted)", marginLeft: 6, fontSize: "0.72rem" }}>
                  hex (0x…) or UTF-8 text
                </span>
              </div>
              <textarea
                style={{
                  width: "100%", minHeight: 80, padding: "0.5rem 0.75rem",
                  background: "var(--surface2)", border: "1px solid var(--border)",
                  borderRadius: 8, color: "var(--text)", fontSize: "0.8rem",
                  fontFamily: "monospace", resize: "vertical", boxSizing: "border-box",
                }}
                value={instructionPayload}
                onChange={(e) => setInstructionPayload(e.target.value)}
                placeholder='e.g. {"action":"settle","tradeId":"T-001"} or 0xdeadbeef'
              />
            </div>
          )}

          {/* Contract info */}
          {config && (
            <div style={{ marginBottom: "1.25rem" }}>
              <div className="amount-label">Contract Details</div>
              <div className="contract-row">
                <span className="contract-label">{direction === "amoy_to_sepolia" ? "LockBridge (Amoy)" : "MintBridge (Sepolia)"}</span>
                <span className="contract-addr">{truncate(direction === "amoy_to_sepolia" ? config.lock_bridge : config.mint_bridge)}</span>
              </div>
              <div className="contract-row">
                <span className="contract-label">{direction === "amoy_to_sepolia" ? "tCCS Token (Amoy)" : "wCCC Token (Sepolia)"}</span>
                <span className="contract-addr">{truncate(direction === "amoy_to_sepolia" ? config.tccs_token : config.mint_bridge)}</span>
              </div>
              <div className="contract-row">
                <span className="contract-label">Steps</span>
                <span className="contract-addr" style={{ color: "var(--muted)" }}>
                  {direction === "amoy_to_sepolia" ? "Approve → Lock → Mint" : "Burn → Unlock (no approve)"}
                </span>
              </div>
            </div>
          )}

          {!config && <p className="text-muted text-sm" style={{ marginBottom: "1rem" }}>Loading config…</p>}

          <button
            className="btn-primary"
            onClick={handleSubmit}
            disabled={(!amount && direction !== "asset_to_instruction") || !config || onWrongChain || insufficientBalance || submitting}
          >
            {submitting
              ? <span style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
                  <span className="spinner" /> Processing…
                </span>
              : direction === "amoy_to_sepolia"       ? "Lock & Bridge →"
              : direction === "cbdc_to_stablecoin"    ? "Lock CBDC & Convert →"
              : direction === "token_to_instruction"  ? "Lock CBDC + Submit Instruction →"
              : direction === "asset_to_instruction"  ? "Lock Asset + Submit Instruction →"
              : "Burn & Bridge →"
            }
          </button>
        </div>
      )}

      {/* ── Pending ── */}
      {step === "pending" && transfer && (
        <div className="card">
          <div className="card-title">
            <span className="spinner" style={{ width: 18, height: 18 }} />
            Transfer in Progress
          </div>

          <div style={{ marginBottom: "1.5rem" }}>
            <div className="progress-bar">
              <div className="progress-fill" style={{ width: `${stateProgress(transfer.state)}%` }} />
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", marginTop: 6, fontSize: "0.72rem", color: "var(--muted)" }}>
              <span>Init</span><span>Locked</span><span>Confirmed</span><span>Minted</span><span>Done</span>
            </div>
          </div>

          <div className="stepper">
            {steps.map((s) => {
              const status = transfer.state === "failed" && s.key === "init"
                ? "active"
                : stepStatus(s.key, transfer.state);
              return (
                <div key={s.key} className={`step-item ${status}`}>
                  <div className="step-icon">
                    {status === "done" ? "✓" : status === "active" ? "●" : "○"}
                  </div>
                  <div className="step-content">
                    <div className="step-title">{s.label}</div>
                    <div className="step-desc">{s.desc}</div>
                    {status === "active" && s.eta && (
                      <div style={{ fontSize: "0.72rem", color: "var(--primary)", marginTop: 2 }}>
                        ETA {s.eta}
                      </div>
                    )}
                    {s.key === "locked" && transfer.lock_tx_hash && (
                      <a className="step-tx" href={`${explorerBase(transfer.direction as Direction, "lock")}${transfer.lock_tx_hash}`} target="_blank" rel="noreferrer">
                        {transfer.lock_tx_hash.slice(0, 20)}…{transfer.lock_tx_hash.slice(-8)} ↗
                      </a>
                    )}
                    {s.key === "minted" && transfer.mint_tx_hash && (
                      <a className="step-tx" href={`${explorerBase(transfer.direction as Direction, "mint")}${transfer.mint_tx_hash}`} target="_blank" rel="noreferrer">
                        {transfer.mint_tx_hash.slice(0, 20)}…{transfer.mint_tx_hash.slice(-8)} ↗
                      </a>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          <div className="divider" />
          <div className="contract-row">
            <span className="contract-label">Transfer ID</span>
            <span
              className="contract-addr"
              style={{ cursor: "pointer" }}
              title="Click to copy"
              onClick={() => { navigator.clipboard.writeText(transfer.id); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
            >
              {transfer.id} {copied ? <span style={{ color: "var(--primary)", fontSize: "0.7rem" }}>Copied!</span> : <span style={{ color: "var(--muted)", fontSize: "0.7rem" }}>⧉</span>}
            </span>
          </div>
          <div className="contract-row">
            <span className="contract-label">Amount</span>
            <span className="contract-addr" style={{ color: "var(--primary)" }}>
              {transfer.amount} {transfer.direction === "amoy_to_sepolia" ? "tCCS" : "wCCC"}
            </span>
          </div>

          {transfer.state === "init" && !transfer.lock_tx_hash && (
            <div style={{ marginTop: "1.25rem" }}>
              <button className="btn-secondary" style={{ width: "100%", opacity: 0.7 }} onClick={handleCancel}>
                Cancel Transfer
              </button>
              <p style={{ color: "var(--muted)", fontSize: "0.72rem", textAlign: "center", marginTop: 6 }}>
                Safe to cancel — no transaction was submitted yet
              </p>
            </div>
          )}
        </div>
      )}

      {/* ── Done ── */}
      {step === "done" && transfer && (
        <div className={`card ${transfer.state === "completed" ? "success" : "error"}`}>
          <div className="card-title" style={{ fontSize: "1.3rem" }}>
            {transfer.state === "completed" ? "🎉 Transfer Complete!" : "❌ Transfer Failed"}
          </div>

          {transfer.state === "completed" && (
            <p className="text-sm" style={{ color: "var(--primary)", marginBottom: "1.25rem" }}>
              {transfer.direction === "amoy_to_sepolia"    ? `${transfer.amount} wCCC minted to your wallet on Sepolia.`
              : transfer.direction === "cbdc_to_stablecoin" ? `${transfer.amount} INRX minted to your wallet on Polygon Amoy. CBDC locked in vault.`
              : `${transfer.amount} tCCS unlocked to your wallet on Amoy.`}
            </p>
          )}

          <div className="contract-row">
            <span className="contract-label">Transfer ID</span>
            <span
              className="contract-addr"
              style={{ cursor: "pointer" }}
              title="Click to copy"
              onClick={() => { navigator.clipboard.writeText(transfer.id); setCopied(true); setTimeout(() => setCopied(false), 2000); }}
            >
              {transfer.id} {copied ? <span style={{ color: "var(--primary)", fontSize: "0.7rem" }}>Copied!</span> : <span style={{ color: "var(--muted)", fontSize: "0.7rem" }}>⧉</span>}
            </span>
          </div>
          {transfer.lock_tx_hash && (
            <div className="contract-row">
              <span className="contract-label">{transfer.direction === "amoy_to_sepolia" ? "Lock Tx" : "Burn Tx"}</span>
              <a className="contract-addr" style={{ color: "var(--blue)" }}
                href={`${explorerBase(transfer.direction as Direction, "lock")}${transfer.lock_tx_hash}`}
                target="_blank" rel="noreferrer">
                {truncate(transfer.lock_tx_hash)} ↗
              </a>
            </div>
          )}
          {transfer.mint_tx_hash && (
            <div className="contract-row">
              <span className="contract-label">{transfer.direction === "amoy_to_sepolia" ? "Mint Tx" : "Unlock Tx"}</span>
              <a className="contract-addr" style={{ color: "var(--blue)" }}
                href={`${explorerBase(transfer.direction as Direction, "mint")}${transfer.mint_tx_hash}`}
                target="_blank" rel="noreferrer">
                {truncate(transfer.mint_tx_hash)} ↗
              </a>
            </div>
          )}

          <div style={{ marginTop: "1.25rem", display: "flex", gap: "0.75rem" }}>
            {transfer.state === "failed" && transfer.failure_reason?.includes("relay") && (
              <button className="btn-primary" style={{ flex: 1 }} onClick={handleRetry}>
                Retry Relay
              </button>
            )}
            <button className="btn-secondary" style={{ flex: 1 }} onClick={reset}>New Transfer</button>
          </div>
        </div>
      )}

      {/* ── Error ── */}
      {step === "error" && (
        <div className="card error">
          <div className="card-title">
            {errorContext === "login" ? "Sign-In Failed" : "Transaction Failed"}
          </div>
          <p className="text-sm mono" style={{ color: "var(--red)", marginBottom: "0.5rem", wordBreak: "break-word" }}>
            {error}
          </p>
          {errorContext === "login" && (
            <p style={{ fontSize: "0.78rem", color: "var(--muted)", marginBottom: "1.25rem" }}>
              Make sure the BharatSetu backend is running (<code>./dev.sh</code>), then try again.
            </p>
          )}
          {errorContext === "tx" && <div style={{ marginBottom: "1.25rem" }} />}
          <button className="btn-secondary" onClick={() => { localStorage.removeItem("activeTransferId"); setTransfer(null); setTransferId(null); setStep(isLoggedIn() ? "form" : "login"); }}>
            Try Again
          </button>
        </div>
      )}
    </div>
  );
}

function stateProgress(state: string): number {
  return ({ init: 10, locked: 35, confirmed: 60, minted: 85, completed: 100, failed: 100 })[state] ?? 0;
}
