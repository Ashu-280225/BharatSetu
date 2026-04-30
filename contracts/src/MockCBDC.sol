// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "./utils/ERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title MockCBDC
 * @notice Simulated Central Bank Digital Currency (Digital Rupee, INRDC) for POC v2.
 *         Owner can mint to test wallets. Represents the permissioned CBDC ledger token.
 */
contract MockCBDC is ERC20, Ownable {
    error ZeroAddress();
    error ZeroAmount();

    constructor() ERC20("Digital Rupee", "INRDC") {}

    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }
}
