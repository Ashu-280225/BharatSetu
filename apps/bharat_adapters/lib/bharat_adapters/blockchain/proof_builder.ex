defmodule BharatAdapters.Blockchain.ProofBuilder do
  @moduledoc """
  Builds Merkle Patricia Trie receipt proofs for cross-chain verification.

  Given a tx hash on Anvil, fetches the block's full receipt list via
  eth_getBlockReceipts, builds the MPT receipt trie in memory, then
  generates a proof of inclusion for the target tx's receipt.

  The proof can be submitted to StablecoinBridge.executeWithProof() on Amoy,
  where the RLPReader + MerklePatricia Solidity libraries verify it against
  the finalized block hash in BlockHashOracle.
  """

  require Logger
  import Bitwise

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Build a proof for a transaction's lock event on Anvil.

  Returns {:ok, proof_data} where proof_data is:
    %{
      block_number:     integer,
      rlp_block_header: binary,
      tx_index:         integer,
      rlp_receipt:      binary,  # raw RLP bytes (not hex)
      proof_nodes:      [binary],
      log_index:        integer
    }

  log_index is the index of the lock event within the receipt's logs.
  """
  def build(tx_hash_hex, log_event_topic) do
    with {:ok, tx}       <- get_transaction(tx_hash_hex),
         {:ok, block_num} <- parse_hex(tx["blockNumber"]),
         {:ok, tx_index}  <- parse_hex(tx["transactionIndex"]),
         {:ok, receipts}  <- get_block_receipts(block_num),
         {:ok, header}    <- get_block_header_rlp(block_num) do

      receipt_rlp_list = Enum.map(receipts, &receipt_to_rlp/1)

      # Find our receipt at tx_index
      target_receipt_rlp = Enum.at(receipt_rlp_list, tx_index)

      # Build the MPT trie
      trie = build_trie(receipt_rlp_list)

      # Generate proof path for tx_index
      trie_key = rlp_encode_index(tx_index)
      proof_nodes = generate_proof(trie, trie_key)

      # Find log index for the target event topic
      log_index = find_log_index(receipts, tx_index, log_event_topic)

      {:ok, %{
        block_number:     block_num,
        rlp_block_header: header,
        tx_index:         tx_index,
        rlp_receipt:      target_receipt_rlp,
        proof_nodes:      proof_nodes,
        log_index:        log_index
      }}
    end
  end

  # ── RPC calls ──────────────────────────────────────────────────────────────

  defp get_transaction(tx_hash) do
    case rpc("eth_getTransactionByHash", [tx_hash]) do
      {:ok, nil}  -> {:error, :tx_not_found}
      {:ok, tx}   -> {:ok, tx}
      err         -> err
    end
  end

  defp get_block_receipts(block_number) do
    block_hex = "0x" <> Integer.to_string(block_number, 16)
    case rpc("eth_getBlockReceipts", [block_hex]) do
      {:ok, receipts} when is_list(receipts) -> {:ok, receipts}
      {:ok, _}                               -> {:error, :no_receipts}
      err                                    -> err
    end
  end

  defp get_block_header_rlp(block_number) do
    block_hex = "0x" <> Integer.to_string(block_number, 16)
    case rpc("eth_getBlockByNumber", [block_hex, false]) do
      {:ok, block} when is_map(block) -> {:ok, encode_block_header(block)}
      {:ok, nil}                      -> {:error, :block_not_found}
      err                             -> err
    end
  end

  # ── Block header RLP encoding ──────────────────────────────────────────────

  # Encode a block header (from eth_getBlockByNumber) as RLP.
  # Fields in canonical order (EIP-1559 era, no withdrawals for Anvil default):
  #   parentHash, ommersHash, beneficiary, stateRoot, transactionsRoot,
  #   receiptsRoot, logsBloom, difficulty, number, gasLimit, gasUsed,
  #   timestamp, extraData, mixHash, nonce, baseFeePerGas
  defp encode_block_header(block) do
    fields = [
      hex_to_bin(block["parentHash"]),
      hex_to_bin(block["sha3Uncles"]),
      hex_to_bin(block["miner"]),
      hex_to_bin(block["stateRoot"]),
      hex_to_bin(block["transactionsRoot"]),
      hex_to_bin(block["receiptsRoot"]),
      hex_to_bin(block["logsBloom"]),
      hex_int_to_bin(block["difficulty"]),
      hex_int_to_bin(block["number"]),
      hex_int_to_bin(block["gasLimit"]),
      hex_int_to_bin(block["gasUsed"]),
      hex_int_to_bin(block["timestamp"]),
      hex_to_bin(block["extraData"]),
      hex_to_bin(block["mixHash"]),
      hex_to_bin(block["nonce"]),
      hex_int_to_bin(block["baseFeePerGas"])
    ]
    ExRLP.encode(fields)
  end

  # ── Receipt RLP encoding ───────────────────────────────────────────────────

  # Encode a receipt (from eth_getBlockReceipts) as legacy RLP.
  # Fields: [status, cumulativeGasUsed, logsBloom, logs]
  # Each log: [address, topics, data]
  defp receipt_to_rlp(receipt) do
    logs = Enum.map(receipt["logs"] || [], fn log ->
      [
        hex_to_bin(log["address"]),
        Enum.map(log["topics"] || [], &hex_to_bin/1),
        hex_to_bin(log["data"])
      ]
    end)

    fields = [
      hex_int_to_bin(receipt["status"]),
      hex_int_to_bin(receipt["cumulativeGasUsed"]),
      hex_to_bin(receipt["logsBloom"]),
      logs
    ]

    ExRLP.encode(fields)
  end

  # ── MPT trie construction ──────────────────────────────────────────────────

  # Minimal MPT: for sequential receipts (keys are 0, 1, 2, ...) the trie
  # is built as a flat structure. We use a map of nibble-path → RLP value,
  # then build the proof by walking down from root.
  #
  # For a simple sequential list with sequential indices, the trie is compact
  # enough that we can build it as a list of (key, value) pairs and use
  # the standard MPT construction algorithm.

  defp build_trie(receipt_rlp_list) do
    receipt_rlp_list
    |> Enum.with_index()
    |> Enum.map(fn {rlp, idx} -> {rlp_encode_index(idx), rlp} end)
    |> mpt_build()
  end

  # Build MPT from list of {key_bytes, value_bytes} pairs.
  # Returns a node map: hash -> node_rlp
  defp mpt_build(kvs) do
    # Sort by nibble path
    nibble_kvs = Enum.map(kvs, fn {k, v} -> {to_nibbles(k), v} end)
    {root_hash, nodes} = build_node(nibble_kvs, %{})
    %{root: root_hash, nodes: nodes}
  end

  defp build_node([], nodes), do: {nil, nodes}

  defp build_node([{nibbles, value}], nodes) do
    # Leaf node
    encoded_path = encode_hex_prefix(nibbles, true)
    node = ExRLP.encode([encoded_path, value])
    hash = hash_node(node)
    {hash, Map.put(nodes, hash, node)}
  end

  defp build_node(nibble_kvs, nodes) do
    # Check common prefix
    prefix = common_prefix(Enum.map(nibble_kvs, fn {n, _} -> n end))

    if length(prefix) > 0 do
      # Extension node
      rest = Enum.map(nibble_kvs, fn {n, v} -> {Enum.drop(n, length(prefix)), v} end)
      {child_hash, nodes2} = build_node(rest, nodes)
      encoded_path = encode_hex_prefix(prefix, false)
      node = ExRLP.encode([encoded_path, dereference(child_hash, nodes2)])
      hash = hash_node(node)
      {hash, Map.put(nodes2, hash, node)}
    else
      # Branch node: split by first nibble
      branch = Enum.group_by(nibble_kvs, fn {[n | _], _} -> n end, fn {[_ | rest], v} -> {rest, v} end)
      # Also handle empty-key entries (value at this branch)
      {value_entries, keyed_entries} = Enum.split_with(nibble_kvs, fn {n, _} -> n == [] end)
      branch_value = case value_entries do
        [{_, v} | _] -> v
        [] -> <<>>
      end

      {branch_children, nodes2} =
        Enum.reduce(0..15, {[], nodes}, fn i, {acc, n} ->
          children = Map.get(branch, i, [])
          case children do
            [] -> {acc ++ [<<>>], n}
            entries ->
              {child_hash, n2} = build_node(entries, n)
              {acc ++ [dereference(child_hash, n2)], n2}
          end
        end)

      _ = keyed_entries
      node = ExRLP.encode(branch_children ++ [branch_value])
      hash = hash_node(node)
      {hash, Map.put(nodes2, hash, node)}
    end
  end

  defp generate_proof(%{root: root_hash, nodes: node_map}, trie_key) do
    nibbles = to_nibbles(trie_key)
    collect_proof(root_hash, nibbles, node_map, [])
  end

  defp collect_proof(nil, _nibbles, _nodes, acc), do: Enum.reverse(acc)
  defp collect_proof(hash, nibbles, nodes, acc) do
    case Map.get(nodes, hash) do
      nil -> Enum.reverse(acc)
      node_rlp ->
        decoded = ExRLP.decode(node_rlp)
        acc2 = [node_rlp | acc]
        case length(decoded) do
          17 ->
            case nibbles do
              [] -> Enum.reverse(acc2)
              [n | rest] ->
                child = Enum.at(decoded, n)
                next_hash = if byte_size(child) == 32, do: child, else: hash_node(ExRLP.encode(child))
                collect_proof(next_hash, rest, nodes, acc2)
            end
          2 ->
            [encoded_path, child] = decoded
            {is_leaf, path_nibbles} = decode_hex_prefix(encoded_path)
            if is_leaf do
              Enum.reverse(acc2)
            else
              remaining = Enum.drop(nibbles, length(path_nibbles))
              next_hash = if byte_size(child) == 32, do: child, else: hash_node(ExRLP.encode(child))
              collect_proof(next_hash, remaining, nodes, acc2)
            end
        end
    end
  end

  # ── Utility helpers ────────────────────────────────────────────────────────

  defp find_log_index(receipts, tx_index, topic_hex) do
    receipt = Enum.at(receipts, tx_index)
    logs = receipt["logs"] || []
    idx = Enum.find_index(logs, fn log ->
      topics = log["topics"] || []
      Enum.any?(topics, fn t -> String.downcase(t) == String.downcase(topic_hex) end)
    end)
    idx || 0
  end

  defp rlp_encode_index(0), do: <<0x80>>
  defp rlp_encode_index(n) when n < 0x80, do: <<n>>
  defp rlp_encode_index(n) do
    bin = :binary.encode_unsigned(n)
    <<(0x80 + byte_size(bin))>> <> bin
  end

  defp to_nibbles(bytes) do
    for <<n::4 <- bytes>>, do: n
  end

  defp common_prefix([]), do: []
  defp common_prefix([x]), do: x
  defp common_prefix([h | t]) do
    Enum.reduce(t, h, fn nibbles, acc ->
      Enum.zip(acc, nibbles)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(fn {a, _} -> a end)
    end)
  end

  defp encode_hex_prefix(nibbles, is_leaf) do
    flag = if is_leaf, do: 2, else: 0
    {prefix_nibbles, flag2} =
      if rem(length(nibbles), 2) == 1 do
        {[flag + 1 | nibbles], flag + 1}
      else
        {[flag, 0 | nibbles], flag}
      end
    _ = flag2
    nibble_pairs = Enum.chunk_every(prefix_nibbles, 2)
    for [hi, lo] <- nibble_pairs, into: <<>>, do: <<hi::4, lo::4>>
  end

  defp decode_hex_prefix(<<first, rest::binary>>) do
    hi = first >>> 4
    is_leaf = hi >= 2
    odd = rem(hi, 2) == 1
    nibbles = if odd do
      lo = first &&& 0x0f
      [lo | for(<<n::4 <- rest>>, do: n)]
    else
      for(<<n::4 <- rest>>, do: n)
    end
    {is_leaf, nibbles}
  end

  defp hash_node(node_rlp) when byte_size(node_rlp) >= 32 do
    ExKeccak.hash_256(node_rlp)
  end
  defp hash_node(node_rlp), do: node_rlp

  defp dereference(hash, nodes) when byte_size(hash) == 32 do
    # If the node is stored by hash, return the hash as a 32-byte reference
    case Map.get(nodes, hash) do
      nil -> hash
      node_rlp when byte_size(node_rlp) < 32 -> node_rlp
      _ -> hash
    end
  end
  defp dereference(inline, _nodes), do: inline

  defp hex_to_bin("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp hex_to_bin(nil), do: <<>>
  defp hex_to_bin(hex), do: Base.decode16!(hex, case: :mixed)

  defp hex_int_to_bin("0x" <> hex), do: Base.decode16!(hex, case: :mixed) |> strip_leading_zeros()
  defp hex_int_to_bin(nil), do: <<>>
  defp hex_int_to_bin(n) when is_integer(n), do: :binary.encode_unsigned(n) |> strip_leading_zeros()

  defp strip_leading_zeros(<<0, rest::binary>>) when byte_size(rest) > 0,
    do: strip_leading_zeros(rest)
  defp strip_leading_zeros(b), do: b

  defp parse_hex("0x" <> hex), do: {:ok, String.to_integer(hex, 16)}
  defp parse_hex(n) when is_integer(n), do: {:ok, n}

  defp rpc(method, params) do
    anvil_url = Application.get_env(:bharat_core, :anvil_http_url) ||
                raise "anvil_http_url not configured"
    body = Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    case Req.post(anvil_url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{body: %{"error" => err}}}     -> {:error, err}
      {:error, reason}                      -> {:error, reason}
    end
  end
end
