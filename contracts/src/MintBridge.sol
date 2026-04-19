// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "./utils/ERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title MintBridge
 * @notice Mints wrapped tokens (wCCC) for Amoy→Sepolia transfers.
 *         Burns wrapped tokens for Sepolia→Amoy returns via burnAndBridge().
 */
contract MintBridge is ERC20, Ownable {
    // ── State ────────────────────────────────────────────────────────────────

    mapping(bytes32 => bool) public usedNonces;
    address public relayer;
    bool public paused;

    // ── Events ───────────────────────────────────────────────────────────────

    event Minted(address indexed to, uint256 amount, bytes32 nonceHash);
    event TokensBurned(
        address indexed wallet,
        uint256 amount,
        bytes32 nonceHash,
        bytes32 transferId
    );
    event RelayerUpdated(address oldRelayer, address newRelayer);
    event Paused(address by);
    event Unpaused(address by);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NonceAlreadyUsed(bytes32 nonceHash);
    error NotRelayer(address caller);
    error ZeroAmount();
    error ZeroAddress();
    error ContractPaused();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _relayer)
        ERC20("Wrapped Carbon Credit", "wCCC")
    {
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
    }

    // ── External ─────────────────────────────────────────────────────────────

    /**
     * @notice Mint wrapped tokens after confirmed lock on Amoy (Amoy→Sepolia).
     *         Called by relayer only.
     */
    function mintOnProof(
        address to,
        bytes32 nonceHash,
        uint256 amount
    ) external onlyRelayer {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);

        usedNonces[nonceHash] = true;
        _mint(to, amount);
        emit Minted(to, amount, nonceHash);
    }

    /**
     * @notice Burn wCCC to initiate return to Amoy (Sepolia→Amoy).
     *         User calls directly — no relayer needed for this step.
     *         Relayer watches for TokensBurned event then calls LockBridge.unlock() on Amoy.
     */
    function burnAndBridge(uint256 amount, bytes32 transferId) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (usedNonces[transferId]) revert NonceAlreadyUsed(transferId);

        usedNonces[transferId] = true;
        bytes32 nonceHash = keccak256(abi.encodePacked(msg.sender, transferId));
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, nonceHash, transferId);
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
}
