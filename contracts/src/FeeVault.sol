// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PURPOSE:
- Collect fixed fee for each transfer
- Store fee per transferId
- Distribute fees to validators
- Allow treasury withdrawal
*/

contract FeeVault {

    // 🔹 Who controls the system
    address public regulator;

    // 🔹 Treasury address (where leftover funds go)
    address public treasury;

    // 🔹 Fixed fee required per transfer
    uint256 public fixedFeeWei;

    // 🔹 Stores fee per transferId
    mapping(bytes32 => uint256) public fees;

    // 🔹 Constructor (runs once)
    constructor(address _regulator, address _treasury, uint256 _fee) {
        regulator = _regulator;
        treasury = _treasury;
        fixedFeeWei = _fee;
    }

    // 🔒 Only regulator can call
    modifier onlyRegulator() {
        require(msg.sender == regulator, "Not regulator");
        _;
    }

    /*
    FUNCTION: collectFee
    PURPOSE:
    - User pays fee when making transfer
    - Must match exact fixed fee
    */
    function collectFee(bytes32 transferId) external payable {
        require(msg.value == fixedFeeWei, "Invalid fee");

        fees[transferId] = msg.value;
    }

    /*
    FUNCTION: distributeToValidators
    PURPOSE:
    - Distribute collected fees to validators
    - Only regulator can call
    */
    function distributeToValidators(
        address[] calldata validators,
        uint256[] calldata amounts
    ) external onlyRegulator {

        require(validators.length == amounts.length, "Length mismatch");

        uint256 total;

        // Calculate total payout
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }

        // Ensure enough balance
        require(total <= address(this).balance, "Insufficient balance");

        // Send ETH
        for (uint256 i = 0; i < validators.length; i++) {
            payable(validators[i]).transfer(amounts[i]);
        }
    }

    /*
    FUNCTION: withdrawTreasury
    PURPOSE:
    - Send remaining funds to treasury
    */
    function withdrawTreasury(uint256 amount) external onlyRegulator {
        require(amount <= address(this).balance, "Insufficient");

        payable(treasury).transfer(amount);
    }
}