// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ValidatorSet.sol";

    contract ValidatorSetTest is Test {

            ValidatorSet public vs;

            address public regulator = address(0x1234);
            address public stranger = address(0xBAD);

            address public val1 = address(0x1);
            address public val2 = address(0x2);
            address public val3 = address(0x3);

            bytes public bls1 = bytes("bls-key-1");
            bytes public bls2 = bytes("bls-key-2");
            bytes public bls3 = bytes("bls-key-3");

            bytes32 public msghash = keccak256("Test-message");

            function setUp() public {
                vs = new ValidatorSet(regulator);
            }

            function test_addValidator_succeeds_for_regulator() public {
                vm.prank(regulator);
                vs.addValidator(val1, bls1);
                
                ( , , bool active , ) = vs.validators(val1);
                assertTrue(active);
            }

            function test_addValidator_reverts_for_others() public {
                vm.prank(stranger);
                vm.expectRevert(bytes("ValidatorSet: not regulator"));
                vs.addValidator(val1, bls1);
            }

            function test_removeValidator_sets_active_false() public {
                vm.startPrank(regulator);
                vs.addValidator(val1, bls1);
                vs.removeValidator(val1);
                vm.stopPrank();
                
                ( , , bool active , ) = vs.validators(val1);
                assertFalse(active);
            }

            function test_isQuorum_returns_true_for_3_keys() public {
                vm.startPrank(regulator);
                vs.addValidator(val1, bls1);
                vs.addValidator(val2, bls2);
                vs.addValidator(val3, bls3);
                vm.stopPrank();

                bytes[] memory keys = new bytes[](3);
                keys[0] = bls1;
                keys[1] = bls2;
                keys[2] = bls3;

                assertTrue(vs.isQuorum(keys, msghash));
            }

            function test_isQuorum_returns_false_for_2_keys() public {
                vm.startPrank(regulator);
                vs.addValidator(val1, bls1);
                vs.addValidator(val2, bls2);
                vs.addValidator(val3, bls3);
                vm.stopPrank();

                bytes[] memory keys = new bytes[](2);
                keys[0] = bls1;
                keys[1] = bls2;

                assertFalse(vs.isQuorum(keys, msghash));
            }



    }
        