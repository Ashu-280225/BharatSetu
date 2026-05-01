defmodule BharatData.Schemas.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_states ~w(init locked confirmed minted completed failed)
  @valid_directions ~w(amoy_to_sepolia sepolia_to_amoy cbdc_to_stablecoin stablecoin_to_cbdc token_to_instruction asset_to_instruction evm_to_solana)
  @valid_compliance_statuses ~w(approved rejected)
  @valid_transfer_types ~w(token_to_token token_to_instruction asset_to_instruction)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "transfers" do
    field :wallet,               :string
    field :token_address,        :string
    field :amount,               :decimal
    field :nonce_hash,           :string
    field :state,                :string, default: "init"
    field :direction,            :string, default: "amoy_to_sepolia"
    field :compliance_status,    :string, default: "approved"
    field :source_chain,         :string, default: "amoy"
    field :dest_chain,           :string, default: "sepolia"
    field :transfer_type,        :string, default: "token_to_token"
    field :instruction_payload,  :string
    field :asset_contract,       :string
    field :asset_token_id,       :integer
    field :lock_tx_hash,         :string
    field :lock_block,           :integer
    field :mint_tx_hash,         :string
    field :failure_reason,       :string
    field :relay_attempts,       :integer, default: 0
    field :destination_zone,    :string
    field :destination_address, :binary
    field :solana_slot,         :integer
    field :solana_tx_sig,       :string

    timestamps()
  end

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:id, :wallet, :token_address, :amount, :nonce_hash, :state, :direction,
                    :compliance_status, :source_chain, :dest_chain,
                    :transfer_type, :instruction_payload, :asset_contract, :asset_token_id,
                    :lock_tx_hash, :lock_block, :mint_tx_hash,
                    :failure_reason, :relay_attempts,
                    :destination_zone, :destination_address, :solana_slot, :solana_tx_sig])
    |> validate_required([:wallet, :token_address, :amount, :nonce_hash])
    |> validate_inclusion(:state, @valid_states)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:compliance_status, @valid_compliance_statuses)
    |> validate_inclusion(:transfer_type, @valid_transfer_types)
    |> unique_constraint(:nonce_hash)
  end

  def valid_states, do: @valid_states
  def valid_directions, do: @valid_directions
  def valid_transfer_types, do: @valid_transfer_types
end
