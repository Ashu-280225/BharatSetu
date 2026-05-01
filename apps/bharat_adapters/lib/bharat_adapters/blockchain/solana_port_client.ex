defmodule BharatAdapters.Blockchain.SolanaPortClient do
  @moduledoc """
  Elixir port to Node.js for Solana transaction signing.
  Node.js handles @solana/web3.js keypair + transaction building.
  Communicates via stdio JSON (line-delimited).
  """

  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def call(method, payload_json) do
    GenServer.call(__MODULE__, {:call, method, payload_json}, 30_000)
  end

  @impl true
  def init(_) do
    port = Port.open(
      {:spawn, "node #{solana_signer_path()}"},
      [:binary, :use_stdio, {:line, 65536}, :exit_status]
    )
    {:ok, %{port: port, pending: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:call, method, payload_json}, from, state) do
    id = state.next_id
    msg = Jason.encode!(%{id: id, method: method, payload: Jason.decode!(payload_json)})
    Port.command(state.port, msg <> "\n")
    {:noreply, %{state |
      pending: Map.put(state.pending, id, from),
      next_id: id + 1
    }}
  end

  @impl true
  def handle_info({_port, {:data, {:eol, line}}}, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _} ->
            Logger.warning("SolanaPortClient: unknown response id #{id}")
            {:noreply, state}
          {from, pending} ->
            result =
              if Map.has_key?(response, "error"),
                do: {:error, response["error"]},
                else: {:ok, response}
            GenServer.reply(from, result)
            {:noreply, %{state | pending: pending}}
        end

      {:error, _} ->
        Logger.error("SolanaPortClient: invalid JSON from Node: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({_port, {:exit_status, code}}, state) do
    Logger.error("SolanaPortClient: Node.js process exited with code #{code}")
    {:stop, :node_exited, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp solana_signer_path do
    Application.get_env(:bharat_core, :solana_signer_script,
      "apps/bharat_adapters/priv/solana_signer.js")
  end
end
