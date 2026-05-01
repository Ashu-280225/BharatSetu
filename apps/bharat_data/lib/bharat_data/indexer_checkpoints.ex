defmodule BharatData.IndexerCheckpoints do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.IndexerCheckpoint

  @amoy_id         1
  @sepolia_id      2
  @anvil_id        3
  @solana_devnet_id 4

  def get_last_block(chain \\ "amoy") do
    id = chain_id(chain)
    case Repo.get(IndexerCheckpoint, id) do
      nil        -> 0
      checkpoint -> checkpoint.last_processed_block
    end
  end

  def update_last_block(block_number, chain \\ "amoy") do
    id = chain_id(chain)
    IndexerCheckpoint
    |> where([c], c.id == ^id)
    |> Repo.update_all(set: [last_processed_block: block_number, updated_at: DateTime.utc_now()])
    :ok
  end

  def get_last_sig(chain) do
    id = chain_id(chain)
    case Repo.get(IndexerCheckpoint, id) do
      nil -> nil
      cp  -> cp.last_sig
    end
  end

  def update_last_sig(chain, sig) do
    id  = chain_id(chain)
    now = DateTime.utc_now()
    Repo.insert!(
      %IndexerCheckpoint{id: id, chain: chain, last_processed_block: 0, last_sig: sig},
      on_conflict: [set: [last_sig: sig, updated_at: now]],
      conflict_target: :id
    )
    :ok
  end

  def update_last_block_for_chain(chain, block_number) do
    update_last_block(block_number, chain)
  end

  defp chain_id("amoy"),          do: @amoy_id
  defp chain_id("sepolia"),       do: @sepolia_id
  defp chain_id("anvil"),         do: @anvil_id
  defp chain_id("solana_devnet"), do: @solana_devnet_id
  defp chain_id("amoy_evm_escrow"), do: @amoy_id
end
