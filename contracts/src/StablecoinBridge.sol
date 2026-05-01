// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "./utils/ERC20.sol";
import {Ownable} from "./utils/Ownable.sol";
import {RLPReader} from "./lib/RLPReader.sol";
import {MerklePatricia} from "./lib/MerklePatricia.sol";

interface IBlockHashOracle {
    function isFinalized(uint256 blockNumber, bytes32 blockHash) external view returns (bool);
}

/**
 * @title StablecoinBridge
 * @notice Issues INRX stablecoin on Polygon Amoy after verifying an MPT receipt proof
 *         that a lock event occurred on the source chain (Anvil/CBDC ledger).
 *
 *         Trust model: relayers agree on block hashes (BlockHashOracle), but execution
 *         depends on a cryptographic MPT proof against the finalized receiptsRoot.
 *         No relayer can fabricate valid proofs for events that didn't occur.
 *
 *         Source chain event topic hashes:
 *           CBDCLocked (transferType 0,1): 0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8
 *           AssetLocked (transferType 2):  0xfebbc5c036aa2aa6ef382b492327c08033496d19d1286f732900cb5d618a70d4
 */
contract StablecoinBridge is ERC20, Ownable {
    using RLPReader for bytes;

    // ── Structs ───────────────────────────────────────────────────────────────

    struct ProofData {
        uint256 blockNumber;      // Source chain block containing the lock tx
        bytes   rlpBlockHeader;   // Full RLP-encoded source block header
        uint256 txIndex;          // Index of the lock tx in that block
        bytes   rlpReceipt;       // RLP-encoded receipt of the lock tx
        bytes[] proofNodes;       // MPT proof nodes from receiptsRoot to receipt leaf
        uint256 logIndex;         // Index of the lock event log within the receipt
    }

    // ── State ────────────────────────────────────────────────────────────────

    IBlockHashOracle public oracle;
    bool public paused;
    mapping(bytes32 => bool) public usedNonces;

    // Expected source chain contract addresses (set at deploy time)
    address public cbdcVaultSource;
    address public assetVaultSource;

    // Source chain topic hashes
    bytes32 constant CBDC_LOCKED_TOPIC  = 0x106e28fff448c4af52727f4a2a877a388930773c9c799031b52f7be42d5dbfe8;
    bytes32 constant ASSET_LOCKED_TOPIC = 0xfebbc5c036aa2aa6ef382b492327c08033496d19d1286f732900cb5d618a70d4;

    // ── Events ───────────────────────────────────────────────────────────────

    event Minted(address indexed to, uint256 amount, bytes32 nonceHash);
    event InstructionExecuted(address indexed to, bytes32 nonceHash, bytes payload);
    event AssetInstructionExecuted(address indexed to, address tokenContract, uint256 tokenId, bytes32 nonceHash, bytes payload);
    event TokensBurned(address indexed wallet, uint256 amount, bytes32 transferId);
    event Paused(address by);
    event Unpaused(address by);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NonceAlreadyUsed(bytes32 nonce);
    error ZeroAmount();
    error ZeroAddress();
    error ContractPaused();
    error BlockNotFinalized(uint256 blockNumber);
    error ProofInvalid();
    error UnknownSourceContract(address addr);
    error UnknownEventTopic(bytes32 topic);
    error MalformedEvent();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _oracle,
        address _cbdcVaultSource,
        address _assetVaultSource
    ) ERC20("India Rupee Stablecoin", "INRX") {
        if (_oracle == address(0)) revert ZeroAddress();
        if (_cbdcVaultSource == address(0)) revert ZeroAddress();
        if (_assetVaultSource == address(0)) revert ZeroAddress();
        oracle = IBlockHashOracle(_oracle);
        cbdcVaultSource = _cbdcVaultSource;
        assetVaultSource = _assetVaultSource;
    }

    // ── External: Proof-based execution ──────────────────────────────────────

    /**
     * @notice Execute a cross-chain action by verifying an MPT receipt proof.
     *
     *         Steps:
     *         1. Verify block hash is finalized in the oracle.
     *         2. Extract receiptsRoot from the RLP block header.
     *         3. Verify the MPT proof: receipt is included under txIndex key.
     *         4. Decode the target log from the receipt.
     *         5. Dispatch by event topic (CBDCLocked or AssetLocked).
     *         6. Mark nonce used, execute action.
     */
    function executeWithProof(ProofData calldata p) external whenNotPaused {
        // Step 1: Block finalized?
        bytes32 headerHash = keccak256(p.rlpBlockHeader);
        if (!oracle.isFinalized(p.blockNumber, headerHash)) revert BlockNotFinalized(p.blockNumber);

        // Step 2: Extract receiptsRoot from header
        bytes32 root = RLPReader.receiptsRoot(p.rlpBlockHeader);

        // Step 3: Verify MPT proof
        bytes memory trieKey = RLPReader.encodeIndex(p.txIndex);
        bool valid = MerklePatricia.verify(root, trieKey, p.rlpReceipt, p.proofNodes);
        if (!valid) revert ProofInvalid();

        // Step 4: Decode target log
        RLPReader.Log memory log = RLPReader.decodeLog(p.rlpReceipt, p.logIndex);

        // Step 5: Verify source contract and topic
        if (log.addr != cbdcVaultSource && log.addr != assetVaultSource) {
            revert UnknownSourceContract(log.addr);
        }
        if (log.topics.length == 0) revert MalformedEvent();
        bytes32 topic = log.topics[0];

        // Step 6: Dispatch
        if (topic == CBDC_LOCKED_TOPIC && log.addr == cbdcVaultSource) {
            _executeCBDCLocked(log);
        } else if (topic == ASSET_LOCKED_TOPIC && log.addr == assetVaultSource) {
            _executeAssetLocked(log);
        } else {
            revert UnknownEventTopic(topic);
        }
    }

    /**
     * @notice Burn INRX to initiate Stablecoin→CBDC reverse flow.
     *         Hub relayers observe TokensBurned on Amoy, then submit proof to CBDCVault on Anvil.
     */
    function burnAndBridge(uint256 amount, bytes32 transferId) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (usedNonces[transferId]) revert NonceAlreadyUsed(transferId);
        usedNonces[transferId] = true;
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, transferId);
    }

    // ── Internal: Event handlers ──────────────────────────────────────────────

    /**
     * @dev Handle CBDCLocked event.
     *      Event: CBDCLocked(address indexed wallet, uint256 amount, bytes32 nonceHash, bytes32 transferId, uint8 transferType, bytes instructionPayload)
     *      topics[0] = event sig, topics[1] = wallet (indexed)
     *      data = abi.encode(amount, nonceHash, transferId, transferType, instructionPayload)
     */
    function _executeCBDCLocked(RLPReader.Log memory log) internal {
        if (log.topics.length < 2) revert MalformedEvent();
        address wallet = address(uint160(uint256(log.topics[1])));
        bytes memory d = log.data;
        if (d.length < 128) revert MalformedEvent();

        uint256 amount;
        bytes32 nonceHash;
        uint8 transferType;
        assembly {
            amount     := mload(add(d, 32))
            nonceHash  := mload(add(d, 64))
            // transferId at offset 96 — skip
            transferType := mload(add(d, 128)) // uint8 right-padded in 32-byte slot
        }

        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);
        usedNonces[nonceHash] = true;

        if (transferType == 0) {
            // TOKEN_TO_TOKEN: mint INRX
            if (amount == 0) revert ZeroAmount();
            _mint(wallet, amount);
            emit Minted(wallet, amount, nonceHash);
        } else if (transferType == 1) {
            // TOKEN_TO_INSTRUCTION: emit instruction payload
            bytes memory payload = _decodePayloadFromData(d, 4); // slot 4 = offset pointer
            emit InstructionExecuted(wallet, nonceHash, payload);
        } else {
            revert MalformedEvent();
        }
    }

    /**
     * @dev Handle AssetLocked event.
     *      Event: AssetLocked(address indexed wallet, address indexed tokenContract, uint256 tokenId, bytes32 nonceHash, bytes32 transferId, bytes instructionPayload)
     *      topics[0] = event sig, topics[1] = wallet, topics[2] = tokenContract
     *      data = abi.encode(tokenId, nonceHash, transferId, instructionPayload)
     */
    function _executeAssetLocked(RLPReader.Log memory log) internal {
        if (log.topics.length < 3) revert MalformedEvent();
        address wallet        = address(uint160(uint256(log.topics[1])));
        address tokenContract = address(uint160(uint256(log.topics[2])));
        bytes memory d = log.data;
        if (d.length < 96) revert MalformedEvent();

        uint256 tokenId;
        bytes32 nonceHash;
        assembly {
            tokenId   := mload(add(d, 32))
            nonceHash := mload(add(d, 64))
            // transferId at 96
        }

        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);
        usedNonces[nonceHash] = true;

        bytes memory payload = _decodePayloadFromData(d, 3); // slot 3 = offset pointer for instructionPayload
        emit AssetInstructionExecuted(wallet, tokenContract, tokenId, nonceHash, payload);
    }

    /**
     * @dev Decode ABI-encoded dynamic bytes at slot `slotIndex` (0-based) in event data.
     *      ABI encoding: each dynamic type stores an offset pointer in the static head.
     */
    function _decodePayloadFromData(bytes memory d, uint256 slotIndex)
        internal pure returns (bytes memory payload)
    {
        // Read offset pointer at slotIndex * 32
        uint256 offsetPtr;
        assembly { offsetPtr := mload(add(d, add(32, mul(slotIndex, 32)))) }
        // offsetPtr is relative to start of data (d without length prefix)
        uint256 lenOffset = 32 + offsetPtr;
        if (d.length < lenOffset + 32) return new bytes(0);
        uint256 payloadLen;
        assembly { payloadLen := mload(add(d, add(lenOffset, 32))) }
        if (d.length < lenOffset + 32 + payloadLen) return new bytes(0);
        payload = new bytes(payloadLen);
        for (uint256 i = 0; i < payloadLen; i++) {
            payload[i] = d[lenOffset + 32 + i];
        }
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IBlockHashOracle(_oracle);
    }

    function setSourceContracts(address _cbdcVault, address _assetVault) external onlyOwner {
        if (_cbdcVault == address(0) || _assetVault == address(0)) revert ZeroAddress();
        cbdcVaultSource = _cbdcVault;
        assetVaultSource = _assetVault;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
