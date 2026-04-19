"use client";

import { useEffect, useState } from "react";
import { getPrices, listTransfers } from "../lib/api";

export default function LandingPage() {
  const [bctPrice, setBctPrice] = useState<number | null>(null);
  const [totalTransfers, setTotalTransfers] = useState<number | null>(null);

  useEffect(() => {
    getPrices()
      .then((r) => {
        const p = r.data as Record<string, number>;
        if (typeof p["BCT"] === "number") setBctPrice(p["BCT"]);
      })
      .catch(() => {});

    const jwt = typeof window !== "undefined" ? localStorage.getItem("jwt") : null;
    if (jwt) {
      listTransfers()
        .then((r) => setTotalTransfers(r.data.length))
        .catch(() => {});
    }
  }, []);

  return (
    <div style={{ maxWidth: 1100, margin: "0 auto", padding: "0 1.5rem" }}>

      {/* ── Hero ── */}
      <section style={{ textAlign: "center", padding: "5rem 1rem 4rem" }}>
        <div style={{
          display: "inline-flex", alignItems: "center", gap: 8,
          background: "rgba(0,255,135,0.08)", border: "1px solid var(--border)",
          borderRadius: 999, padding: "0.3rem 1rem", marginBottom: "1.5rem",
          fontSize: "0.78rem", color: "var(--primary)", fontWeight: 500,
        }}>
          <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--primary)", display: "inline-block" }} />
          Multi-chain · Trustless · Made in India 🇮🇳
        </div>

        <h1 style={{
          fontFamily: "'Space Grotesk', sans-serif",
          fontSize: "clamp(2.2rem, 5vw, 3.8rem)",
          fontWeight: 700,
          lineHeight: 1.1,
          letterSpacing: "-0.03em",
          marginBottom: "1.25rem",
        }}>
          The Carbon Credit<br />
          <span style={{ color: "var(--primary)" }}>Cross-Chain Bridge</span>
        </h1>

        <p style={{
          color: "var(--muted)", fontSize: "1.1rem", maxWidth: 560,
          margin: "0 auto 2.5rem", lineHeight: 1.65,
        }}>
          Move carbon credits across blockchains — trustlessly.
          On-chain escrow. No custodians. No middlemen.
        </p>

        <div style={{ display: "flex", gap: "1rem", justifyContent: "center", flexWrap: "wrap" }}>
          <a href="/bridge" style={{
            background: "var(--primary)", color: "#030712",
            padding: "0.75rem 2rem", borderRadius: 12,
            fontWeight: 700, fontSize: "0.95rem", textDecoration: "none",
            fontFamily: "'Space Grotesk', sans-serif",
            transition: "opacity 0.15s",
          }}>
            Launch Bridge →
          </a>
          <a href="/dashboard" style={{
            border: "1px solid var(--border)", color: "var(--text)",
            padding: "0.75rem 2rem", borderRadius: 12,
            fontWeight: 500, fontSize: "0.95rem", textDecoration: "none",
            background: "var(--surface)",
          }}>
            View Dashboard
          </a>
        </div>
      </section>

      {/* ── Stats bar ── */}
      <section style={{
        display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))",
        gap: "1px", background: "var(--border)",
        border: "1px solid var(--border)", borderRadius: 16,
        overflow: "hidden", marginBottom: "4rem",
      }}>
        {[
          { label: "Chains Connected", value: "2" },
          { label: "Tokens Supported", value: "tCCS / wCCC" },
          { label: "BCT Price", value: bctPrice != null ? `$${bctPrice.toFixed(4)}` : "—" },
          { label: "Bridge Model", value: "Lock & Mint" },
        ].map((s) => (
          <div key={s.label} style={{
            background: "var(--surface)", padding: "1.5rem 1.25rem", textAlign: "center",
          }}>
            <div style={{
              fontSize: "1.4rem", fontWeight: 700, color: "var(--primary)",
              fontFamily: "'Space Grotesk', sans-serif", marginBottom: 4,
            }}>{s.value}</div>
            <div style={{ fontSize: "0.78rem", color: "var(--muted)" }}>{s.label}</div>
          </div>
        ))}
      </section>

      {/* ── How it works ── */}
      <section style={{ marginBottom: "4rem" }}>
        <h2 style={{
          fontFamily: "'Space Grotesk', sans-serif", fontSize: "1.75rem",
          fontWeight: 700, textAlign: "center", marginBottom: "0.5rem",
        }}>How It Works</h2>
        <p style={{ color: "var(--muted)", textAlign: "center", marginBottom: "2.5rem", fontSize: "0.95rem" }}>
          Two directions. Same trustless model.
        </p>

        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "1.25rem" }}>
          {/* Amoy → Sepolia */}
          <div style={{
            background: "var(--surface)", border: "1px solid var(--border)",
            borderRadius: 16, padding: "1.75rem",
          }}>
            <div style={{
              display: "flex", alignItems: "center", gap: 8,
              marginBottom: "1.25rem",
            }}>
              <span style={{
                background: "rgba(0,255,135,0.1)", border: "1px solid rgba(0,255,135,0.25)",
                borderRadius: 8, padding: "0.25rem 0.75rem",
                fontSize: "0.78rem", color: "var(--primary)", fontWeight: 600,
              }}>Amoy → Sepolia</span>
            </div>
            {[
              { n: "1", title: "Approve & Lock", desc: "Approve tCCS spend, then lock tokens into LockBridge escrow on Polygon Amoy." },
              { n: "2", title: "Event Indexed", desc: "Elixir indexer detects the TokensLocked event and confirms after 3 blocks." },
              { n: "3", title: "Relay", desc: "Relayer calls MintBridge on Sepolia with the verified proof." },
              { n: "4", title: "Receive wCCC", desc: "wCCC tokens are minted 1:1 to your wallet on Ethereum Sepolia." },
            ].map((step) => (
              <div key={step.n} style={{ display: "flex", gap: "0.75rem", marginBottom: "1rem" }}>
                <div style={{
                  width: 24, height: 24, borderRadius: "50%", flexShrink: 0,
                  background: "rgba(0,255,135,0.15)", border: "1px solid rgba(0,255,135,0.3)",
                  display: "flex", alignItems: "center", justifyContent: "center",
                  fontSize: "0.72rem", fontWeight: 700, color: "var(--primary)",
                }}>{step.n}</div>
                <div>
                  <div style={{ fontWeight: 600, fontSize: "0.88rem", marginBottom: 2 }}>{step.title}</div>
                  <div style={{ fontSize: "0.8rem", color: "var(--muted)", lineHeight: 1.5 }}>{step.desc}</div>
                </div>
              </div>
            ))}
          </div>

          {/* Sepolia → Amoy */}
          <div style={{
            background: "var(--surface)", border: "1px solid var(--border)",
            borderRadius: 16, padding: "1.75rem",
          }}>
            <div style={{ marginBottom: "1.25rem" }}>
              <span style={{
                background: "rgba(56,189,248,0.1)", border: "1px solid rgba(56,189,248,0.25)",
                borderRadius: 8, padding: "0.25rem 0.75rem",
                fontSize: "0.78rem", color: "var(--blue)", fontWeight: 600,
              }}>Sepolia → Amoy</span>
            </div>
            {[
              { n: "1", title: "Burn wCCC", desc: "Call burnAndBridge on MintBridge. Tokens are burned on Ethereum Sepolia." },
              { n: "2", title: "Event Indexed", desc: "Sepolia indexer detects the TokensBurned event and confirms after 3 blocks." },
              { n: "3", title: "Relay", desc: "Relayer calls unlock on LockBridge on Polygon Amoy." },
              { n: "4", title: "Receive tCCS", desc: "Escrowed tCCS tokens are released 1:1 back to your wallet on Amoy." },
            ].map((step) => (
              <div key={step.n} style={{ display: "flex", gap: "0.75rem", marginBottom: "1rem" }}>
                <div style={{
                  width: 24, height: 24, borderRadius: "50%", flexShrink: 0,
                  background: "rgba(56,189,248,0.15)", border: "1px solid rgba(56,189,248,0.3)",
                  display: "flex", alignItems: "center", justifyContent: "center",
                  fontSize: "0.72rem", fontWeight: 700, color: "var(--blue)",
                }}>{step.n}</div>
                <div>
                  <div style={{ fontWeight: 600, fontSize: "0.88rem", marginBottom: 2 }}>{step.title}</div>
                  <div style={{ fontSize: "0.8rem", color: "var(--muted)", lineHeight: 1.5 }}>{step.desc}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Why trustless ── */}
      <section style={{ marginBottom: "4rem" }}>
        <h2 style={{
          fontFamily: "'Space Grotesk', sans-serif", fontSize: "1.75rem",
          fontWeight: 700, textAlign: "center", marginBottom: "0.5rem",
        }}>Security Guarantees</h2>
        <p style={{ color: "var(--muted)", textAlign: "center", marginBottom: "2.5rem", fontSize: "0.95rem" }}>
          Code enforces the rules. Not promises.
        </p>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: "1rem" }}>
          {[
            {
              icon: "🔒",
              title: "On-Chain Escrow",
              desc: "tCCS locked in LockBridge contract. No one can move them without a valid unlock call from the relayer.",
            },
            {
              icon: "🛡️",
              title: "Replay Protection",
              desc: "Each transferId used once. MintBridge tracks usedNonces on-chain — double-spend impossible.",
            },
            {
              icon: "⚖️",
              title: "1:1 Peg",
              desc: "Mint and unlock amounts match the lock/burn event exactly. Relayer has no discretion over amounts.",
            },
            {
              icon: "⏸️",
              title: "Emergency Pause",
              desc: "Both contracts have a pause function. Owner can halt bridging instantly if an issue is detected.",
            },
          ].map((f) => (
            <div key={f.title} style={{
              background: "var(--surface)", border: "1px solid var(--border)",
              borderRadius: 14, padding: "1.5rem",
            }}>
              <div style={{ fontSize: "1.5rem", marginBottom: "0.75rem" }}>{f.icon}</div>
              <div style={{ fontWeight: 600, marginBottom: "0.4rem", fontSize: "0.95rem" }}>{f.title}</div>
              <div style={{ fontSize: "0.82rem", color: "var(--muted)", lineHeight: 1.6 }}>{f.desc}</div>
            </div>
          ))}
        </div>
      </section>

      {/* ── Contract verification ── */}
      <section style={{
        background: "var(--surface)", border: "1px solid var(--border)",
        borderRadius: 16, padding: "2rem", marginBottom: "4rem",
      }}>
        <h2 style={{
          fontFamily: "'Space Grotesk', sans-serif", fontSize: "1.25rem",
          fontWeight: 700, marginBottom: "0.5rem",
        }}>Verify the Contracts</h2>
        <p style={{ color: "var(--muted)", fontSize: "0.88rem", marginBottom: "1.5rem" }}>
          All bridge logic lives on-chain. Inspect it yourself.
        </p>
        <div style={{ display: "flex", flexDirection: "column", gap: "0.75rem" }}>
          {[
            {
              name: "LockBridge (Polygon Amoy)",
              label: "amoy",
              hint: "Lock + Unlock tCCS",
            },
            {
              name: "MintBridge / wCCC (Ethereum Sepolia)",
              label: "sepolia",
              hint: "Mint + Burn wCCC",
            },
          ].map((c) => (
            <div key={c.name} style={{
              display: "flex", alignItems: "center", gap: "1rem",
              background: "rgba(0,0,0,0.25)", borderRadius: 10,
              padding: "0.875rem 1rem",
            }}>
              <span className={`chain-badge ${c.label}`} style={{ flexShrink: 0 }}>
                <span className="chain-dot" />{c.label.charAt(0).toUpperCase() + c.label.slice(1)}
              </span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 600, fontSize: "0.88rem" }}>{c.name}</div>
                <div style={{ fontSize: "0.75rem", color: "var(--muted)" }}>{c.hint}</div>
              </div>
              <a href="/dashboard" style={{
                color: "var(--primary)", fontSize: "0.8rem",
                textDecoration: "none", whiteSpace: "nowrap",
              }}>
                View config →
              </a>
            </div>
          ))}
        </div>
      </section>

      {/* ── Final CTA ── */}
      <section style={{
        textAlign: "center", padding: "3rem 1rem 5rem",
        borderTop: "1px solid var(--border)",
      }}>
        <h2 style={{
          fontFamily: "'Space Grotesk', sans-serif", fontSize: "1.75rem",
          fontWeight: 700, marginBottom: "0.75rem",
        }}>Ready to Bridge?</h2>
        <p style={{ color: "var(--muted)", marginBottom: "2rem", fontSize: "0.95rem" }}>
          Connect your wallet. Pick a direction. Done in under 2 minutes.
        </p>
        <a href="/bridge" style={{
          background: "var(--primary)", color: "#030712",
          padding: "0.875rem 2.5rem", borderRadius: 12,
          fontWeight: 700, fontSize: "1rem", textDecoration: "none",
          fontFamily: "'Space Grotesk', sans-serif",
          display: "inline-block",
        }}>
          Open Bridge →
        </a>
      </section>
    </div>
  );
}
