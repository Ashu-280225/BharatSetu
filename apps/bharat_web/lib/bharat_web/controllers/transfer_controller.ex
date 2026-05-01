defmodule BharatWeb.TransferController do
  use BharatWeb, :controller

  alias BharatCore.Bridge.{TransferServer, TransferSupervisor}
  alias BharatData.{Transfers, Schemas.Transfer}

  def index(conn, _params) do
    wallet = conn.assigns.wallet
    transfers = Transfers.list_by_wallet(wallet)
    json(conn, %{data: Enum.map(transfers, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      transfer ->
        # Merge live FSM state if process is running
        live_state =
          case TransferServer.get_state(id) do
            {:ok, s} -> s.state
            _ -> transfer.state
          end

        json(conn, %{data: serialize(%{transfer | state: to_string(live_state)})})
    end
  end

  def create(conn, params) do
    wallet    = conn.assigns.wallet
    direction = params["direction"] || "amoy_to_sepolia"

    # Compliance gate — required for CBDC flows, advisory for EVM flows
    with :ok <- maybe_check_compliance(direction, wallet) do
      do_create(conn, wallet, direction, params)
    else
      {:error, reason} ->
        conn |> put_status(:forbidden) |> json(%{error: to_string(reason)})
    end
  end

  defp do_create(conn, wallet, direction, params) do
    {destination_zone, destination_address} =
      if direction == "evm_to_solana" do
        pubkey_b58 = params["destination_address"]
        unless pubkey_b58 do
          conn
          |> put_status(:bad_request)
          |> json(%{error: "destination_address required for evm_to_solana"})
          |> halt()
        end
        {"sol:devnet", B58.decode!(pubkey_b58)}
      else
        {nil, nil}
      end

    attrs = %{
      wallet:              wallet,
      token_address:       params["token_address"],
      amount:              parse_amount(params["amount"]),
      direction:           direction,
      compliance_status:   "approved",
      instruction_payload: params["instruction_payload"],
      asset_contract:      params["asset_contract"],
      asset_token_id:      params["asset_token_id"] && String.to_integer(params["asset_token_id"]),
      destination_zone:    destination_zone,
      destination_address: destination_address
    }

    require Logger
    Logger.info("[TransferController.create] wallet=#{wallet} token=#{attrs.token_address} amount=#{attrs.amount} direction=#{direction}")

    case TransferSupervisor.start_transfer(attrs) do
      {:ok, id} ->
        Logger.info("[TransferController.create] OK id=#{id}")
        conn
        |> put_status(:created)
        |> json(%{data: %{id: id, state: "init"}})

      {:error, reason} ->
        Logger.error("[TransferController.create] FAILED reason=#{inspect(reason)}")
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  @cbdc_directions ~w(cbdc_to_stablecoin stablecoin_to_cbdc token_to_instruction asset_to_instruction)

  defp maybe_check_compliance(direction, wallet) when direction in @cbdc_directions do
    BharatCore.Compliance.Engine.check(wallet)
  end
  defp maybe_check_compliance(_direction, _wallet), do: :ok

  def confirm_lock(conn, %{"id" => id, "tx_hash" => tx_hash}) do
    wallet = conn.assigns.wallet

    require Logger
    Logger.info("[TransferController.confirm_lock] id=#{id} wallet=#{wallet} tx=#{tx_hash}")

    case Transfers.get(id, wallet) do
      nil ->
        Logger.error("[TransferController.confirm_lock] NOT FOUND id=#{id} wallet=#{wallet}")
        # Log all transfers in DB for this wallet to help debug
        all = BharatData.Transfers.list_by_wallet(wallet)
        Logger.error("[TransferController.confirm_lock] DB has #{length(all)} transfers for wallet: #{Enum.map(all, & &1.id) |> inspect()}")
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      transfer ->
        Logger.info("[TransferController.confirm_lock] FOUND state=#{transfer.state}")
        TransferServer.lock_submitted(id, tx_hash)
        json(conn, %{data: %{id: id, state: "locked"}})
    end
  end

  def cancel(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      %{state: "init", lock_tx_hash: nil} ->
        Transfers.update_state(id, "failed", %{failure_reason: "cancelled by user"})
        json(conn, %{data: %{id: id, state: "failed"}})

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "transfer cannot be cancelled after submission"})
    end
  end

  def retry(conn, %{"id" => id}) do
    wallet = conn.assigns.wallet

    case Transfers.get(id, wallet) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      %{state: "failed", failure_reason: reason} when not is_nil(reason) ->
        if String.contains?(reason, "relay") do
          case Transfers.reset_for_retry(id) do
            {:ok, :reset} -> json(conn, %{data: %{id: id, state: "confirmed"}})
            {:error, _}   -> conn |> put_status(:unprocessable_entity) |> json(%{error: "reset failed"})
          end
        else
          conn |> put_status(:conflict) |> json(%{error: "only relay failures can be retried"})
        end

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "transfer is not in a retryable state"})
    end
  end

  defp serialize(%Transfer{} = t) do
    %{
      id:                  t.id,
      wallet:              t.wallet,
      token_address:       t.token_address,
      amount:              t.amount,
      nonce_hash:          t.nonce_hash,
      state:               t.state,
      direction:           t.direction,
      compliance_status:   t.compliance_status,
      source_chain:        t.source_chain,
      dest_chain:          t.dest_chain,
      transfer_type:       t.transfer_type,
      instruction_payload: t.instruction_payload,
      asset_contract:      t.asset_contract,
      asset_token_id:      t.asset_token_id,
      lock_tx_hash:        t.lock_tx_hash,
      mint_tx_hash:        t.mint_tx_hash,
      failure_reason:      t.failure_reason,
      inserted_at:         t.inserted_at
    }
  end

  defp serialize(map), do: map

  defp parse_amount(nil), do: Decimal.new(0)
  defp parse_amount(n) when is_integer(n), do: Decimal.new(n)
  defp parse_amount(s) when is_binary(s), do: Decimal.new(s)
  defp parse_amount(f) when is_float(f), do: Decimal.from_float(f)
end
