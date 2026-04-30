defmodule BharatData.Users do
  alias BharatData.Repo
  alias BharatData.Schemas.User

  def get_or_create(wallet_address) do
    case Repo.get(User, wallet_address) do
      nil ->
        %User{}
        |> User.changeset(%{wallet_address: wallet_address})
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  @doc "Returns the KYC tier (integer) for a wallet, or 0 if not registered."
  def get_kyc_tier(wallet_address) do
    case Repo.get(User, wallet_address) do
      nil -> 0
      user -> user.kyc_tier
    end
  end

  def set_kyc_tier(wallet_address, tier) do
    case Repo.get(User, wallet_address) do
      nil ->
        %User{}
        |> User.changeset(%{wallet_address: wallet_address, kyc_tier: tier})
        |> Repo.insert()

      user ->
        user
        |> User.changeset(%{kyc_tier: tier})
        |> Repo.update()
    end
  end
end
