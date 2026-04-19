"use client";

import { useEffect, useState } from "react";
import { listTransfers, Transfer } from "../../lib/api";

type Filter = "all" | "active" | "completed" | "failed";

const STATE_META: Record<string, { label: string; cls: string }> = {
  init:      { label: "Awaiting Tx",      cls: "init" },
  locked:    { label: "Lock Submitted",   cls: "locked" },
  confirmed: { label: "Confirming",       cls: "confirmed" },
  minted:    { label: "Minted",           cls: "minted" },
  completed: { label: "Completed",        cls: "completed" },
  failed:    { label: "Failed",           cls: "failed" },
};

const ACTIVE_STATES = ["init", "locked", "confirmed", "minted"];

const EXPLORER: Record<string, { lock: string; mint: string }> = {
  amoy_to_sepolia: {
    lock: "https://amoy.polygonscan.com/tx/",
    mint: "https://sepolia.etherscan.io/tx/",
  },
  sepolia_to_amoy: {
    lock: "https://sepolia.etherscan.io/tx/",
    mint: "https://amoy.polygonscan.com/tx/",
  },
};

function truncate(s: string, n = 8) {
  return s ? `${s.slice(0, n)}…${s.slice(-6)}` : "—";
}

function formatDate(iso: string) {
  return new Date(iso).toLocaleString(undefined, {
    month: "short", day: "numeric",
    hour: "2-digit", minute: "2-digit",
  });
}

function copyText(text: string, setCopied: (id: string) => void, id: string) {
  navigator.clipboard.writeText(text);
  setCopied(id);
  setTimeout(() => setCopied(""), 1500);
}

export default function HistoryPage() {
  const [transfers, setTransfers] = useState<Transfer[]>([]);
  const [loading, setLoading]     = useState(true);
  const [filter, setFilter]       = useState<Filter>("all");
  const [copiedId, setCopiedId]   = useState("");

  useEffect(() => {
    const jwt = localStorage.getItem("jwt");
    if (!jwt) {
      window.location.href = "/bridge";
      return;
    }
    listTransfers()
      .then((r) => setTransfers(r.data))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = transfers.filter((t) => {
    if (filter === "active")    return ACTIVE_STATES.includes(t.state);
    if (filter === "completed") return t.state === "completed";
    if (filter === "failed")    return t.state === "failed";
    return true;
  });

  const active    = transfers.filter((t) => ACTIVE_STATES.includes(t.state)).length;
  const completed = transfers.filter((t) => t.state === "completed").length;
  const failed    = transfers.filter((t) => t.state === "failed").length;

  return (
    <div className="page-wide">
      <div className="page-title">Transfer History</div>
      <div className="page-subtitle">All bridge transfers for your wallet</div>

      {/* Filter tabs */}
      <div style={{ display: "flex", gap: "0.5rem", marginBottom: "1.25rem", flexWrap: "wrap" }}>
        {(["all", "active", "completed", "failed"] as Filter[]).map((f) => {
          const count = f === "all" ? transfers.length : f === "active" ? active : f === "completed" ? completed : failed;
          return (
            <button
              key={f}
              onClick={() => setFilter(f)}
              style={{
                padding: "0.35rem 1rem",
                borderRadius: 8,
                border: filter === f ? "1px solid var(--primary)" : "1px solid var(--border)",
                background: filter === f ? "rgba(0,255,135,0.08)" : "var(--surface)",
                color: filter === f ? "var(--primary)" : "var(--muted)",
                cursor: "pointer",
                fontSize: "0.82rem",
                fontWeight: filter === f ? 600 : 400,
              }}
            >
              {f.charAt(0).toUpperCase() + f.slice(1)}
              <span style={{ marginLeft: 6, opacity: 0.7 }}>({count})</span>
            </button>
          );
        })}
      </div>

      <div className="card" style={{ padding: 0, overflow: "hidden" }}>
        {loading ? (
          <p className="text-muted text-sm" style={{ padding: "2rem", textAlign: "center" }}>Loading…</p>
        ) : filtered.length === 0 ? (
          <div style={{ padding: "3rem", textAlign: "center" }}>
            <p className="text-muted text-sm">
              {transfers.length === 0 ? "No transfers yet." : `No ${filter} transfers.`}
            </p>
            {transfers.length === 0 && (
              <a href="/bridge" style={{ color: "var(--primary)", fontSize: "0.875rem", textDecoration: "none", display: "inline-block", marginTop: 8 }}>
                Start your first bridge →
              </a>
            )}
          </div>
        ) : (
          <table style={{ width: "100%" }}>
            <thead>
              <tr>
                <th>Transfer ID</th>
                <th>Direction</th>
                <th>Amount</th>
                <th>Status</th>
                <th>Date</th>
                <th>Txs</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((t) => {
                const meta = STATE_META[t.state] ?? { label: t.state, cls: "init" };
                const ex   = EXPLORER[t.direction] ?? EXPLORER.amoy_to_sepolia;
                const isCopied = copiedId === t.id;
                return (
                  <tr key={t.id}>
                    <td>
                      <span
                        style={{ fontFamily: "monospace", fontSize: "0.78rem", cursor: "pointer" }}
                        title="Click to copy"
                        onClick={() => copyText(t.id, setCopiedId, t.id)}
                      >
                        {truncate(t.id, 8)}
                        {" "}
                        <span style={{ color: isCopied ? "var(--primary)" : "var(--muted)", fontSize: "0.68rem" }}>
                          {isCopied ? "Copied!" : "⧉"}
                        </span>
                      </span>
                    </td>
                    <td style={{ fontSize: "0.78rem", color: "var(--muted)", whiteSpace: "nowrap" }}>
                      {t.direction === "amoy_to_sepolia" ? "Amoy → Sepolia" : "Sepolia → Amoy"}
                    </td>
                    <td style={{ fontWeight: 600, fontSize: "0.88rem" }}>
                      {t.amount}
                      {" "}
                      <span style={{ color: "var(--muted)", fontSize: "0.72rem" }}>
                        {t.direction === "amoy_to_sepolia" ? "tCCS" : "wCCC"}
                      </span>
                    </td>
                    <td>
                      <span className={`badge ${meta.cls}`}>{meta.label}</span>
                      {t.failure_reason && (
                        <div style={{ fontSize: "0.65rem", color: "var(--red)", marginTop: 2, maxWidth: 140, wordBreak: "break-word" }}>
                          {t.failure_reason}
                        </div>
                      )}
                    </td>
                    <td style={{ fontSize: "0.75rem", color: "var(--muted)", whiteSpace: "nowrap" }}>
                      {formatDate(t.inserted_at)}
                    </td>
                    <td style={{ fontSize: "0.75rem" }}>
                      <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                        {t.lock_tx_hash && (
                          <a href={`${ex.lock}${t.lock_tx_hash}`} target="_blank" rel="noreferrer"
                            style={{ color: "var(--primary)" }}>
                            {t.direction === "amoy_to_sepolia" ? "Lock" : "Burn"} ↗
                          </a>
                        )}
                        {t.mint_tx_hash && (
                          <a href={`${ex.mint}${t.mint_tx_hash}`} target="_blank" rel="noreferrer"
                            style={{ color: "var(--blue)" }}>
                            {t.direction === "amoy_to_sepolia" ? "Mint" : "Unlock"} ↗
                          </a>
                        )}
                        {!t.lock_tx_hash && !t.mint_tx_hash && (
                          <span style={{ color: "var(--muted)" }}>—</span>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
