// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../../src/oracles/OracleAdapter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Reads the REAL Chainlink ETH/USD feed on Sepolia through the adapter. Optional: it is skipped unless
///         `SEPOLIA_RPC_URL` is set, so CI does not depend on a node. Run:
///         SEPOLIA_RPC_URL=<url> forge test --match-contract OracleAdapterForkTest -vv
contract OracleAdapterForkTest is Test {
    /// @dev Chainlink ETH/USD on Sepolia.
    address internal constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    /// @dev Pyth on Sepolia (not used here; Chainlink is enough to validate the real feed).
    address internal constant PYTH_SEPOLIA = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    function test_Fork_RealChainlinkFeedThroughAdapter() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        assertGt(PYTH_SEPOLIA.code.length, 0, "Pyth address has no code on this network");

        address weth = makeAddr("weth");
        OracleAdapter adapter = new OracleAdapter(address(this), PYTH_SEPOLIA, address(0));
        // ETH/USD heartbeat on Sepolia is 1 hour; allow a generous margin for a testnet feed.
        adapter.setAssetConfig(weth, ETH_USD_FEED, 24 hours, bytes32(0), 0, 0);

        uint256 price = adapter.getAssetPrice(weth);
        (, int256 raw,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        emit log_named_uint("ETH/USD (8 decimals)", price);

        assertEq(AggregatorV3Interface(ETH_USD_FEED).decimals(), 8);
        assertEq(price, uint256(raw));
        assertGt(price, 100e8); // sanity: ETH above 100 USD
        assertLt(price, 100_000e8); // and below 100 000 USD
    }
}
