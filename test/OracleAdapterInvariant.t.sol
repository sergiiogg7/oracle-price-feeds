// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {OracleAdapter} from "../src/oracles/OracleAdapter.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

/// @dev Moves Chainlink (prices, breakage, time), Pyth (prices, confidence) and the clock at random and reads the
///      adapter after every step, recording violations in ghost variables.
contract InvOracleHandler is Test {
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xE7));
    uint32 internal constant STALENESS = 1 hours;
    uint32 internal constant PYTH_AGE = 60;

    OracleAdapter public immutable adapter;
    MockAggregator public immutable feed;
    MockPyth public immutable pyth;
    address public immutable token;

    uint256 public ghostReads;
    uint256 public ghostZeroPrices;
    uint256 public ghostStaleChainlinkAccepted;
    uint256 public ghostStalePythAccepted;
    uint64 internal lastPythPublish;

    constructor(OracleAdapter adapter_, MockAggregator feed_, MockPyth pyth_, address token_) {
        adapter = adapter_;
        feed = feed_;
        pyth = pyth_;
        token = token_;
        vm.deal(address(this), 100 ether); // pays the Pyth update fee
    }

    function chainlinkUpdate(int256 answer) external {
        feed.set(bound(answer, -1e12, 1e14));
        _read();
    }

    function chainlinkBreak(bool broken) external {
        feed.setBroken(broken);
        _read();
    }

    function pythUpdate(int64 price, uint64 conf, int32 expo) external {
        price = int64(bound(price, -1e12, 1e15));
        expo = int32(bound(expo, -12, 2));
        uint64 publishTime = uint64(block.timestamp);
        if (publishTime <= lastPythPublish) return; // MockPyth ignores updates that are not newer
        lastPythPublish = publishTime;

        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(PRICE_ID, price, conf, expo, price, conf, publishTime);
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(data)}(data);
        _read();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 hours));
        _read();
    }

    function _read() internal {
        ghostReads++;
        try adapter.getAssetPriceWithSource(token) returns (uint256 price, OracleAdapter.Source source) {
            if (price == 0) ghostZeroPrices++;
            if (source == OracleAdapter.Source.Chainlink) {
                if (block.timestamp - feed.updatedAt() > STALENESS) ghostStaleChainlinkAccepted++;
            } else {
                uint256 publishTime = pyth.getPriceUnsafe(PRICE_ID).publishTime;
                if (block.timestamp - publishTime > PYTH_AGE) ghostStalePythAccepted++;
            }
        } catch {}
    }
}

contract OracleAdapterInvariantTest is Test {
    InvOracleHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        MockAggregator feed = new MockAggregator(8, 2_000e8);
        MockPyth pyth = new MockPyth(60, 1);
        OracleAdapter adapter = new OracleAdapter(address(this), address(pyth), address(0));
        address token = makeAddr("token");
        adapter.setAssetConfig(token, address(feed), 1 hours, bytes32(uint256(0xE7)), 60, 100);

        handler = new InvOracleHandler(adapter, feed, pyth, token);
        targetContract(address(handler));
    }

    /// @dev The oracle never returns zero: it reverts instead.
    function invariant_NeverReturnsZero() public view {
        assertEq(handler.ghostZeroPrices(), 0);
    }

    /// @dev A Chainlink price older than `maxStaleness` is never returned.
    function invariant_NeverReturnsStaleChainlink() public view {
        assertEq(handler.ghostStaleChainlinkAccepted(), 0);
    }

    /// @dev A Pyth price older than `maxAge` is never returned.
    function invariant_NeverReturnsStalePyth() public view {
        assertEq(handler.ghostStalePythAccepted(), 0);
    }
}
