defmodule BharatWeb.ConfigController do
  use BharatWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      data: %{
        # POC v1 — Amoy ↔ Sepolia
        lock_bridge:      Application.get_env(:bharat_core, :lock_contract),
        mint_bridge:      Application.get_env(:bharat_core, :mint_contract),
        tccs_token:       Application.get_env(:bharat_core, :tccs_token, "0x3CcbD8c7b63363998e63F73E92fF72c5813bE4eB"),
        amoy_chain_id:    80_002,
        sepolia_chain_id: 11_155_111,
        # POC v2 — Anvil ↔ Amoy (CBDC ↔ Stablecoin)
        cbdc_vault:            Application.get_env(:bharat_core, :cbdc_vault_contract),
        asset_vault:           Application.get_env(:bharat_core, :asset_vault_contract),
        stablecoin_bridge:     Application.get_env(:bharat_core, :stablecoin_bridge_contract),
        mock_cbdc_token:       Application.get_env(:bharat_core, :mock_cbdc_token),
        mock_asset_contract:   Application.get_env(:bharat_core, :mock_asset_contract),
        anvil_chain_id:        31_337
      }
    })
  end
end
