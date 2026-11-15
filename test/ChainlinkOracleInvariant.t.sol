// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/oracles/ChainlinkOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @dev Moves the Chainlink feed (prices, breakage) and the clock at random and reads the oracle after every step,
///      recording violations in ghost variables.
contract InvChainlinkHandler is Test {
    uint32 internal constant STALENESS = 1 hours;

    ChainlinkOracle public immutable oracle;
    MockAggregator public immutable feed;
    address public immutable token;

    uint256 public ghostReads;
    uint256 public ghostZeroPrices;
    uint256 public ghostStaleAccepted;

    constructor(ChainlinkOracle oracle_, MockAggregator feed_, address token_) {
        oracle = oracle_;
        feed = feed_;
        token = token_;
    }

    function chainlinkUpdate(int256 answer) external {
        feed.set(bound(answer, -1e12, 1e14));
        _read();
    }

    function chainlinkBreak(bool broken) external {
        feed.setBroken(broken);
        _read();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 hours));
        _read();
    }

    function _read() internal {
        ghostReads++;
        try oracle.getAssetPrice(token) returns (uint256 price) {
            if (price == 0) ghostZeroPrices++;
            if (block.timestamp - feed.updatedAt() > STALENESS) ghostStaleAccepted++;
        } catch {}
    }
}

contract ChainlinkOracleInvariantTest is Test {
    InvChainlinkHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        MockAggregator feed = new MockAggregator(8, 2_000e8);
        ChainlinkOracle oracle = new ChainlinkOracle(address(this), address(0));
        address token = makeAddr("token");
        oracle.setAssetConfig(token, address(feed), 1 hours);

        handler = new InvChainlinkHandler(oracle, feed, token);
        targetContract(address(handler));
    }

    /// @dev The oracle never returns zero: it reverts instead.
    function invariant_NeverReturnsZero() public view {
        assertEq(handler.ghostZeroPrices(), 0);
    }

    /// @dev A price older than `maxStaleness` is never returned.
    function invariant_NeverReturnsStalePrice() public view {
        assertEq(handler.ghostStaleAccepted(), 0);
    }
}
