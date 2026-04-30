defmodule BharatWeb.Plugs.RequireCompliance do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    wallet = conn.assigns.wallet

    case BharatCore.Compliance.Engine.check(wallet) do
      :ok ->
        conn

      {:error, :ofac_blocked} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "ofac_blocked"})
        |> halt()

      {:error, :kyc_required} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "kyc_required"})
        |> halt()
    end
  end
end
