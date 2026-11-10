// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OracleAdapter} from "../src/oracles/OracleAdapter.sol";

/// @notice Deploys `OracleAdapter`; assets are configured afterwards with `setAssetConfig` (see README).
/// @dev Required: `PRIVATE_KEY`, `OWNER`. Optional: `PYTH` (zero if Pyth is not used) and `SEQUENCER_FEED`
///      (Chainlink L2 sequencer uptime feed, zero on L1). See `.env.example`.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external returns (OracleAdapter adapter) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address pyth = vm.envOr("PYTH", address(0));
        address sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));

        vm.startBroadcast(deployerKey);
        adapter = new OracleAdapter(owner, pyth, sequencerFeed);
        vm.stopBroadcast();

        console.log("OracleAdapter:", address(adapter));
        console.log("owner:", owner);
        console.log("pyth:", pyth);
        console.log("sequencer feed:", sequencerFeed);
    }
}
