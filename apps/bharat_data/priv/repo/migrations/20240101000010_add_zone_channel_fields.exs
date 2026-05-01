defmodule BharatData.Repo.Migrations.AddZoneChannelFields do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :channel_id,          :string
      add :token_version,       :string  # "original" | "wrapped"
      add :zone_a_committed_at, :utc_datetime_usec
      add :zone_b_committed_at, :utc_datetime_usec
    end
  end
end
