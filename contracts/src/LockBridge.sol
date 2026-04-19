// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title LockBridge
 * @notice Locks ERC-20 tokens for Amoy→Sepolia transfers.
 *         Releases locked tokens for Sepolia→Amoy returns via unlock().
 */
contract LockBridge is Ownable {
    // ── State ────────────────────────────────────────────────────────────────

    mapping(bytes32 => bool) public usedTransferIds;
    bool public paused;
    address public relayer;

    // ── Events ───────────────────────────────────────────────────────────────

    event TokensLocked(
        address indexed wallet,
        address indexed token,
        uint256 amount,
        bytes32 nonceHash,
        bytes32 transferId
    );

    event TokensUnlocked(
        address indexed wallet,
        address indexed token,
        uint256 amount,
        bytes32 nonceHash,
        bytes32 transferId
    );

    event Paused(address by);
    event Unpaused(address by);
    event Withdrawn(address token, address to, uint256 amount);
    event RelayerUpdated(address oldRelayer, address newRelayer);

    // ── Errors ───────────────────────────────────────────────────────────────

    error TransferIdUsed(bytes32 transferId);
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();
    error NotRelayer(address caller);
    error TransferFailed();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer(msg.sender);
        _;
    }

    // ── External ─────────────────────────────────────────────────────────────

    function lockTokens(
        address token,
        uint256 amount,
        bytes32 transferId
    ) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();
        if (usedTransferIds[transferId]) revert TransferIdUsed(transferId);

        usedTransferIds[transferId] = true;
        bytes32 nonceHash = keccak256(abi.encodePacked(msg.sender, transferId));
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit TokensLocked(msg.sender, token, amount, nonceHash, transferId);
    }

    /**
     * @notice Release locked tokens back to user (Sepolia→Amoy return flow).
     *         Called by relayer after detecting TokensBurned on Sepolia.
     */
    function unlock(
        address to,
        address token,
        uint256 amount,
        bytes32 transferId
    ) external onlyRelayer whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (usedTransferIds[transferId]) revert TransferIdUsed(transferId);

        usedTransferIds[transferId] = true;
        bytes32 nonceHash = keccak256(abi.encodePacked(to, transferId));
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        emit TokensUnlocked(to, token, amount, nonceHash, transferId);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setRelayer(address newRelayer) external onlyOwner {
        if (newRelayer == address(0)) revert ZeroAddress();
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        emit Withdrawn(token, to, amount);
    }
}
