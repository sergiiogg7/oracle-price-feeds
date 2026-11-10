// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {NaiveChainlinkOracle} from "../src/naive/NaiveChainlinkOracle.sol";
import {NaivePythOracle} from "../src/naive/NaivePythOracle.sol";
import {OracleAdapter} from "../src/oracles/OracleAdapter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @notice Shows what the naive oracles accept and that `OracleAdapter` rejects the same inputs.
///         Each `test_Exploit_*` passes because the naive contract returns a dangerous value.
contract NaiveOraclesTest is Test {
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xE7));
    address internal token = makeAddr("token");

    MockAggregator internal feed;
    MockPyth internal pyth;
    NaiveChainlinkOracle internal naiveChainlink;
    NaivePythOracle internal naivePyth;
    OracleAdapter internal adapter;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregator(8, 2_000e8);
        pyth = new MockPyth(60, 1);
        naiveChainlink = new NaiveChainlinkOracle(address(feed));
        naivePyth = new NaivePythOracle(address(pyth), PRICE_ID);

        adapter = new OracleAdapter(address(this), address(pyth), address(0));
        adapter.setAssetConfig(token, address(feed), 1 hours, PRICE_ID, 60, 100);
    }

    function test_NaiveChainlink_ReturnsFreshPrice() public view {
        assertEq(naiveChainlink.getLatestPrice(), 2_000e8);
        assertEq(address(naiveChainlink.priceFeed()), address(feed));
    }

    /// @notice ATTACK: the feed froze three days ago; the naive oracle still returns that price as current.
    function test_Exploit_NaiveChainlink_AcceptsStalePrice() public {
        vm.warp(block.timestamp + 3 days);
        assertEq(naiveChainlink.getLatestPrice(), 2_000e8);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        adapter.getAssetPrice(token);
    }

    /// @notice ATTACK: a zero answer is returned as a price (a debt valued at zero, collateral at zero).
    function test_Exploit_NaiveChainlink_ReturnsZero() public {
        feed.set(0);
        assertEq(naiveChainlink.getLatestPrice(), 0);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        adapter.getAssetPrice(token);
    }

    /// @notice ATTACK: a negative answer is returned as is and breaks any later cast to `uint256`.
    function test_Exploit_NaiveChainlink_ReturnsNegative() public {
        feed.set(-1);
        assertEq(naiveChainlink.getLatestPrice(), -1);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        adapter.getAssetPrice(token);
    }

    function test_NaivePyth_ReturnsFreshPrice() public {
        _push(2_000e8, 1e8, -8, uint64(block.timestamp));
        (int64 price, uint64 conf, int32 expo) = naivePyth.getLatestPrice();
        assertEq(price, 2_000e8);
        assertEq(conf, 1e8);
        assertEq(expo, -8);
        assertEq(address(naivePyth.pyth()), address(pyth));
    }

    /// @notice ATTACK: a Pyth price published a week ago is returned by `getPriceUnsafe` without complaint.
    function test_Exploit_NaivePyth_AcceptsOldPrice() public {
        _push(2_000e8, 1e8, -8, uint64(block.timestamp));
        vm.warp(block.timestamp + 7 days);

        (int64 price,,) = naivePyth.getLatestPrice();
        assertEq(price, 2_000e8);

        // Pyth-only asset: the adapter refuses the same price.
        address pythOnly = makeAddr("pythOnly");
        adapter.setAssetConfig(pythOnly, address(0), 0, PRICE_ID, 60, 100);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, pythOnly));
        adapter.getAssetPrice(pythOnly);
    }

    /// @notice ATTACK: price 100 with confidence 100 (+/- 100 %) is "valid" for the naive oracle.
    function test_Exploit_NaivePyth_IgnoresWideConfidence() public {
        _push(100, 100, 0, uint64(block.timestamp));
        (int64 price, uint64 conf,) = naivePyth.getLatestPrice();
        assertEq(price, 100);
        assertEq(conf, 100);

        address pythOnly = makeAddr("pythOnly");
        adapter.setAssetConfig(pythOnly, address(0), 0, PRICE_ID, 60, 100);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, pythOnly));
        adapter.getAssetPrice(pythOnly);
    }

    function _push(int64 price, uint64 conf, int32 expo, uint64 publishTime) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(PRICE_ID, price, conf, expo, price, conf, publishTime);
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(data)}(data);
    }
}
