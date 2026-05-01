// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";
import "./utils/Ownable.sol";

contract EVMEscrow is Ownable {
    uint256 public constant TIMEOUT = 1 hours;
    uint256 public constant MIN_AMOUNT = 1e12; // 1 SPL unit in 18-decimal terms

    address public relayer;
    bool    public paused;

    struct Lock {
        address token;
        uint256 amount;
        address sender;
        uint256 lockedAt;
        bool    released;
    }

    mapping(bytes32 => Lock) public locks;
    mapping(address => uint256) public nonces;

    event TokensLockedForZone(
        bytes32 indexed transferId,
        address indexed token,
        uint256 amount,
        address sender,
        string  destinationZone,
        bytes32 destinationAddress,
        bytes   metadata
    );
    event TokensUnlocked(bytes32 indexed transferId, address recipient, uint256 amount);
    event RefundIssued(bytes32 indexed transferId, address recipient, uint256 amount);

    modifier onlyRelayer() { require(msg.sender == relayer, "not relayer"); _; }
    modifier notPaused()   { require(!paused, "paused"); _; }

    constructor(address _relayer) { relayer = _relayer; }

    function lockForZone(
        address token,
        uint256 amount,
        string  calldata destinationZone,
        bytes32 destinationAddress,
        bytes   calldata metadata
    ) external notPaused {
        require(amount >= MIN_AMOUNT, "below minimum");

        // Round down to SPL precision — dust stays in user wallet
        uint256 transferable = (amount / MIN_AMOUNT) * MIN_AMOUNT;

        // transferId: collision-proof via sender + nonce + chainId
        bytes32 transferId = keccak256(
            abi.encode(msg.sender, nonces[msg.sender]++, block.chainid)
        );

        IERC20(token).transferFrom(msg.sender, address(this), transferable);

        locks[transferId] = Lock({
            token:    token,
            amount:   transferable,
            sender:   msg.sender,
            lockedAt: block.timestamp,
            released: false
        });

        emit TokensLockedForZone(
            transferId, token, transferable, msg.sender,
            destinationZone, destinationAddress, metadata
        );
    }

    // Called by relayer after Solana release confirmed
    function unlockFromZone(
        address token,
        address recipient,
        uint256 amount,
        bytes32 transferId
    ) external onlyRelayer {
        Lock storage lock = locks[transferId];
        require(!lock.released, "already released");
        require(lock.token == token, "token mismatch");
        require(lock.amount == amount, "amount mismatch");

        lock.released = true;
        IERC20(token).transfer(recipient, amount);
        emit TokensUnlocked(transferId, recipient, amount);
    }

    // Permissionless refund — anyone can call after timeout
    function refundAfterTimeout(bytes32 transferId) external {
        Lock storage lock = locks[transferId];
        require(!lock.released, "already released");
        require(block.timestamp >= lock.lockedAt + TIMEOUT, "not timed out");

        lock.released = true;
        IERC20(lock.token).transfer(lock.sender, lock.amount);
        emit RefundIssued(transferId, lock.sender, lock.amount);
    }

    function setRelayer(address _relayer) external onlyOwner { relayer = _relayer; }
    function setPaused(bool _paused) external onlyOwner { paused = _paused; }
}
