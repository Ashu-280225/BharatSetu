defmodule BharatAdapters.Blockchain.SolanaRpc do
  require Logger

  def get_slot(commitment \\ "finalized") do
    case rpc("getSlot", [%{commitment: commitment}]) do
      {:ok, slot} when is_integer(slot) -> {:ok, slot}
      err -> err
    end
  end

  def get_signatures_for_address(address, opts \\ []) do
    params = [address, Map.new(opts)]
    case rpc("getSignaturesForAddress", params) do
      {:ok, sigs} when is_list(sigs) -> {:ok, sigs}
      err -> err
    end
  end

  def get_transaction(signature) do
    params = [signature, %{encoding: "jsonParsed", commitment: "finalized",
                           maxSupportedTransactionVersion: 0}]
    rpc("getTransaction", params)
  end

  def get_account_info(pubkey) do
    rpc("getAccountInfo", [pubkey, %{encoding: "base64", commitment: "finalized"}])
  end

  def send_transaction(base64_tx) do
    rpc("sendTransaction", [base64_tx, %{encoding: "base64",
                                          skipPreflight: false,
                                          preflightCommitment: "finalized"}])
  end

  defp rpc(method, params) do
    url = Application.get_env(:bharat_core, :solana_rpc_url) ||
          "https://api.devnet.solana.com"

    body = Jason.encode!(%{
      jsonrpc: "2.0",
      id:      :erlang.unique_integer([:positive]),
      method:  method,
      params:  params
    })

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => err}}}     -> {:error, err}
      {:error, reason}                      -> {:error, reason}
    end
  end
end
