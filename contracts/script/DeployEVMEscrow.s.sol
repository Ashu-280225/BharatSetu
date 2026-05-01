// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/EVMEscrow.sol";

contract DeployEVMEscrow is Script {
    function run() external {
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        vm.startBroadcast();
        EVMEscrow escrow = new EVMEscrow(relayer);
        console.log("EVMEscrow deployed:", address(escrow));
        vm.stopBroadcast();
    }
}
