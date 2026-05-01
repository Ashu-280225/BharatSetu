defmodule BharatCore.Bridge.TransferSupervisor do
  @moduledoc "Starts and tracks TransferServer processes."

  alias BharatCore.Bridge.TransferServer
  alias BharatData.Transfers

  def start_transfer(attrs) do
    id = Ecto.UUID.generate()

    direction = Map.get(attrs, :direction, "amoy_to_sepolia")
    {source_chain, dest_chain} = chains_for_direction(direction)

    transfer_attrs = %{
      id:                  id,
      wallet:              attrs.wallet,
      token_address:       attrs.token_address,
      amount:              attrs.amount,
      nonce_hash:          compute_nonce(attrs.wallet, id),
      state:               "init",
      direction:           direction,
      compliance_status:   Map.get(attrs, :compliance_status, "approved"),
      source_chain:        source_chain,
      dest_chain:          dest_chain,
      transfer_type:       transfer_type_for_direction(direction),
      instruction_payload: Map.get(attrs, :instruction_payload),
      asset_contract:      Map.get(attrs, :asset_contract),
      asset_token_id:      Map.get(attrs, :asset_token_id),
      destination_zone:    Map.get(attrs, :destination_zone),
      destination_address: Map.get(attrs, :destination_address)
    }

    with {:ok, _record} <- Transfers.create(transfer_attrs) do
      opts = Enum.map(transfer_attrs, fn {k, v} -> {k, v} end)

      case DynamicSupervisor.start_child(
             BharatCore.Bridge.Supervisor,
             {TransferServer, opts}
           ) do
        {:ok, _pid}             -> {:ok, id}
        {:error, {:already_started, _}} -> {:ok, id}
        {:error, reason}        -> {:error, reason}
      end
    end
  end

  defp chains_for_direction("amoy_to_sepolia"),      do: {"amoy", "sepolia"}
  defp chains_for_direction("sepolia_to_amoy"),      do: {"sepolia", "amoy"}
  defp chains_for_direction("cbdc_to_stablecoin"),   do: {"anvil", "amoy"}
  defp chains_for_direction("stablecoin_to_cbdc"),   do: {"amoy", "anvil"}
  defp chains_for_direction("token_to_instruction"), do: {"anvil", "amoy"}
  defp chains_for_direction("asset_to_instruction"), do: {"anvil", "amoy"}
  defp chains_for_direction("evm_to_solana"),        do: {"amoy", "solana_devnet"}
  defp chains_for_direction(_),                      do: {"amoy", "sepolia"}

  defp transfer_type_for_direction("cbdc_to_stablecoin"),   do: "token_to_token"
  defp transfer_type_for_direction("stablecoin_to_cbdc"),   do: "token_to_token"
  defp transfer_type_for_direction("token_to_instruction"), do: "token_to_instruction"
  defp transfer_type_for_direction("asset_to_instruction"), do: "asset_to_instruction"
  defp transfer_type_for_direction(_),                      do: "token_to_token"

  defp compute_nonce(wallet, id) do
    :crypto.hash(:sha256, wallet <> id)
    |> Base.encode16(case: :lower)
    |> then(&"0x#{&1}")
  end
end
