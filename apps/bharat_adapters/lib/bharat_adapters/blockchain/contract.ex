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

  # keccak256("CBDCLocked(address,uint256,bytes32,bytes32,uint8,bytes)") — CBDCVault
  @cbdc_locked_topic "0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8"

  # keccak256("TokensBurned(address,uint256,bytes32)") — StablecoinBridge burn event
  @stablecoin_burned_topic "0x52916471973ae53f679d702015168c0a34628d9d95a48de6bd2093661e39a7c3"

  # keccak256("AssetLocked(address,address,uint256,bytes32,bytes32,string,bytes32,bytes)") — AssetVault
  # Recompute with: cast keccak "AssetLocked(address,address,uint256,bytes32,bytes32,string,bytes32,bytes)"
  @asset_locked_topic "0x0000000000000000000000000000000000000000000000000000000000000000"

  # Sepolia chain ID
  @sepolia_chain_id 11_155_111

  # Amoy chain ID
  @amoy_chain_id 80_002

  # keccak256("TokensLockedForZone(bytes32,address,uint256,address,string,bytes32,bytes)")
  # Compute with: cast keccak "TokensLockedForZone(bytes32,address,uint256,address,string,bytes32,bytes)"
  @tokens_locked_for_zone_topic "0x0000000000000000000000000000000000000000000000000000000000000000"

  def tokens_locked_topic, do: @tokens_locked_topic
  def tokens_burned_topic, do: @tokens_burned_topic
  def cbdc_locked_topic, do: @cbdc_locked_topic
  def stablecoin_burned_topic, do: @stablecoin_burned_topic
  def asset_locked_topic, do: @asset_locked_topic

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

  # ── POC v2: Anvil / CBDCVault / StablecoinBridge ─────────────────────────

  # Build lockCBDC() calldata for MetaMask (user calls on Anvil)
  def build_lock_cbdc_tx(amount, transfer_id) do
    calldata = encode_call(
      "lockCBDC(uint256,bytes32)",
      [uint(amount), bytes32(transfer_id)]
    )
    %{
      to:   cbdc_vault_address(),
      data: "0x" <> Base.encode16(calldata, case: :lower),
      gas:  "0x30D40"
    }
  end

  # Get current block number from Anvil local node
  def anvil_block_number do
    anvil_url = anvil_http_url()
    case rpc(anvil_url, "eth_blockNumber", []) do
      {:ok, "0x" <> hex} -> {:ok, String.to_integer(hex, 16)}
      {:ok, hex}         -> {:ok, String.to_integer(hex, 16)}
      err                -> err
    end
  end

  # Get CBDCLocked + AssetLocked logs from Anvil (both vault contracts).
  def get_anvil_logs(from_block, to_block) do
    params = %{
      fromBlock: "0x" <> Integer.to_string(from_block, 16),
      toBlock:   "0x" <> Integer.to_string(to_block, 16),
      address:   [cbdc_vault_address(), asset_vault_address()],
      topics:    [[@cbdc_locked_topic, @asset_locked_topic]]
    }
    rpc(anvil_http_url(), "eth_getLogs", [params])
  end

  # Submit executeTokenInstruction() on Amoy — Token→Instruction flow.
  def execute_token_instruction(to_wallet, nonce_hash, payload, signatures) when is_list(signatures) do
    calldata = encode_call(
      "executeTokenInstruction(address,bytes32,bytes,bytes[])",
      encode_token_instruction_args(to_wallet, nonce_hash, payload, signatures)
    )
    submit_to_bridge(calldata)
  end

  # Submit executeAssetInstruction() on Amoy — Asset→Instruction flow.
  def execute_asset_instruction(to_wallet, token_contract, token_id, nonce_hash, payload, signatures)
      when is_list(signatures) do
    calldata = encode_call(
      "executeAssetInstruction(address,address,uint256,bytes32,bytes,bytes[])",
      encode_asset_instruction_args(to_wallet, token_contract, token_id, nonce_hash, payload, signatures)
    )
    submit_to_bridge(calldata)
  end

  defp submit_to_bridge(calldata) do
    relayer_key    = relayer_1_private_key()
    bridge_address = stablecoin_bridge_address()
    amoy_url       = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, bridge_address, calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("bridge tx failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Submit mintWithApprovals() on Amoy — called by HubRouter when 2-of-3 threshold reached.
  # signatures: list of 65-byte raw ECDSA signatures (r ++ s ++ v).
  def mint_with_approvals(to_wallet, amount, nonce_hash, signatures) when is_list(signatures) do
    calldata = encode_call(
      "mintWithApprovals(address,uint256,bytes32,bytes[])",
      encode_mint_with_approvals_args(to_wallet, amount, nonce_hash, signatures)
    )

    relayer_key    = relayer_1_private_key()
    bridge_address = stablecoin_bridge_address()
    amoy_url       = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, bridge_address, calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("mintWithApprovals submitted on Amoy: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("mintWithApprovals failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── POC v2 proof-based bridge: oracle + executeWithProof ─────────────────

  # Submit a source chain block hash to BlockHashOracle on Amoy.
  # Called by BlockHashReporter once per finalized Anvil block.
  def submit_block_hash(block_number, block_hash_hex) when is_integer(block_number) do
    block_hash_bytes = bytes32_hex(block_hash_hex)
    calldata = encode_call(
      "submitBlockHash(uint256,bytes32)",
      [uint(block_number), block_hash_bytes]
    )
    relayer_key  = relayer_1_private_key()
    oracle_addr  = block_hash_oracle_address()
    amoy_url     = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, oracle_addr, calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("submitBlockHash block=#{block_number} tx=#{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("submitBlockHash failed block=#{block_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Submit executeWithProof() on Amoy after MPT proof is built.
  # proof_data: %{block_number, rlp_block_header, tx_index, rlp_receipt, proof_nodes, log_index}
  # All bytes fields are raw binaries.
  def execute_with_proof(proof_data) do
    %{
      block_number:     block_number,
      rlp_block_header: rlp_header,
      tx_index:         tx_index,
      rlp_receipt:      rlp_receipt,
      proof_nodes:      proof_nodes,
      log_index:        log_index
    } = proof_data

    calldata = encode_call(
      "executeWithProof((uint256,bytes,uint256,bytes,bytes[],uint256))",
      encode_proof_data_args(block_number, rlp_header, tx_index, rlp_receipt, proof_nodes, log_index)
    )
    submit_to_bridge(calldata)
  end

  # ABI-encode ProofData struct as a tuple argument.
  # Struct fields: (uint256 blockNumber, bytes rlpHeader, uint256 txIndex, bytes rlpReceipt, bytes[] proofNodes, uint256 logIndex)
  # Static head = 6 slots × 32 = 192 bytes.
  # Dynamic fields: rlpHeader (slot 1), rlpReceipt (slot 3), proofNodes (slot 4).
  defp encode_proof_data_args(block_number, rlp_header, tx_index, rlp_receipt, proof_nodes, log_index) do
    header_enc    = encode_bytes_elem(rlp_header)
    receipt_enc   = encode_bytes_elem(rlp_receipt)
    nodes_enc     = encode_bytes_array(proof_nodes)

    static_size = 192  # 6 × 32
    header_offset  = static_size
    receipt_offset = header_offset + byte_size(header_enc)
    nodes_offset   = receipt_offset + byte_size(receipt_enc)

    IO.iodata_to_binary([
      uint(block_number),
      uint(header_offset),
      uint(tx_index),
      uint(receipt_offset),
      uint(nodes_offset),
      uint(log_index),
      header_enc,
      receipt_enc,
      nodes_enc
    ])
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

  # ── ABI encoding for mintWithApprovals(address,uint256,bytes32,bytes[]) ──
  # bytes[] is a dynamic type: requires offset pointer in head + encoded array in tail.
  # Layout (all sizes in bytes, from start of args):
  #   [0..31]    to address
  #   [32..63]   amount uint256
  #   [64..95]   nonceHash bytes32
  #   [96..127]  offset to bytes[] = 128  (4 static head slots × 32)
  #   [128..]    bytes[] encoding:
  #                length N, N offset words (relative to head-section start after length),
  #                then N encoded bytes elements (length + padded data)
  defp encode_mint_with_approvals_args(to_wallet, amount, nonce_hash, signatures) do
    static_head = IO.iodata_to_binary([
      addr(to_wallet),
      uint(amount),
      bytes32_hex(nonce_hash),
      uint(128)  # offset to bytes[] from start of args
    ])

    dynamic_tail = encode_bytes_array(signatures)
    static_head <> dynamic_tail
  end

  # executeTokenInstruction(address to, bytes32 nonceHash, bytes payload, bytes[] signatures)
  # Static head: to(32) + nonceHash(32) + payloadOffset(32) + sigsOffset(32) = 128 bytes
  # Dynamic: payload bytes, then signatures bytes[]
  defp encode_token_instruction_args(to_wallet, nonce_hash, payload, signatures) do
    payload_bin    = decode_hex_bytes(payload)
    payload_enc    = encode_bytes_elem(payload_bin)
    payload_offset = 128  # 4 static slots
    sigs_offset    = payload_offset + byte_size(payload_enc)

    IO.iodata_to_binary([
      addr(to_wallet),
      bytes32_hex(nonce_hash),
      uint(payload_offset),
      uint(sigs_offset),
      payload_enc,
      encode_bytes_array(signatures)
    ])
  end

  # executeAssetInstruction(address to, address tokenContract, uint256 tokenId,
  #                         bytes32 nonceHash, bytes payload, bytes[] signatures)
  # Static head: to(32) + tokenContract(32) + tokenId(32) + nonceHash(32) + payloadOffset(32) + sigsOffset(32) = 192 bytes
  defp encode_asset_instruction_args(to_wallet, token_contract, token_id, nonce_hash, payload, signatures) do
    payload_bin    = decode_hex_bytes(payload)
    payload_enc    = encode_bytes_elem(payload_bin)
    payload_offset = 192  # 6 static slots
    sigs_offset    = payload_offset + byte_size(payload_enc)

    IO.iodata_to_binary([
      addr(to_wallet),
      addr(token_contract),
      uint(token_id),
      bytes32_hex(nonce_hash),
      uint(payload_offset),
      uint(sigs_offset),
      payload_enc,
      encode_bytes_array(signatures)
    ])
  end

  defp decode_hex_bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_hex_bytes(hex), do: Base.decode16!(hex, case: :mixed)

  # Encode a list of binaries as Solidity bytes[] (dynamic array of dynamic elements).
  defp encode_bytes_array(list) do
    n = length(list)
    # Calculate offset for each element relative to the start of the head section
    # (right after the length word). Head section = N offset words = N * 32 bytes.
    head_size = n * 32
    {offsets, elems} =
      Enum.reduce(list, {[], [], head_size}, fn bin, {offs, elems, current_offset} ->
        enc = encode_bytes_elem(bin)
        {offs ++ [uint(current_offset)], elems ++ [enc], current_offset + byte_size(enc)}
      end)
      |> (fn {o, e, _} -> {o, e} end).()

    IO.iodata_to_binary([uint(n)] ++ offsets ++ elems)
  end

  # Encode a single bytes value: ABI uint256 length + right-padded data to 32-byte boundary.
  defp encode_bytes_elem(bin) do
    len = byte_size(bin)
    pad = rem(32 - rem(len, 32), 32)
    uint(len) <> bin <> :binary.copy(<<0>>, pad)
  end

  # ── Config accessors ─────────────────────────────────────────────────────

  defp relayer_private_key do
    Application.get_env(:bharat_core, :relayer_private_key) ||
      raise "relayer_private_key not configured"
  end

  defp relayer_1_private_key do
    Application.get_env(:bharat_core, :relayer_1_private_key) ||
      relayer_private_key()
  end

  defp lock_contract_address do
    Application.get_env(:bharat_core, :lock_contract) ||
      raise "lock_contract not configured"
  end

  defp mint_contract_address do
    Application.get_env(:bharat_core, :mint_contract) ||
      raise "mint_contract not configured"
  end

  defp cbdc_vault_address do
    Application.get_env(:bharat_core, :cbdc_vault_contract) ||
      raise "cbdc_vault_contract not configured"
  end

  defp asset_vault_address do
    Application.get_env(:bharat_core, :asset_vault_contract) ||
      raise "asset_vault_contract not configured"
  end

  defp stablecoin_bridge_address do
    Application.get_env(:bharat_core, :stablecoin_bridge_contract) ||
      raise "stablecoin_bridge_contract not configured"
  end

  defp block_hash_oracle_address do
    Application.get_env(:bharat_core, :block_hash_oracle_contract) ||
      raise "block_hash_oracle_contract not configured"
  end

  defp anvil_http_url do
    Application.get_env(:bharat_core, :anvil_http_url) ||
      raise "anvil_http_url not configured"
  end

  defp amoy_http_url do
    Application.get_env(:bharat_core, :polygon_http_url) ||
      raise "polygon_http_url not configured"
  end

  defp evm_escrow_address do
    Application.get_env(:bharat_core, :evm_escrow_contract) ||
      raise "evm_escrow_contract not configured"
  end

  # ── AssetVault functions ──────────────────────────────────────────────────

  # Build lockAsset() calldata for MetaMask — NFT EVM→Solana forward flow
  # lockAsset(address,uint256,bytes32,string,bytes32,bytes)
  def build_asset_vault_lock_tx(token_contract, token_id, transfer_id, dest_zone, dest_address_bytes, instruction_payload) do
    payload_bin    = if instruction_payload, do: decode_hex_bytes(instruction_payload), else: <<>>
    zone_enc       = encode_bytes_elem(dest_zone)
    payload_enc    = encode_bytes_elem(payload_bin)
    # Static head: tokenContract(32) + tokenId(32) + transferId(32) + destZoneOffset(32) + destAddress(32) + payloadOffset(32) = 192
    zone_offset    = 192
    payload_offset = zone_offset + byte_size(zone_enc)

    args = IO.iodata_to_binary([
      addr(token_contract),
      uint(token_id),
      bytes32(transfer_id),
      uint(zone_offset),
      dest_address_bytes,
      uint(payload_offset),
      zone_enc,
      payload_enc
    ])

    calldata = encode_call(
      "lockAsset(address,uint256,bytes32,string,bytes32,bytes)",
      args
    )

    %{
      to:   asset_vault_address(),
      data: "0x" <> Base.encode16(calldata, case: :lower),
      gas:  "0x493E0"
    }
  end

  # Call unlockAsset() on AssetVault — NFT Solana→EVM reverse flow
  def unlock_asset(to_wallet, token_contract, token_id, transfer_id) do
    calldata = encode_call(
      "unlockAsset(address,address,uint256,bytes32)",
      [addr(to_wallet), addr(token_contract), uint(token_id), bytes32(transfer_id)]
    )
    submit_to_asset_vault(calldata)
  end

  defp submit_to_asset_vault(calldata) do
    relayer_key = relayer_private_key()
    amoy_url    = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, asset_vault_address(), calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("unlockAsset submitted: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("unlockAsset failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Call refundAfterTimeout() on EVMEscrow — permissionless after 1hr lock timeout
  def refund_after_timeout(nonce_hash) do
    calldata = encode_call(
      "refundAfterTimeout(bytes32)",
      [bytes32_hex(nonce_hash)]
    )

    relayer_key = relayer_private_key()
    amoy_url    = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, evm_escrow_address(), calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("refundAfterTimeout submitted: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("refundAfterTimeout failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Call unlockFromZone() on EVMEscrow — reverse token flow (Solana→EVM)
  def unlock_from_zone(recipient, token, amount, transfer_id) do
    calldata = encode_call(
      "unlockFromZone(address,address,uint256,bytes32)",
      [addr(recipient), addr(token), uint(amount), bytes32_hex(transfer_id)]
    )

    relayer_key = relayer_private_key()
    amoy_url    = amoy_http_url()

    with {:ok, nonce}     <- eth_get_nonce(amoy_url, relayer_address(relayer_key)),
         {:ok, gas_price} <- eth_gas_price(amoy_url),
         {:ok, signed}    <- sign_tx_for_chain(relayer_key, evm_escrow_address(), calldata, nonce, gas_price, @amoy_chain_id),
         {:ok, tx_hash}   <- eth_send_raw(amoy_url, signed) do
      Logger.info("unlockFromZone submitted: #{tx_hash}")
      {:ok, tx_hash}
    else
      {:error, reason} ->
        Logger.error("unlockFromZone failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── EVMEscrow functions ───────────────────────────────────────────────────

  def get_evm_escrow_logs(from_block, to_block) do
    params = %{
      fromBlock: "0x" <> Integer.to_string(from_block, 16),
      toBlock:   "0x" <> Integer.to_string(to_block, 16),
      address:   evm_escrow_address(),
      topics:    [@tokens_locked_for_zone_topic]
    }
    Ethereumex.HttpClient.eth_get_logs(params)
  end

  # Build lockForZone() calldata — returned to frontend for MetaMask signing
  def build_evm_escrow_lock_tx(token_address, amount, _transfer_id, destination_zone, destination_address_bytes) do
    # lockForZone(address,uint256,string,bytes32,bytes)
    # Static head (5 slots = 160 bytes):
    #   token(32) + amount(32) + zoneOffset(32) + destAddr(32) + metaOffset(32)
    zone_enc    = encode_bytes_elem(destination_zone)
    meta_enc    = encode_bytes_elem(<<>>)
    zone_offset = 160
    meta_offset = zone_offset + byte_size(zone_enc)

    args = IO.iodata_to_binary([
      addr(token_address),
      uint(Decimal.to_integer(amount)),
      uint(zone_offset),
      destination_address_bytes,
      uint(meta_offset),
      zone_enc,
      meta_enc
    ])

    selector = <<0xAB, 0xCD, 0xEF, 0x12>> # placeholder — replace with cast sig output
    calldata = selector <> args

    %{
      to:   evm_escrow_address(),
      data: "0x" <> Base.encode16(calldata, case: :lower),
      gas:  "0x493E0"
    }
  end
end
