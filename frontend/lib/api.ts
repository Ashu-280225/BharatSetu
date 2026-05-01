const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:4000/api/v1";

function getToken(): string | null {
  return typeof window !== "undefined" ? localStorage.getItem("jwt") : null;
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(options.headers as Record<string, string>),
  };

  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${API_BASE}${path}`, { ...options, headers });

  if (!res.ok) {
    if (res.status === 401) {
      localStorage.removeItem("jwt");
    }
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error ?? `HTTP ${res.status}`);
  }

  return res.json();
}

// ── Auth ──────────────────────────────────────────────────────────────────

export async function getChallenge(wallet: string) {
  return request<{ nonce: string; domain: string; expiry: string }>(
    "/auth/challenge",
    { method: "POST", body: JSON.stringify({ wallet }) }
  );
}

export async function verifySignature(message: string, signature: string) {
  return request<{ token: string; wallet: string }>(
    "/auth/verify",
    { method: "POST", body: JSON.stringify({ message, signature }) }
  );
}

// ── Transfers ─────────────────────────────────────────────────────────────

export type Transfer = {
  id: string;
  wallet: string;
  token_address: string;
  amount: string;
  nonce_hash: string;
  state: "init" | "locked" | "confirmed" | "minted" | "completed" | "failed";
  direction: "amoy_to_sepolia" | "sepolia_to_amoy" | "cbdc_to_stablecoin" | "stablecoin_to_cbdc" | "token_to_instruction" | "asset_to_instruction";
  compliance_status: "approved" | "rejected" | null;
  source_chain: string | null;
  dest_chain: string | null;
  transfer_type: "token_to_token" | "token_to_instruction" | "asset_to_instruction" | null;
  instruction_payload: string | null;
  asset_contract: string | null;
  asset_token_id: number | null;
  lock_tx_hash: string | null;
  mint_tx_hash: string | null;
  failure_reason: string | null;
  inserted_at: string;
};

export async function createTransfer(
  token_address: string,
  amount: string,
  direction = "amoy_to_sepolia",
  extra?: {
    instruction_payload?: string;
    asset_contract?: string;
    asset_token_id?: string;
  }
) {
  return request<{ data: { id: string; state: string } }>(
    "/transfers",
    { method: "POST", body: JSON.stringify({ token_address, amount, direction, ...extra }) }
  );
}

export async function confirmLock(id: string, tx_hash: string) {
  return request<{ data: { id: string; state: string } }>(
    `/transfers/${id}/lock`,
    { method: "POST", body: JSON.stringify({ tx_hash }) }
  );
}

export async function getTransfer(id: string) {
  return request<{ data: Transfer }>(`/transfers/${id}`);
}

export async function listTransfers() {
  return request<{ data: Transfer[] }>("/transfers");
}

export async function cancelTransfer(id: string) {
  return request<{ data: { id: string; state: string } }>(
    `/transfers/${id}`,
    { method: "DELETE" }
  );
}

export async function retryTransfer(id: string) {
  return request<{ data: { id: string; state: string } }>(
    `/transfers/${id}/retry`,
    { method: "POST" }
  );
}

// ── Prices ────────────────────────────────────────────────────────────────

export async function getPrices() {
  return request<{ data: Record<string, number | Record<string, number>> }>("/prices");
}

// ── Config ────────────────────────────────────────────────────────────────

export type BridgeConfig = {
  // POC v1 — Amoy ↔ Sepolia
  lock_bridge: string;
  mint_bridge: string;
  tccs_token: string;
  amoy_chain_id: number;
  sepolia_chain_id: number;
  // POC v2 — Anvil ↔ Amoy (CBDC ↔ Stablecoin Hub-and-Spoke)
  cbdc_vault: string | null;
  asset_vault: string | null;
  stablecoin_bridge: string | null;
  mock_cbdc_token: string | null;
  mock_asset_contract: string | null;
  block_hash_oracle: string | null;
  anvil_chain_id: number;
};

export async function getConfig() {
  return request<{ data: BridgeConfig }>("/config");
}
