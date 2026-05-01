defmodule BharatData.Repo.Migrations.AddSolanaFieldsToTransfers do
  use Ecto.Migration

  def change do
    alter table(:transfers) do
      add :destination_zone,    :string
      add :destination_address, :binary
      add :solana_slot,         :bigint
      add :solana_tx_sig,       :string
    end

    execute """
      ALTER TABLE transfers DROP CONSTRAINT IF EXISTS transfers_direction_check;
    """, ""

    execute """
      ALTER TABLE transfers ADD CONSTRAINT transfers_direction_check
        CHECK (direction IN (
          'amoy_to_sepolia','sepolia_to_amoy',
          'cbdc_to_stablecoin','stablecoin_to_cbdc',
          'token_to_instruction','asset_to_instruction',
          'evm_to_solana'
        ));
    """, ""
  end
end
