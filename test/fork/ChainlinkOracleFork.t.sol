// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../../src/oracles/ChainlinkOracle.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Reads the REAL Chainlink ETH/USD feed on Sepolia through the oracle. Optional: it is skipped unless
///         `SEPOLIA_RPC_URL` is set, so CI does not depend on a node. Run:
///         SEPOLIA_RPC_URL=<url> forge test --match-contract ChainlinkOracleForkTest -vv
contract ChainlinkOracleForkTest is Test {
    /// @dev Chainlink ETH/USD on Sepolia.
    address internal constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function test_Fork_RealFeedThroughOracle() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        address weth = makeAddr("weth");
        ChainlinkOracle oracle = new ChainlinkOracle(address(this), address(0));
        // ETH/USD heartbeat on Sepolia is 1 hour; allow a generous margin for a testnet feed.
        oracle.setAssetConfig(weth, ETH_USD_FEED, 24 hours);

        uint256 price = oracle.getAssetPrice(weth);
        (, int256 raw,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        emit log_named_uint("ETH/USD (8 decimals)", price);

        assertEq(AggregatorV3Interface(ETH_USD_FEED).decimals(), 8);
        assertEq(price, uint256(raw));
        assertGt(price, 100e8); // sanity: ETH above 100 USD
        assertLt(price, 100_000e8); // and below 100 000 USD
    }
}
