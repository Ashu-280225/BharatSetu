// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title CBDCVault
 * @notice Simulates a Central Bank's institutional lockbox on the permissioned CBDC ledger.
 *         Users lock INRDC here to initiate a CBDC→Stablecoin conversion.
 *         The hub's admin account unlocks INRDC for the reverse stablecoin→CBDC flow.
 */
contract CBDCVault is Ownable {
    // ── State ────────────────────────────────────────────────────────────────

    address public cbdcToken;
    address public admin;
    bool public paused;
    mapping(bytes32 => bool) public processedTransfers;

    // ── Events ───────────────────────────────────────────────────────────────

    // transferType: 0 = TOKEN_TO_TOKEN, 1 = TOKEN_TO_INSTRUCTION
    event CBDCLocked(
        address indexed wallet,
        uint256 amount,
        bytes32 nonceHash,
        bytes32 transferId,
        uint8 transferType,
        bytes instructionPayload
    );

    event CBDCUnlocked(
        address indexed wallet,
        uint256 amount,
        bytes32 transferId
    );

    event Paused(address by);
    event Unpaused(address by);
    event AdminUpdated(address oldAdmin, address newAdmin);

    // ── Errors ───────────────────────────────────────────────────────────────

    error TransferIdUsed(bytes32 transferId);
    error ContractPaused();
    error ZeroAmount();
    error ZeroAddress();
    error NotAdmin(address caller);
    error TransferFailed();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address _cbdcToken, address _admin) {
        if (_cbdcToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        cbdcToken = _cbdcToken;
        admin = _admin;
    }

    // ── External ─────────────────────────────────────────────────────────────

    /**
     * @notice Lock INRDC for TOKEN_TO_TOKEN conversion (CBDC→Stablecoin).
     */
    function lockCBDC(uint256 amount, bytes32 transferId) external whenNotPaused {
        _lockCBDC(amount, transferId, 0, "");
    }

    /**
     * @notice Lock INRDC and attach an instruction payload for TOKEN_TO_INSTRUCTION flow.
     *         instructionPayload encodes the instruction to execute on the destination chain.
     */
    function lockCBDCWithInstruction(
        uint256 amount,
        bytes32 transferId,
        bytes calldata instructionPayload
    ) external whenNotPaused {
        if (instructionPayload.length == 0) revert ZeroAmount(); // reuse error for empty payload
        _lockCBDC(amount, transferId, 1, instructionPayload);
    }

    function _lockCBDC(
        uint256 amount,
        bytes32 transferId,
        uint8 transferType,
        bytes memory instructionPayload
    ) internal {
        if (amount == 0) revert ZeroAmount();
        if (processedTransfers[transferId]) revert TransferIdUsed(transferId);

        processedTransfers[transferId] = true;
        bytes32 nonceHash = keccak256(abi.encodePacked(
            block.chainid,
            address(this),
            transferType,
            msg.sender,
            transferId
        ));

        if (!IERC20(cbdcToken).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit CBDCLocked(msg.sender, amount, nonceHash, transferId, transferType, instructionPayload);
    }

    /**
     * @notice Unlock INRDC back to user (Stablecoin→CBDC reverse flow).
     *         Called by hub admin after 2-of-3 relayer approval of burn event on Amoy.
     */
    function unlockCBDC(address to, uint256 amount, bytes32 transferId) external onlyAdmin whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (processedTransfers[transferId]) revert TransferIdUsed(transferId);

        processedTransfers[transferId] = true;
        if (!IERC20(cbdcToken).transfer(to, amount)) revert TransferFailed();
        emit CBDCUnlocked(to, amount, transferId);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
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
