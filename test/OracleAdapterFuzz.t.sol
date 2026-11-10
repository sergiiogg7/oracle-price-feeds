// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {OracleAdapter} from "../src/oracles/OracleAdapter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract OracleAdapterFuzzTest is Test {
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xE7));

    OracleAdapter internal adapter;
    MockPyth internal pyth;
    address internal token = makeAddr("token");

    function setUp() public {
        vm.warp(1_000_000);
        pyth = new MockPyth(60, 1);
        adapter = new OracleAdapter(address(this), address(pyth), address(0));
    }

    /// @dev Whatever the feed decimals and answer, the price is the answer rescaled to 8 decimals (or a revert if it
    ///      rescales to zero). It is never a wrong non-zero number.
    function testFuzz_Chainlink_ScalesToEightDecimals(uint8 decimals, uint128 answer) public {
        decimals = uint8(bound(decimals, 0, 18));
        answer = uint128(bound(answer, 1, type(uint128).max));
        MockAggregator feed = new MockAggregator(decimals, int256(uint256(answer)));
        adapter.setAssetConfig(token, address(feed), 1 hours, bytes32(0), 0, 0);

        uint256 expected =
            decimals >= 8 ? uint256(answer) / 10 ** (decimals - 8) : uint256(answer) * 10 ** (8 - decimals);
        if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
            adapter.getAssetPrice(token);
        } else {
            assertEq(adapter.getAssetPrice(token), expected);
        }
    }

    /// @dev A Chainlink answer is accepted exactly while its age is within `maxStaleness`.
    function testFuzz_Chainlink_StalenessBoundary(uint32 maxStaleness, uint32 age) public {
        maxStaleness = uint32(bound(maxStaleness, 1, type(uint32).max));
        MockAggregator feed = new MockAggregator(8, 2_000e8);
        adapter.setAssetConfig(token, address(feed), maxStaleness, bytes32(0), 0, 0);
        vm.warp(block.timestamp + age);

        if (age > maxStaleness) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        }
        adapter.getAssetPrice(token);
    }

    /// @dev Non-positive answers are never accepted.
    function testFuzz_Chainlink_NonPositiveAnswerRejected(int256 answer) public {
        answer = bound(answer, type(int256).min, 0);
        MockAggregator feed = new MockAggregator(8, 1);
        feed.set(answer);
        adapter.setAssetConfig(token, address(feed), 1 hours, bytes32(0), 0, 0);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        adapter.getAssetPrice(token);
    }

    /// @dev Pyth price and exponent: the result is `price * 10^(expo + 8)`; out-of-range exponents are rejected.
    function testFuzz_Pyth_Normalization(int64 price, int32 expo) public {
        price = int64(bound(price, 1, type(int64).max));
        expo = int32(bound(expo, -40, 40));
        adapter.setAssetConfig(token, address(0), 0, PRICE_ID, 60, 10_000);
        _push(price, 0, expo);

        int256 shift = int256(expo) + 8;
        uint256 raw = uint256(uint64(price));
        uint256 expected;
        bool valid = shift >= -18 && shift <= 18;
        if (valid) {
            expected = shift >= 0 ? raw * 10 ** uint256(shift) : raw / 10 ** uint256(-shift);
        }

        if (!valid || expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
            adapter.getAssetPrice(token);
        } else {
            assertEq(adapter.getAssetPrice(token), expected);
        }
    }

    /// @dev Pyth is accepted iff `conf / price <= maxConfidenceBps / 10_000`.
    function testFuzz_Pyth_ConfidenceBoundary(uint64 price, uint64 conf, uint16 bps) public {
        price = uint64(bound(price, 1, uint64(type(int64).max)));
        bps = uint16(bound(bps, 1, 10_000));
        adapter.setAssetConfig(token, address(0), 0, PRICE_ID, 60, bps);
        _push(int64(price), conf, 0);

        bool accepted = uint256(conf) * 10_000 <= uint256(price) * bps;
        if (!accepted) {
            vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        }
        adapter.getAssetPrice(token);
    }

    /// @dev With arbitrary feed state the adapter either reverts or returns a non-zero price.
    function testFuzz_NeverReturnsZero(uint80 roundId, int256 answer, uint32 updatedAtAgo, uint80 answeredInRound)
        public
    {
        MockAggregator feed = new MockAggregator(8, 1);
        uint256 updatedAt = block.timestamp > updatedAtAgo ? block.timestamp - updatedAtAgo : 0;
        feed.setRaw(roundId, answer, updatedAt, updatedAt, answeredInRound);
        adapter.setAssetConfig(token, address(feed), 1 hours, bytes32(0), 0, 0);

        try adapter.getAssetPrice(token) returns (uint256 price) {
            assertGt(price, 0);
        } catch {}
    }

    function _push(int64 price, uint64 conf, int32 expo) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(PRICE_ID, price, conf, expo, price, conf, uint64(block.timestamp));
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(data)}(data);
    }
}
