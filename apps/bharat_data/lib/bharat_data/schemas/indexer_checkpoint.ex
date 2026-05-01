defmodule BharatData.Schemas.IndexerCheckpoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "indexer_checkpoints" do
    field :chain,                :string
    field :last_processed_block, :integer
    field :last_sig,             :string

    timestamps(inserted_at: false)
  end

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:id, :chain, :last_processed_block, :last_sig])
    |> validate_required([:id])
  end
end
