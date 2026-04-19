"use client";

import { useEffect, useState } from "react";
import { getPrices, listTransfers, Transfer } from "../../lib/api";

const STATE_META: Record<string, { label: string; cls: string }> = {
  init:      { label: "Awaiting Lock",        cls: "init" },
  locked:    { label: "Lock Submitted",        cls: "locked" },
  confirmed: { label: "Confirmed on Chain",    cls: "confirmed" },
  minted:    { label: "Tokens Minted",         cls: "minted" },
  completed: { label: "Completed",             cls: "completed" },
  failed:    { label: "Failed",                cls: "failed" },
};

const DIR_LABEL: Record<string, string> = {
  amoy_to_sepolia: "Amoy → Sepolia",
  sepolia_to_amoy: "Sepolia → Amoy",
};

export default function DashboardPage() {
  const [prices, setPrices]     = useState<Record<string, number>>({});
  const [transfers, setTransfers] = useState<Transfer[]>([]);
  const [loading, setLoading]   = useState(true);

  useEffect(() => {
    getPrices()
      .then((r) => setPrices(r.data as Record<string, number>))
      .catch(() => {});

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

  const completed = transfers.filter((t) => t.state === "completed").length;
  const pending   = transfers.filter((t) => !["completed", "failed"].includes(t.state)).length;
  const volume    = transfers.filter((t) => t.state === "completed").reduce((s, t) => s + Number(t.amount), 0);

  const tokenPrices = Object.entries(prices).filter(([, v]) => typeof v === "number") as [string, number][];

  return (
    <div className="page-wide">
      <div className="page-title">Dashboard</div>
      <div className="page-subtitle">Monitor carbon credit bridge activity and live token prices</div>

      {/* Stats */}
      <div className="stats-grid">
        <div className="stat-card">
          <div className="stat-label">Total Transfers</div>
          <div className="stat-value">{transfers.length}</div>
          <div className="stat-sub">{completed} completed · {pending} pending</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">Volume Bridged</div>
          <div className="stat-value">{volume.toLocaleString()}</div>
          <div className="stat-sub">carbon credits</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">BCT Price</div>
          <div className="stat-value" style={{ fontSize: "1.25rem" }}>
            ${typeof prices["BCT"] === "number" ? (prices["BCT"] as number).toFixed(4) : "—"}
          </div>
          <div className="stat-sub">Base Carbon Tonne</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">Network</div>
          <div className="stat-value" style={{ fontSize: "1rem", paddingTop: 4 }}>
            <div className="chain-badge amoy" style={{ marginBottom: 4, display: "inline-flex" }}>
              <span className="chain-dot" />Amoy
            </div>
            <br />
            <div className="chain-badge sepolia" style={{ marginTop: 4, display: "inline-flex" }}>
              <span className="chain-dot" />Sepolia
            </div>
          </div>
          <div className="stat-sub">both chains active</div>
        </div>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "1.25rem", alignItems: "start" }}>
        {/* Prices */}
        <div className="card">
          <div className="card-title">Live Carbon Prices</div>
          <table>
            <thead>
              <tr>
                <th>Token</th>
                <th>Price (USD)</th>
                <th>Change</th>
              </tr>
            </thead>
            <tbody>
              {tokenPrices.map(([k, v]) => (
                <tr key={k}>
                  <td>
                    <span style={{ fontWeight: 600, fontFamily: "var(--font-mono, monospace)", fontSize: "0.85rem" }}>{k}</span>
                  </td>
                  <td style={{ color: "var(--primary)", fontWeight: 600 }}>
                    ${v.toFixed(4)}
                  </td>
                  <td>
                    <span className="badge completed">live</span>
                  </td>
                </tr>
              ))}
              {tokenPrices.length === 0 && (
                <tr><td colSpan={3} style={{ color: "var(--muted)", textAlign: "center", padding: "1.5rem" }}>Loading…</td></tr>
              )}
            </tbody>
          </table>
        </div>

        {/* Recent transfers */}
        <div className="card">
          <div className="card-title">Recent Transfers</div>
          {loading ? (
            <p className="text-muted text-sm">Loading…</p>
          ) : transfers.length === 0 ? (
            <div style={{ textAlign: "center", padding: "2rem 0" }}>
              <p className="text-muted text-sm">No transfers yet.</p>
              <a href="/bridge" style={{ color: "var(--primary)", fontSize: "0.875rem", textDecoration: "none", display: "inline-block", marginTop: 8 }}>
                Start your first bridge →
              </a>
            </div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Direction</th>
                  <th>Amount</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {transfers.slice(0, 10).map((t) => {
                  const meta = STATE_META[t.state] ?? { label: t.state, cls: "init" };
                  return (
                    <tr key={t.id}>
                      <td>
                        <a href={`/bridge?id=${t.id}`} style={{ fontFamily: "monospace", fontSize: "0.78rem" }}>
                          {t.id.slice(0, 8)}…
                        </a>
                      </td>
                      <td style={{ fontSize: "0.78rem", color: "var(--muted)" }}>
                        {DIR_LABEL[t.direction] ?? t.direction}
                      </td>
                      <td style={{ fontWeight: 600 }}>{t.amount}</td>
                      <td><span className={`badge ${meta.cls}`}>{meta.label}</span></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  );
}
