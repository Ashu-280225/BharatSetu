// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "./utils/ERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title StablecoinBridge
 * @notice Issues INRX stablecoin on Polygon Amoy when 2-of-3 hub validators
 *         confirm a CBDC lock event on the permissioned ledger.
 *         On-chain ECDSA multi-sig enforcement: mintWithApprovals() verifies
 *         threshold unique validator signatures before minting.
 */
contract StablecoinBridge is ERC20, Ownable {
    // ── State ────────────────────────────────────────────────────────────────

    address[] public validators;
    mapping(address => bool) public isValidator;
    uint256 public threshold;
    bool public paused;
    mapping(bytes32 => bool) public usedNonces;

    // ── Events ───────────────────────────────────────────────────────────────

    event Minted(address indexed to, uint256 amount, bytes32 nonceHash);
    event TokensBurned(address indexed wallet, uint256 amount, bytes32 transferId);
    event InstructionExecuted(address indexed to, bytes32 nonceHash, bytes payload);
    event AssetInstructionExecuted(address indexed to, address tokenContract, uint256 tokenId, bytes32 nonceHash, bytes payload);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event Paused(address by);
    event Unpaused(address by);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NonceAlreadyUsed(bytes32 nonce);
    error ZeroAmount();
    error ZeroAddress();
    error ContractPaused();
    error BelowThreshold(uint256 got, uint256 required);
    error InvalidValidator(address signer);
    error DuplicateSigner(address signer);
    error BadSignatureLength();
    error InvalidThreshold();
    error ValidatorAlreadyAdded(address validator);
    error ValidatorNotFound(address validator);

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(address[] memory _validators, uint256 _threshold)
        ERC20("India Rupee Stablecoin", "INRX")
    {
        if (_threshold == 0 || _threshold > _validators.length) revert InvalidThreshold();
        for (uint256 i = 0; i < _validators.length; i++) {
            if (_validators[i] == address(0)) revert ZeroAddress();
            validators.push(_validators[i]);
            isValidator[_validators[i]] = true;
        }
        threshold = _threshold;
    }

    // ── External ─────────────────────────────────────────────────────────────

    /**
     * @notice Mint INRX after hub validators confirm a CBDC lock on the permissioned ledger.
     *         Verifies that at least `threshold` registered validators signed the approval.
     *         Message signed by each validator: keccak256(to ++ amount ++ nonceHash)
     */
    function mintWithApprovals(
        address to,
        uint256 amount,
        bytes32 nonceHash,
        bytes[] calldata signatures
    ) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);
        if (signatures.length < threshold) revert BelowThreshold(signatures.length, threshold);

        bytes32 messageHash = keccak256(abi.encodePacked(to, amount, nonceHash));
        _verifySignatures(messageHash, signatures);

        usedNonces[nonceHash] = true;
        _mint(to, amount);
        emit Minted(to, amount, nonceHash);
    }

    /**
     * @notice Execute an instruction on this chain after validators confirm a Token→Instruction lock.
     *         Validators sign: keccak256(to ++ keccak256(payload) ++ nonceHash)
     *         Emits InstructionExecuted — callers can decode payload off-chain to determine action.
     */
    function executeTokenInstruction(
        address to,
        bytes32 nonceHash,
        bytes calldata payload,
        bytes[] calldata signatures
    ) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (payload.length == 0) revert ZeroAmount();
        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);
        if (signatures.length < threshold) revert BelowThreshold(signatures.length, threshold);

        bytes32 messageHash = keccak256(abi.encodePacked(to, keccak256(payload), nonceHash));
        _verifySignatures(messageHash, signatures);

        usedNonces[nonceHash] = true;
        emit InstructionExecuted(to, nonceHash, payload);
    }

    /**
     * @notice Execute an instruction after validators confirm an Asset→Instruction lock.
     *         Validators sign: keccak256(to ++ tokenContract ++ tokenId ++ keccak256(payload) ++ nonceHash)
     */
    function executeAssetInstruction(
        address to,
        address tokenContract,
        uint256 tokenId,
        bytes32 nonceHash,
        bytes calldata payload,
        bytes[] calldata signatures
    ) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (tokenContract == address(0)) revert ZeroAddress();
        if (payload.length == 0) revert ZeroAmount();
        if (usedNonces[nonceHash]) revert NonceAlreadyUsed(nonceHash);
        if (signatures.length < threshold) revert BelowThreshold(signatures.length, threshold);

        bytes32 messageHash = keccak256(abi.encodePacked(to, tokenContract, tokenId, keccak256(payload), nonceHash));
        _verifySignatures(messageHash, signatures);

        usedNonces[nonceHash] = true;
        emit AssetInstructionExecuted(to, tokenContract, tokenId, nonceHash, payload);
    }

    /**
     * @notice Burn INRX to initiate Stablecoin→CBDC reverse flow.
     *         Hub validators observe TokensBurned, then admin calls CBDCVault.unlockCBDC().
     */
    function burnAndBridge(uint256 amount, bytes32 transferId) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (usedNonces[transferId]) revert NonceAlreadyUsed(transferId);

        usedNonces[transferId] = true;
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, transferId);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function addValidator(address v) external onlyOwner {
        if (v == address(0)) revert ZeroAddress();
        if (isValidator[v]) revert ValidatorAlreadyAdded(v);
        validators.push(v);
        isValidator[v] = true;
        emit ValidatorAdded(v);
    }

    function removeValidator(address v) external onlyOwner {
        if (!isValidator[v]) revert ValidatorNotFound(v);
        isValidator[v] = false;
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == v) {
                validators[i] = validators[validators.length - 1];
                validators.pop();
                break;
            }
        }
        emit ValidatorRemoved(v);
    }

    function setThreshold(uint256 t) external onlyOwner {
        if (t == 0 || t > validators.length) revert InvalidThreshold();
        emit ThresholdUpdated(threshold, t);
        threshold = t;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function validatorCount() external view returns (uint256) {
        return validators.length;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _verifySignatures(bytes32 messageHash, bytes[] calldata signatures) internal view {
        address[] memory seen = new address[](signatures.length);
        uint256 validCount = 0;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(messageHash, signatures[i]);
            if (!isValidator[signer]) revert InvalidValidator(signer);
            for (uint256 j = 0; j < validCount; j++) {
                if (seen[j] == signer) revert DuplicateSigner(signer);
            }
            seen[validCount] = signer;
            validCount++;
        }
        if (validCount < threshold) revert BelowThreshold(validCount, threshold);
    }

    /**
     * @notice Recover signer from a raw 65-byte ECDSA signature over an Ethereum signed message.
     *         Expects sig = abi.encodePacked(r, s, v) — same as eth_sign output.
     */
    function _recoverSigner(bytes32 messageHash, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) revert BadSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (v < 27) v += 27;
        bytes32 ethHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        return ecrecover(ethHash, v, r, s);
    }
}
