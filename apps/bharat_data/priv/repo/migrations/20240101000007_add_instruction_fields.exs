defmodule BharatData.Repo.Migrations.AddInstructionFields do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :transfer_type,       :string, default: "token_to_token"
      add :instruction_payload, :text
      add :asset_contract,      :string
      add :asset_token_id,      :bigint
    end

    create index(:transfers, [:transfer_type])
  end
end
