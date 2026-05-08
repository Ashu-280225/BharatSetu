// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeVault.sol";

contract FeeVaultTest is Test {

    FeeVault vault;

    address regulator = address(1);
    address treasury = address(2);

    function setUp() public {
        vault = new FeeVault(regulator, treasury, 1 ether);
    }

    function testCollectFee() public {
        bytes32 transferId = keccak256("tx1");

        vm.deal(address(this), 1 ether);

        vault.collectFee{value: 1 ether}(transferId);

        assertEq(vault.fees(transferId), 1 ether);
    }

    function testCollectFeeFailsWrongAmount() public {
        bytes32 transferId = keccak256("tx1");

        vm.expectRevert("Invalid fee");

        vault.collectFee{value: 0.5 ether}(transferId);
    }

    function testDistributeToValidators() public {
        vm.deal(address(vault), 2 ether);

        address[] memory validators = new address[](2);
        validators[0] = address(3);
        validators[1] = address(4);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        vm.prank(regulator);

        vault.distributeToValidators(validators, amounts);

        assertEq(address(3).balance, 1 ether);
        assertEq(address(4).balance, 1 ether);
    }

    function testWithdrawTreasury() public {
        vm.deal(address(vault), 1 ether);

        vm.prank(regulator);

        vault.withdrawTreasury(1 ether);

        assertEq(treasury.balance, 1 ether);
    }
}