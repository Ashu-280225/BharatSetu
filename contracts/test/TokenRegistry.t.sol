// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TokenRegistry.sol";

contract TokenRegistryTest is Test {

    TokenRegistry registry;

    address regulator = address(1);
    address token = address(100);

    function setUp() public {
        registry = new TokenRegistry(regulator);
    }

    function testRegisterToken() public {
        vm.prank(regulator);

        registry.registerToken(token, 18);

        (address t, uint8 d, bool active) = registry.tokens(token);

        assertEq(t, token);
        assertEq(d, 18);
        assertEq(active, true);
    }

    function testDeactivateToken() public {
        vm.prank(regulator);
        registry.registerToken(token, 18);

        vm.prank(regulator);
        registry.deactivateToken(token);

        bool supported = registry.isSupported(token);

        assertEq(supported, false);
    }
}