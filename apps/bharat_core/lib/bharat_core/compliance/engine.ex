defmodule BharatCore.Compliance.Engine do
  @moduledoc false

  alias BharatData.Users

  # Hardcoded OFAC SDN sample list for POC. In production, sync from OFAC API.
  @ofac_blocklist MapSet.new([
    "0x7f268357a8c2552623316e2562d90e642bb538e5",
    "0xd882cfc20f52f2599d84b8e8d58c7fb62cfe344b",
    "0x901bb9583b24d97e995513c6778dc6888ab6870e",
    "0xa7e5d5a720f06526557c513402f2e6b5fa20b008"
  ])

  @doc """
  Runs compliance gate for a wallet before a transfer is created.
  Returns :ok or {:error, reason} where reason is :ofac_blocked | :kyc_required.
  """
  @spec check(String.t()) :: :ok | {:error, :ofac_blocked | :kyc_required}
  def check(wallet) when is_binary(wallet) do
    normalized = String.downcase(wallet)
    with :ok <- check_ofac(normalized),
         :ok <- check_kyc(wallet) do
      :ok
    end
  end

  defp check_ofac(wallet) do
    if MapSet.member?(@ofac_blocklist, wallet) do
      {:error, :ofac_blocked}
    else
      :ok
    end
  end

  defp check_kyc(wallet) do
    case Users.get_kyc_tier(wallet) do
      tier when is_integer(tier) and tier >= 1 -> :ok
      _ -> {:error, :kyc_required}
    end
  end
end
