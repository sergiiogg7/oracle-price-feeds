// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "../src/oracles/ChainlinkOracle.sol";

/// @notice Deploys `ChainlinkOracle`; assets are configured afterwards with `setAssetConfig` (see README).
/// @dev Required: `PRIVATE_KEY`, `OWNER`. Optional: `SEQUENCER_FEED` (Chainlink L2 sequencer uptime feed, zero on L1).
///      See `.env.example`.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external returns (ChainlinkOracle oracle) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));

        vm.startBroadcast(deployerKey);
        oracle = new ChainlinkOracle(owner, sequencerFeed);
        vm.stopBroadcast();

        console.log("ChainlinkOracle:", address(oracle));
        console.log("owner:", owner);
        console.log("sequencer feed:", sequencerFeed);
    }
}
