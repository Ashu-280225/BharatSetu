// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LockBridge} from "../src/LockBridge.sol";
import {MintBridge} from "../src/MintBridge.sol";

// Fixed salt — guarantees same address every deploy as long as bytecode unchanged.
// Change salt only when intentionally rotating to a new address.
bytes32 constant SALT = keccak256("bharatsetu.v1");

/// Deploy LockBridge on Polygon Amoy:
///   forge script script/Deploy.s.sol:DeployLock --rpc-url amoy --broadcast
contract DeployLock is Script {
    function run() external {
        vm.startBroadcast();
        LockBridge lock = new LockBridge{salt: SALT}();
        vm.stopBroadcast();
        console.log("LockBridge (Amoy):", address(lock));
    }
}

/// Deploy MintBridge on Ethereum Sepolia:
///   forge script script/Deploy.s.sol:DeployMint --rpc-url sepolia --broadcast
contract DeployMint is Script {
    function run() external {
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        vm.startBroadcast();
        MintBridge mint = new MintBridge{salt: SALT}(relayer);
        vm.stopBroadcast();
        console.log("MintBridge (Sepolia):", address(mint));
        console.log("Relayer:             ", relayer);
    }
}
