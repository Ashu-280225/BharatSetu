defmodule BharatData.Repo.Migrations.AddPocV2Fields do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :compliance_status, :string, null: false, default: "approved"
      add :source_chain, :string, null: false, default: "amoy"
      add :dest_chain, :string, null: false, default: "sepolia"
    end

    create index(:transfers, [:compliance_status])

    # Anvil indexer checkpoint (id=3)
    execute(
      "INSERT INTO indexer_checkpoints (id, chain, last_processed_block, updated_at) VALUES (3, 'anvil', 0, NOW())",
      "DELETE FROM indexer_checkpoints WHERE id = 3"
    )
  end
end
