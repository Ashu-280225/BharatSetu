defmodule BharatData.IndexerCheckpoints do
  import Ecto.Query
  alias BharatData.Repo
  alias BharatData.Schemas.IndexerCheckpoint

  @amoy_id    1
  @sepolia_id 2
  @anvil_id   3

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

  defp chain_id("amoy"),    do: @amoy_id
  defp chain_id("sepolia"), do: @sepolia_id
  defp chain_id("anvil"),   do: @anvil_id
end
