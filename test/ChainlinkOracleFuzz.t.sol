// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/oracles/ChainlinkOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract ChainlinkOracleFuzzTest is Test {
    ChainlinkOracle internal oracle;
    address internal token = makeAddr("token");

    function setUp() public {
        vm.warp(1_000_000);
        oracle = new ChainlinkOracle(address(this), address(0));
    }

    /// @dev Whatever the feed decimals and answer, the price is the answer rescaled to 8 decimals (or a revert if it
    ///      rescales to zero). It is never a wrong non-zero number.
    function testFuzz_ScalesToEightDecimals(uint8 decimals, uint128 answer) public {
        decimals = uint8(bound(decimals, 0, 18));
        answer = uint128(bound(answer, 1, type(uint128).max));
        MockAggregator feed = new MockAggregator(decimals, int256(uint256(answer)));
        oracle.setAssetConfig(token, address(feed), 1 hours);

        uint256 expected =
            decimals >= 8 ? uint256(answer) / 10 ** (decimals - 8) : uint256(answer) * 10 ** (8 - decimals);
        if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.NoValidPrice.selector, token));
            oracle.getAssetPrice(token);
        } else {
            assertEq(oracle.getAssetPrice(token), expected);
        }
    }

    /// @dev An answer is accepted exactly while its age is within `maxStaleness`.
    function testFuzz_StalenessBoundary(uint32 maxStaleness, uint32 age) public {
        maxStaleness = uint32(bound(maxStaleness, 1, type(uint32).max));
        MockAggregator feed = new MockAggregator(8, 2_000e8);
        oracle.setAssetConfig(token, address(feed), maxStaleness);
        vm.warp(block.timestamp + age);

        if (age > maxStaleness) {
            vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.NoValidPrice.selector, token));
        }
        oracle.getAssetPrice(token);
    }

    /// @dev Non-positive answers are never accepted.
    function testFuzz_NonPositiveAnswerRejected(int256 answer) public {
        answer = bound(answer, type(int256).min, 0);
        MockAggregator feed = new MockAggregator(8, 1);
        feed.set(answer);
        oracle.setAssetConfig(token, address(feed), 1 hours);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.NoValidPrice.selector, token));
        oracle.getAssetPrice(token);
    }

    /// @dev With arbitrary feed state the oracle either reverts or returns a non-zero price.
    function testFuzz_NeverReturnsZero(uint80 roundId, int256 answer, uint32 updatedAtAgo, uint80 answeredInRound)
        public
    {
        MockAggregator feed = new MockAggregator(8, 1);
        uint256 updatedAt = block.timestamp > updatedAtAgo ? block.timestamp - updatedAtAgo : 0;
        feed.setRaw(roundId, answer, updatedAt, updatedAt, answeredInRound);
        oracle.setAssetConfig(token, address(feed), 1 hours);

        try oracle.getAssetPrice(token) returns (uint256 price) {
            assertGt(price, 0);
        } catch {}
    }
}
