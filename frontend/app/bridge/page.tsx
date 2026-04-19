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

type Direction = "amoy_to_sepolia" | "sepolia_to_amoy";
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
  return { name: `Chain ${id}`, cls: "unknown", symbol: "?" };
}

export default function BridgePage() {
  const { address, isConnected } = useAccount();
  const { signMessageAsync } = useSignMessage();
  const { sendTransactionAsync } = useSendTransaction();
  const publicClient = usePublicClient();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  const [step, setStep]         = useState<Step>("connect");
  const [direction, setDirection] = useState<Direction>("amoy_to_sepolia");
  const [amount, setAmount]     = useState("");
  const [transferId, setTransferId] = useState<string | null>(null);
  const [transfer, setTransfer] = useState<Transfer | null>(null);
  const [config, setConfig]     = useState<BridgeConfig | null>(null);
  const [error, setError]       = useState<string | null>(null);
  const [errorContext, setErrorContext] = useState<"login" | "tx">("tx");
  const [submitting, setSubmitting] = useState(false);
  const [copied, setCopied]     = useState(false);

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

  const expectedChain = direction === "amoy_to_sepolia"
    ? (config?.amoy_chain_id ?? 80002)
    : (config?.sepolia_chain_id ?? 11155111);

  const onWrongChain = step === "form" && !!config && chainId !== expectedChain;

  const tokenAddress = config
    ? (direction === "amoy_to_sepolia" ? config.tccs_token : config.mint_bridge) as `0x${string}`
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
  const steps = direction === "amoy_to_sepolia" ? STEPS_FORWARD : STEPS_REVERSE;

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
    const { lock_bridge, mint_bridge, tccs_token } = config;

    try {
      const { data } = await createTransfer(tccs_token, amount, direction);
      log("created", data.id);
      setTransferId(data.id);
      localStorage.setItem("activeTransferId", data.id);
      setTransfer({ id: data.id, state: "init", direction, wallet: address!, token_address: tccs_token, amount, nonce_hash: "", lock_tx_hash: null, mint_tx_hash: null, inserted_at: "" });
      setStep("pending");

      const amountWei = BigInt(amount) * BigInt(10 ** 18);
      const transferIdBytes = `0x${data.id.replace(/-/g, "").padEnd(64, "0")}` as `0x${string}`;

      if (direction === "amoy_to_sepolia") {
        const fees = { gas: BigInt(120000), maxFeePerGas: BigInt(50_000_000_000), maxPriorityFeePerGas: BigInt(30_000_000_000) };
        const approveTx = await sendTransactionAsync({
          to: tccs_token as `0x${string}`,
          data: encodeFunctionData({ abi: ERC20_APPROVE_ABI, functionName: "approve", args: [lock_bridge as `0x${string}`, amountWei] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: approveTx });

        const txHash = await sendTransactionAsync({
          to: lock_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: LOCK_BRIDGE_ABI, functionName: "lockTokens", args: [tccs_token as `0x${string}`, amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);
      } else {
        const fees = { gas: BigInt(80000), maxFeePerGas: BigInt(5_000_000_000), maxPriorityFeePerGas: BigInt(1_000_000_000) };
        const txHash = await sendTransactionAsync({
          to: mint_bridge as `0x${string}`,
          data: encodeFunctionData({ abi: BURN_BRIDGE_ABI, functionName: "burnAndBridge", args: [amountWei, transferIdBytes] }),
          ...fees,
        });
        await publicClient!.waitForTransactionReceipt({ hash: txHash });
        setTransfer((prev) => prev ? { ...prev, lock_tx_hash: txHash } : null);
        await confirmLock(data.id, txHash);
      }

      const { data: t } = await getTransfer(data.id);
      setTransfer(t);
    } catch (e) {
      console.error("[Bridge] ERROR", e);
      setErrorContext("tx");
      setError((e as Error).message);
      setStep("error");
    } finally {
      setSubmitting(false);
    }
  };

  const reset = () => {
    localStorage.removeItem("activeTransferId");
    setStep("form"); setTransfer(null); setTransferId(null); setAmount(""); setError(null);
    // direction preserved intentionally — user likely wants to bridge back
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

          {/* Direction toggle */}
          <div className="direction-toggle">
            <div className={`chain-box ${direction === "amoy_to_sepolia" ? "active" : ""}`}
              onClick={() => setDirection("amoy_to_sepolia")}>
              <div className="chain-name" style={{ color: direction === "amoy_to_sepolia" ? "var(--primary)" : "var(--text)" }}>
                Polygon Amoy
              </div>
              <div className="chain-label">
                tCCS · {direction === "amoy_to_sepolia" ? "Source" : "Destination"}
              </div>
            </div>
            <button className="swap-btn" onClick={() => setDirection(d => d === "amoy_to_sepolia" ? "sepolia_to_amoy" : "amoy_to_sepolia")}>
              ⇄
            </button>
            <div className={`chain-box ${direction === "sepolia_to_amoy" ? "active" : ""}`}
              onClick={() => setDirection("sepolia_to_amoy")}>
              <div className="chain-name" style={{ color: direction === "sepolia_to_amoy" ? "var(--primary)" : "var(--text)" }}>
                Ethereum Sepolia
              </div>
              <div className="chain-label">
                wCCC · {direction === "sepolia_to_amoy" ? "Source" : "Destination"}
              </div>
            </div>
          </div>

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
              {direction === "amoy_to_sepolia" ? "tCCS" : "wCCC"}
            </span>
          </div>
          {insufficientBalance && (
            <div style={{ color: "var(--red)", fontSize: "0.78rem", marginTop: "-0.75rem", marginBottom: "0.75rem" }}>
              Insufficient balance
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
            disabled={!amount || !config || onWrongChain || insufficientBalance || submitting}
          >
            {submitting
              ? <span style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 8 }}>
                  <span className="spinner" /> Processing…
                </span>
              : direction === "amoy_to_sepolia" ? "Lock & Bridge →" : "Burn & Bridge →"
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
              {transfer.direction === "amoy_to_sepolia"
                ? `${transfer.amount} wCCC has been minted to your wallet on Sepolia.`
                : `${transfer.amount} tCCS has been unlocked to your wallet on Amoy.`}
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
          <button className="btn-secondary" onClick={() => setStep(isLoggedIn() ? "form" : "login")}>
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
