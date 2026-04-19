defmodule BharatWeb.ConfigController do
  use BharatWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      data: %{
        lock_bridge:   Application.get_env(:bharat_core, :lock_contract),
        mint_bridge:   Application.get_env(:bharat_core, :mint_contract),
        tccs_token:    Application.get_env(:bharat_core, :tccs_token, "0x3CcbD8c7b63363998e63F73E92fF72c5813bE4eB"),
        amoy_chain_id: 80002,
        sepolia_chain_id: 11_155_111
      }
    })
  end
end
