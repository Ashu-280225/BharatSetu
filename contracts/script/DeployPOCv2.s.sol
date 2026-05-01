// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockCBDC} from "../src/MockCBDC.sol";
import {CBDCVault} from "../src/CBDCVault.sol";
import {StablecoinBridge} from "../src/StablecoinBridge.sol";
import {BlockHashOracle} from "../src/BlockHashOracle.sol";
import {MockAsset} from "../src/MockAsset.sol";
import {AssetVault} from "../src/AssetVault.sol";

bytes32 constant SALT = keccak256("bharatsetu.v2");

/// Deploy MockCBDC + CBDCVault on Anvil local (permissioned CBDC ledger simulation):
///   forge script script/DeployPOCv2.s.sol:DeployCBDC --rpc-url http://localhost:8545 --broadcast
///
/// After deploy, set MOCK_CBDC_TOKEN and CBDC_VAULT_CONTRACT in .env.
/// The deployer is both owner and initial admin — run setAdmin() to point at relayer if needed.
contract DeployCBDC is Script {
    function run() external {
        address admin = vm.envAddress("RELAYER_1_ADDRESS");
        vm.startBroadcast();

        MockCBDC cbdc = new MockCBDC{salt: SALT}();
        CBDCVault vault = new CBDCVault{salt: SALT}(address(cbdc), admin);

        vm.stopBroadcast();

        console.log("MockCBDC  (Anvil):", address(cbdc));
        console.log("CBDCVault (Anvil):", address(vault));
        console.log("Admin:            ", admin);
        console.log("");
        console.log("Add to .env:");
        console.log("  MOCK_CBDC_TOKEN=%s", address(cbdc));
        console.log("  CBDC_VAULT_CONTRACT=%s", address(vault));
    }
}

/// Deploy BlockHashOracle on Polygon Amoy (receives source block hashes from relayers):
///   forge script script/DeployPOCv2.s.sol:DeployOracle --rpc-url amoy --broadcast
///
/// After deploy, set BLOCK_HASH_ORACLE_CONTRACT in .env.
contract DeployOracle is Script {
    function run() external {
        address r1 = vm.envAddress("RELAYER_1_ADDRESS");
        address r2 = vm.envAddress("RELAYER_2_ADDRESS");
        address r3 = vm.envAddress("RELAYER_3_ADDRESS");

        address[] memory relayers = new address[](3);
        relayers[0] = r1;
        relayers[1] = r2;
        relayers[2] = r3;

        vm.startBroadcast();
        BlockHashOracle oracle = new BlockHashOracle{salt: SALT}(relayers, 2);
        vm.stopBroadcast();

        console.log("BlockHashOracle (Amoy):", address(oracle));
        console.log("Relayers: R1=%s R2=%s R3=%s", r1, r2, r3);
        console.log("Threshold: 2-of-3");
        console.log("");
        console.log("Add to .env:");
        console.log("  BLOCK_HASH_ORACLE_CONTRACT=%s", address(oracle));
    }
}

/// Deploy StablecoinBridge on Polygon Amoy (public stablecoin chain).
/// Requires BLOCK_HASH_ORACLE_CONTRACT, CBDC_VAULT_CONTRACT, ASSET_VAULT_CONTRACT in .env.
///   forge script script/DeployPOCv2.s.sol:DeployStablecoin --rpc-url amoy --broadcast
///
/// After deploy, set STABLECOIN_BRIDGE_CONTRACT in .env.
contract DeployStablecoin is Script {
    function run() external {
        address oracleAddr    = vm.envAddress("BLOCK_HASH_ORACLE_CONTRACT");
        address cbdcVault     = vm.envAddress("CBDC_VAULT_CONTRACT");
        address assetVault    = vm.envAddress("ASSET_VAULT_CONTRACT");

        vm.startBroadcast();
        StablecoinBridge bridge = new StablecoinBridge{salt: SALT}(oracleAddr, cbdcVault, assetVault);
        vm.stopBroadcast();

        console.log("StablecoinBridge (Amoy):", address(bridge));
        console.log("Oracle:     ", oracleAddr);
        console.log("CBDCVault:  ", cbdcVault);
        console.log("AssetVault: ", assetVault);
        console.log("");
        console.log("Add to .env:");
        console.log("  STABLECOIN_BRIDGE_CONTRACT=%s", address(bridge));
    }
}

/// Deploy MockAsset + AssetVault on Anvil (Asset→Instruction use case):
///   forge script script/DeployPOCv2.s.sol:DeployAssets --rpc-url http://localhost:8545 --broadcast
contract DeployAssets is Script {
    function run() external {
        address admin = vm.envAddress("RELAYER_1_ADDRESS");
        vm.startBroadcast();

        MockAsset asset = new MockAsset{salt: SALT}();
        AssetVault vault = new AssetVault{salt: SALT}(admin);

        vm.stopBroadcast();

        console.log("MockAsset  (Anvil):", address(asset));
        console.log("AssetVault (Anvil):", address(vault));
        console.log("");
        console.log("Add to .env:");
        console.log("  MOCK_ASSET_CONTRACT=%s", address(asset));
        console.log("  ASSET_VAULT_CONTRACT=%s", address(vault));
    }
}

/// Mint a test tokenized asset (Anvil only):
///   RECIPIENT=0x... forge script script/DeployPOCv2.s.sol:MintTestAsset --rpc-url http://localhost:8545 --broadcast
contract MintTestAsset is Script {
    function run() external {
        address token     = vm.envAddress("MOCK_ASSET_CONTRACT");
        address recipient = vm.envAddress("RECIPIENT");

        vm.startBroadcast();
        uint256 tokenId = MockAsset(token).mint(recipient, "BOND");
        vm.stopBroadcast();

        console.log("Minted asset tokenId=%s (BOND) to %s", tokenId, recipient);
    }
}

/// Mint INRDC test tokens to a wallet (Anvil only — for local testing):
///   RECIPIENT=0x... forge script script/DeployPOCv2.s.sol:MintTestCBDC --rpc-url http://localhost:8545 --broadcast
contract MintTestCBDC is Script {
    function run() external {
        address token     = vm.envAddress("MOCK_CBDC_TOKEN");
        address recipient = vm.envAddress("RECIPIENT");
        uint256 amount    = 100_000 * 1e18; // 100,000 INRDC

        vm.startBroadcast();
        MockCBDC(token).mint(recipient, amount);
        vm.stopBroadcast();

        console.log("Minted %s INRDC to %s", amount / 1e18, recipient);
    }
}
