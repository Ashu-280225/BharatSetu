defmodule BharatAdapters.Blockchain.Contract do
  @moduledoc """
  Ethereum contract interaction layer.
  Wraps Ethereumex (Polygon Amoy) for indexer reads.
  Uses Req directly for Sepolia writes (relayer minting).
  """

  require Logger

  # keccak256("TokensLocked(address,address,uint256,bytes32,bytes32)")
  @tokens_locked_topic "0xa4da05d95d26d78a21cff87ae79a365e9e40f1b813298b6553033965693e1090"

  # keccak256("TokensBurned(address,uint256,bytes32,bytes32)")
  @tokens_burned_topic "0x76802cff36c98e0fd357b353b62bdf235862d5c71277fcc4827fce74d4d0a487"

  # Sepolia chain ID
  @sepolia_chain_id 11_155_111

  # Amoy chain ID
  @amoy_chain_id 80_002

  def tokens_locked_topic, do: @tokens_locked_topic
  def tokens_burned_topic, do: @tokens_burned_topic

  # Build lockTokens() calldata for MetaMask (returned to frontend as hex)
  def build_lock_tx(token_address, amount, transfer_id) do
    calldata = encode_call(
      "lockTokens(address,uint256,bytes32)",
      [addr(token_address), uint(amount), bytes32(transfer_id)]
    )
    %{
      to:   lock_contract_address(),
      data: "0x" <> Base.encode16(calldata, case: :lower),
      gas:  "0x30D40"
    }
  end

  # Submit mintOnProof() from relayer wallet on Sepolia.
  def mint_on_proof(to_wallet, nonce_hash, amount) do
    calldata = encode_call(
      "mintOnProof(address,bytes32,uint256)",
      [addr(to_wallet), bytes32_hex(nonce_hash), uint(amount)]
    )

    relayer_key  = relayer_private_key()
    mint_address = mint_contract_address()
    sepolia_url  = Application.get_env(:bharat_core, :sepolia_http_url) ||
                   raise "sepolia_http_url not configured"

    with {:ok, nonce}     <- eth_get_nonce(sepolia_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(sepolia_url),
         {:ok, signed}    <- sign_tx(relayer_key, mint_address, calldata, nonce, gas_price),
         {:ok, tx_hash}   <- eth_send_raw(sepolia_url, signed) do
      Logger.info("mintOnProof submitted on Sepolia: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("mintOnProof failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fetch current block number from Polygon Amoy (via Ethereumex global config)
  def current_block_number do
    case Ethereumex.HttpClient.eth_block_number() do
      {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
      {:error, reason}   -> {:error, reason}
    end
  end

  # Get logs from Polygon Amoy (TokensLocked events)
  def get_logs(from_block, to_block) do
    params = %{
      fromBlock: "0x" <> Integer.to_string(from_block, 16),
      toBlock:   "0x" <> Integer.to_string(to_block, 16),
      address:   lock_contract_address(),
      topics:    [@tokens_locked_topic]
    }
    Ethereumex.HttpClient.eth_get_logs(params)
  end

  # Get logs from Ethereum Sepolia (TokensBurned events)
  def get_sepolia_logs(from_block, to_block) do
    params = %{
      fromBlock: "0x" <> Integer.to_string(from_block, 16),
      toBlock:   "0x" <> Integer.to_string(to_block, 16),
      address:   mint_contract_address(),
      topics:    [@tokens_burned_topic]
    }
    sepolia_url = Application.get_env(:bharat_core, :sepolia_http_url) ||
                  raise "sepolia_http_url not configured"
    rpc(sepolia_url, "eth_getLogs", [params])
  end

  # Get current block number from Sepolia
  def sepolia_block_number do
    sepolia_url = Application.get_env(:bharat_core, :sepolia_http_url) ||
                  raise "sepolia_http_url not configured"
    case rpc(sepolia_url, "eth_blockNumber", []) do
      {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
      {:ok, hex}         -> {:ok, String.to_integer(hex, 16)}
      err                -> err
    end
  end

  # Unlock tCCS on Amoy — called by relayer after Sepolia burn confirmed
  def unlock_on_amoy(to_wallet, token_address, nonce_hash, amount) do
    calldata = encode_call(
      "unlock(address,address,uint256,bytes32)",
      [addr(to_wallet), addr(token_address), uint(amount), bytes32_hex(nonce_hash)]
    )

    relayer_key  = relayer_private_key()
    amoy_url     = Application.get_env(:bharat_core, :polygon_http_url) ||
                   raise "polygon_http_url not configured"

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, lock_contract_address(), calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("unlock_on_amoy submitted: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("unlock_on_amoy failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── EIP-155 Transaction Signing ──────────────────────────────────────────

  defp sign_tx(private_key_hex, to, calldata, nonce, gas_price) do
    sign_tx_for_chain(private_key_hex, to, calldata, nonce, gas_price, @sepolia_chain_id)
  end

  defp sign_tx_for_chain(private_key_hex, to, calldata, nonce, gas_price, chain_id) do
    private_key = decode_hex(private_key_hex)
    gas_limit   = 200_000
    to_bytes    = decode_hex(to)

    tx_fields = [
      encode_int(nonce),
      encode_int(gas_price),
      encode_int(gas_limit),
      to_bytes,
      <<>>,
      calldata,
      encode_int(chain_id),
      <<>>,
      <<>>
    ]

    rlp_encoded = ExRLP.encode(tx_fields)
    hash        = ExKeccak.hash_256(rlp_encoded)

    case ExSecp256k1.sign_compact(hash, private_key) do
      {:ok, {sig, recovery_id}} ->
        <<r::binary-32, s::binary-32>> = sig
        v = chain_id * 2 + 35 + recovery_id

        signed_fields = [
          encode_int(nonce),
          encode_int(gas_price),
          encode_int(gas_limit),
          to_bytes,
          <<>>,
          calldata,
          encode_int(v),
          r,
          s
        ]

        raw = ExRLP.encode(signed_fields)
        {:ok, "0x" <> Base.encode16(raw, case: :lower)}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  defp relayer_address(private_key_hex) do
    private_key = decode_hex(private_key_hex)
    # Derive public key then address
    case ExSecp256k1.create_public_key(private_key) do
      {:ok, <<4, pub::binary-64>>} ->
        hash = ExKeccak.hash_256(pub)
        <<_::binary-12, addr::binary-20>> = hash
        "0x" <> Base.encode16(addr, case: :lower)

      _ ->
        raise "Cannot derive relayer address from private key"
    end
  end

  # ── JSON-RPC helpers (direct HTTP to Sepolia) ─────────────────────────────

  defp eth_get_nonce(url, address) do
    case rpc(url, "eth_getTransactionCount", [address, "pending"]) do
      {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
      {:ok, val}         -> {:ok, String.to_integer(val, 16)}
      err                -> err
    end
  end

  defp eth_gas_price(url) do
    case rpc(url, "eth_gasPrice", []) do
      {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
      {:ok, val}         -> {:ok, String.to_integer(val, 16)}
      err                -> err
    end
  end

  defp eth_send_raw(url, signed_tx) do
    case rpc(url, "eth_sendRawTransaction", [signed_tx]) do
      {:ok, tx_hash} -> {:ok, tx_hash}
      err            -> err
    end
  end

  defp rpc(url, method, params) do
    body = Jason.encode!(%{jsonrpc: "2.0", id: :erlang.unique_integer([:positive]), method: method, params: params})

    case Req.post(url, body: body, headers: [{"content-type", "application/json"}]) do
      {:ok, %{body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{body: %{"error" => err}}} ->
        {:error, err}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── ABI encoding ─────────────────────────────────────────────────────────

  defp encode_call(selector, encoded_args) do
    <<method_id::binary-4, _::binary>> = ExKeccak.hash_256(selector)
    method_id <> IO.iodata_to_binary(encoded_args)
  end

  # address → 32-byte ABI word (12 zero bytes + 20-byte address)
  defp addr("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :mixed)
  defp addr(hex),          do: addr("0x" <> hex)

  # uint256 → 32-byte big-endian
  defp uint(n) when is_integer(n) do
    <<n::big-unsigned-integer-256>>
  end
  defp uint(%Decimal{} = d), do: d |> Decimal.to_integer() |> uint()
  defp uint(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> uint(n)
      :error -> <<0::256>>
    end
  end

  # bytes32 from binary
  defp bytes32(b) when is_binary(b) and byte_size(b) == 32, do: b
  defp bytes32(s) when is_binary(s) do
    hex = String.trim_leading(s, "0x")
    raw = Base.decode16!(hex, case: :mixed)
    pad = max(0, 32 - byte_size(raw))
    :binary.copy(<<0>>, pad) <> raw
  end

  # bytes32 from hex string
  defp bytes32_hex("0x" <> hex) do
    raw = Base.decode16!(hex, case: :mixed)
    pad = max(0, 32 - byte_size(raw))
    :binary.copy(<<0>>, pad) <> raw
  end
  defp bytes32_hex(hex), do: bytes32_hex("0x" <> hex)

  # integer → minimal big-endian binary (for RLP)
  defp encode_int(0), do: <<>>
  defp encode_int(n) when n > 0 do
    bin = :binary.encode_unsigned(n)
    bin
  end

  defp decode_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex(hex),          do: Base.decode16!(hex, case: :mixed)

  defp relayer_private_key do
    Application.get_env(:bharat_core, :relayer_private_key) ||
      raise "relayer_private_key not configured"
  end

  defp lock_contract_address do
    Application.get_env(:bharat_core, :lock_contract) ||
      raise "lock_contract not configured"
  end

  defp mint_contract_address do
    Application.get_env(:bharat_core, :mint_contract) ||
      raise "mint_contract not configured"
  end
end
