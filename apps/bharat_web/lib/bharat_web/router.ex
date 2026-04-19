defmodule BharatWeb.Router do
  use BharatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BharatWeb.Plugs.RateLimit
    plug BharatWeb.Plugs.CorrelationId
  end

  pipeline :authenticated do
    plug BharatWeb.Plugs.VerifyJWT
    plug BharatWeb.Plugs.LoadWallet
  end

  pipeline :kyc_verified do
    plug BharatWeb.Plugs.RequireKYC
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BharatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Public
  scope "/api/v1", BharatWeb do
    pipe_through [:api]

    post "/auth/challenge", AuthController, :challenge
    post "/auth/verify",    AuthController, :verify
    get  "/prices",         PriceController, :index
    get  "/health",         HealthController, :index
    get  "/config",         ConfigController, :index
  end

  # Authenticated — read-only
  scope "/api/v1", BharatWeb do
    pipe_through [:api, :authenticated]

    get "/transfers",        TransferController, :index
    get "/transfers/:id",    TransferController, :show
  end

  # KYC-gated — write operations
  scope "/api/v1", BharatWeb do
    pipe_through [:api, :authenticated, :kyc_verified]

    post   "/transfers",              TransferController, :create
    post   "/transfers/:id/lock",    TransferController, :confirm_lock
    delete "/transfers/:id",         TransferController, :cancel
    post   "/transfers/:id/retry",   TransferController, :retry
  end

  # LiveView dashboard
  scope "/", BharatWeb do
    pipe_through :browser

    live "/dashboard", DashboardLive, :index
  end
end
