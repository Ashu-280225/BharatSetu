defmodule BharatData.Repo.Migrations.AddLastSigToIndexerCheckpoints do
  use Ecto.Migration

  def change do
    alter table(:indexer_checkpoints) do
      add :last_sig, :string
    end

    execute """
      INSERT INTO indexer_checkpoints (id, chain, last_processed_block, updated_at)
      VALUES (4, 'solana_devnet', 0, NOW())
      ON CONFLICT (id) DO NOTHING;
    """, ""
  end
end
