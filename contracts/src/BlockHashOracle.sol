// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "./utils/Ownable.sol";

/**
 * @title BlockHashOracle
 * @notice Threshold block hash registry for cross-chain proof verification.
 *         Relayers submit source chain block hashes. Once `threshold` unique
 *         relayers agree on the same hash for a block, it is finalized.
 *         Finalized hashes are used by StablecoinBridge to verify MPT proofs.
 *
 *         Security: compromising block hash submission still cannot forge valid
 *         MPT proofs — a relayer would need to produce receipts that hash into
 *         a fabricated receiptsRoot, which is computationally infeasible.
 */
contract BlockHashOracle is Ownable {
    // ── State ────────────────────────────────────────────────────────────────

    address[] public relayers;
    mapping(address => bool) public isRelayer;
    uint256 public threshold;

    // blockNumber => blockHash => count of relayer votes
    mapping(uint256 => mapping(bytes32 => uint256)) public votes;
    // blockNumber => relayer => submitted hash (0 = not submitted)
    mapping(uint256 => mapping(address => bytes32)) public relayerVote;
    // blockNumber => finalized hash (bytes32(0) = not finalized)
    mapping(uint256 => bytes32) public finalizedHash;

    // ── Events ───────────────────────────────────────────────────────────────

    event HashSubmitted(address indexed relayer, uint256 indexed blockNumber, bytes32 blockHash);
    event HashFinalized(uint256 indexed blockNumber, bytes32 blockHash);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotRelayer(address caller);
    error AlreadyVoted(uint256 blockNumber);
    error ZeroAddress();
    error InvalidThreshold();
    error RelayerAlreadyAdded(address relayer);
    error RelayerNotFound(address relayer);

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address[] memory _relayers, uint256 _threshold) {
        if (_threshold == 0 || _threshold > _relayers.length) revert InvalidThreshold();
        for (uint256 i = 0; i < _relayers.length; i++) {
            if (_relayers[i] == address(0)) revert ZeroAddress();
            relayers.push(_relayers[i]);
            isRelayer[_relayers[i]] = true;
        }
        threshold = _threshold;
    }

    // ── External ─────────────────────────────────────────────────────────────

    /**
     * @notice Submit a block hash for a source chain block number.
     *         Each relayer can vote once per block number.
     *         Once threshold unique relayers submit the same hash, it is finalized.
     */
    function submitBlockHash(uint256 blockNumber, bytes32 blockHash) external {
        if (!isRelayer[msg.sender]) revert NotRelayer(msg.sender);
        if (relayerVote[blockNumber][msg.sender] != bytes32(0)) revert AlreadyVoted(blockNumber);

        relayerVote[blockNumber][msg.sender] = blockHash;
        votes[blockNumber][blockHash]++;
        emit HashSubmitted(msg.sender, blockNumber, blockHash);

        if (votes[blockNumber][blockHash] >= threshold && finalizedHash[blockNumber] == bytes32(0)) {
            finalizedHash[blockNumber] = blockHash;
            emit HashFinalized(blockNumber, blockHash);
        }
    }

    /**
     * @notice Returns true if a block hash is finalized at the given block number.
     */
    function isFinalized(uint256 blockNumber, bytes32 blockHash) external view returns (bool) {
        return finalizedHash[blockNumber] == blockHash && blockHash != bytes32(0);
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function addRelayer(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        if (isRelayer[r]) revert RelayerAlreadyAdded(r);
        relayers.push(r);
        isRelayer[r] = true;
        emit RelayerAdded(r);
    }

    function removeRelayer(address r) external onlyOwner {
        if (!isRelayer[r]) revert RelayerNotFound(r);
        isRelayer[r] = false;
        for (uint256 i = 0; i < relayers.length; i++) {
            if (relayers[i] == r) {
                relayers[i] = relayers[relayers.length - 1];
                relayers.pop();
                break;
            }
        }
        emit RelayerRemoved(r);
    }

    function setThreshold(uint256 t) external onlyOwner {
        if (t == 0 || t > relayers.length) revert InvalidThreshold();
        emit ThresholdUpdated(threshold, t);
        threshold = t;
    }

    function relayerCount() external view returns (uint256) {
        return relayers.length;
    }
}
