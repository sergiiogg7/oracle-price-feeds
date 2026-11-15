// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChainlinkOracle} from "../src/oracles/ChainlinkOracle.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract ChainlinkOracleTest is Test {
    uint32 internal constant STALENESS = 1 hours;

    ChainlinkOracle internal oracle;
    MockAggregator internal feed;
    address internal owner = makeAddr("owner");
    address internal token = makeAddr("token");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregator(8, 2_000e8);
        oracle = new ChainlinkOracle(owner, address(0));
        vm.prank(owner);
        oracle.setAssetConfig(token, address(feed), STALENESS);
    }

    // --- configuration ---

    function test_ConstructorSetsState() public view {
        assertEq(oracle.owner(), owner);
        assertEq(address(oracle.sequencerUptimeFeed()), address(0));
        assertEq(oracle.PRICE_DECIMALS(), 8);
    }

    function test_SetAssetConfig_StoresAndEmits() public {
        address other = makeAddr("other");
        MockAggregator f6 = new MockAggregator(6, 1e6);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ChainlinkOracle.AssetConfigured(other, address(f6), 2 hours);
        vm.prank(owner);
        oracle.setAssetConfig(other, address(f6), 2 hours);

        ChainlinkOracle.AssetConfig memory cfg = oracle.getAssetConfig(other);
        assertEq(address(cfg.feed), address(f6));
        assertEq(cfg.maxStaleness, 2 hours);
        assertEq(cfg.decimals, 6);
    }

    function test_RevertWhen_ConfigTokenIsZero() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracle.ZeroAddress.selector);
        oracle.setAssetConfig(address(0), address(feed), STALENESS);
    }

    function test_RevertWhen_ConfigFeedIsZero() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracle.ZeroAddress.selector);
        oracle.setAssetConfig(token, address(0), STALENESS);
    }

    function test_RevertWhen_StalenessIsZero() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracle.InvalidConfig.selector);
        oracle.setAssetConfig(token, address(feed), 0);
    }

    function test_RevertWhen_FeedDecimalsTooHigh() public {
        MockAggregator f = new MockAggregator(19, 1);
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracle.InvalidConfig.selector);
        oracle.setAssetConfig(token, address(f), STALENESS);
    }

    function test_RevertWhen_NonOwnerConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracle.setAssetConfig(token, address(feed), STALENESS);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        oracle.removeAsset(token);
        vm.stopPrank();
    }

    function test_RemoveAsset() public {
        vm.expectEmit(true, false, false, false, address(oracle));
        emit ChainlinkOracle.AssetRemoved(token);
        vm.prank(owner);
        oracle.removeAsset(token);

        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.AssetNotConfigured.selector, token));
        oracle.getAssetPrice(token);
    }

    function test_RevertWhen_RemoveUnknownAsset() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.AssetNotConfigured.selector, stranger));
        oracle.removeAsset(stranger);
    }

    function test_OwnershipIsTwoStep() public {
        vm.prank(owner);
        oracle.transferOwnership(stranger);
        assertEq(oracle.owner(), owner);
        vm.prank(stranger);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), stranger);
    }

    function test_RevertWhen_AssetNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.AssetNotConfigured.selector, stranger));
        oracle.getAssetPrice(stranger);
    }

    // --- prices ---

    function test_ReturnsPrice() public view {
        assertEq(oracle.getAssetPrice(token), 2_000e8);
    }

    function test_WorksThroughTheLendingInterface() public view {
        assertEq(IPriceOracle(address(oracle)).getAssetPrice(token), 2_000e8);
    }

    function test_ScalesDownFrom18Decimals() public {
        MockAggregator f18 = new MockAggregator(18, 2_000e18);
        _config(address(f18));
        assertEq(oracle.getAssetPrice(token), 2_000e8);
    }

    function test_ScalesUpFrom6Decimals() public {
        MockAggregator f6 = new MockAggregator(6, 1_000_000); // 1.000000
        _config(address(f6));
        assertEq(oracle.getAssetPrice(token), 1e8);
    }

    function test_StalenessBoundary() public {
        vm.warp(block.timestamp + STALENESS);
        assertEq(oracle.getAssetPrice(token), 2_000e8); // exactly at the limit: valid

        vm.warp(block.timestamp + 1);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsZeroAndNegative() public {
        feed.set(0);
        _expectNoPrice();
        oracle.getAssetPrice(token);

        feed.set(-5);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsZeroUpdatedAt() public {
        feed.setRaw(1, 2_000e8, 0, 0, 1);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsAnsweredInOlderRound() public {
        feed.setRaw(5, 2_000e8, block.timestamp, block.timestamp, 4);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsFutureTimestamp() public {
        feed.setRaw(1, 2_000e8, block.timestamp, block.timestamp + 1, 1);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsPriceThatScalesToZero() public {
        MockAggregator f18 = new MockAggregator(18, 1e9); // 1e9 / 1e10 = 0
        _config(address(f18));
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    function test_RejectsRevertingFeed() public {
        feed.setBroken(true);
        _expectNoPrice();
        oracle.getAssetPrice(token);
    }

    // --- L2 sequencer ---

    function test_Sequencer_NoFeedMeansNoCheck() public view {
        assertEq(oracle.getAssetPrice(token), 2_000e8);
    }

    function test_Sequencer_DownReverts() public {
        (ChainlinkOracle o, MockAggregator seq) = _oracleWithSequencer();
        seq.set(1);
        vm.expectRevert(ChainlinkOracle.SequencerDown.selector);
        o.getAssetPrice(token);
    }

    function test_Sequencer_GracePeriod() public {
        (ChainlinkOracle o, MockAggregator seq) = _oracleWithSequencer();
        seq.set(0); // up since now

        vm.expectRevert(ChainlinkOracle.SequencerGracePeriodNotOver.selector);
        o.getAssetPrice(token);

        feed.set(2_000e8);
        vm.warp(block.timestamp + o.SEQUENCER_GRACE_PERIOD() - 1);
        feed.set(2_000e8);
        vm.expectRevert(ChainlinkOracle.SequencerGracePeriodNotOver.selector);
        o.getAssetPrice(token);

        vm.warp(block.timestamp + 1);
        feed.set(2_000e8);
        assertEq(o.getAssetPrice(token), 2_000e8);
    }

    function test_Sequencer_InvalidRoundReverts() public {
        (ChainlinkOracle o, MockAggregator seq) = _oracleWithSequencer();
        seq.setRaw(1, 0, 0, 0, 1); // startedAt == 0
        vm.expectRevert(ChainlinkOracle.SequencerGracePeriodNotOver.selector);
        o.getAssetPrice(token);
    }

    // --- helpers ---

    function _oracleWithSequencer() internal returns (ChainlinkOracle o, MockAggregator seq) {
        seq = new MockAggregator(0, 0);
        o = new ChainlinkOracle(owner, address(seq));
        vm.prank(owner);
        o.setAssetConfig(token, address(feed), STALENESS);
    }

    function _config(address f) internal {
        vm.prank(owner);
        oracle.setAssetConfig(token, f, STALENESS);
    }

    function _expectNoPrice() internal {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.NoValidPrice.selector, token));
    }
}
