// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "./utils/ERC721.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title AssetVault
 * @notice Escrow for tokenized assets (ERC721) on the permissioned CBDC ledger.
 *         Locking an asset triggers an instruction on the destination chain.
 *         Supports Asset→Instruction interoperability use case.
 */
contract AssetVault is Ownable {
    address public admin;
    bool public paused;
    mapping(bytes32 => bool) public processedTransfers;

    event AssetLocked(
        address indexed wallet,
        address indexed tokenContract,
        uint256 tokenId,
        bytes32 nonceHash,
        bytes32 transferId,
        bytes instructionPayload
    );

    event AssetUnlocked(
        address indexed wallet,
        address indexed tokenContract,
        uint256 tokenId,
        bytes32 transferId
    );

    event Paused(address by);
    event Unpaused(address by);
    event AdminUpdated(address oldAdmin, address newAdmin);

    error TransferIdUsed(bytes32 transferId);
    error ContractPaused();
    error ZeroAddress();
    error NotAdmin(address caller);
    error EmptyPayload();

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    /**
     * @notice Lock a tokenized asset to trigger an instruction on the destination chain.
     *         instructionPayload encodes the instruction: ABI-packed (target, calldata).
     *         nonceHash = keccak256(msg.sender ++ tokenContract ++ tokenId ++ transferId)
     */
    function lockAsset(
        address tokenContract,
        uint256 tokenId,
        bytes32 transferId,
        bytes calldata instructionPayload
    ) external whenNotPaused {
        if (tokenContract == address(0)) revert ZeroAddress();
        if (instructionPayload.length == 0) revert EmptyPayload();
        if (processedTransfers[transferId]) revert TransferIdUsed(transferId);

        processedTransfers[transferId] = true;
        uint8 transferType = 2; // asset_to_instruction
        bytes32 nonceHash = keccak256(abi.encodePacked(
            block.chainid,
            address(this),
            transferType,
            msg.sender,
            transferId
        ));

        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);
        emit AssetLocked(msg.sender, tokenContract, tokenId, nonceHash, transferId, instructionPayload);
    }

    /**
     * @notice Return locked asset to original owner (reverse flow or failure).
     *         Called by hub admin after instruction execution confirmation.
     */
    function unlockAsset(
        address to,
        address tokenContract,
        uint256 tokenId,
        bytes32 transferId
    ) external onlyAdmin whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (processedTransfers[transferId]) revert TransferIdUsed(transferId);

        processedTransfers[transferId] = true;
        ERC721(tokenContract).transferFrom(address(this), to, tokenId);
        emit AssetUnlocked(to, tokenContract, tokenId, transferId);
    }

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
