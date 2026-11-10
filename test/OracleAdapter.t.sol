// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {OracleAdapter} from "../src/oracles/OracleAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract OracleAdapterTest is Test {
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xE7));
    uint32 internal constant STALENESS = 1 hours;
    uint32 internal constant PYTH_AGE = 60;
    uint16 internal constant MAX_CONF_BPS = 100; // 1 %

    OracleAdapter internal adapter;
    MockAggregator internal feed;
    MockPyth internal pyth;
    address internal owner = makeAddr("owner");
    address internal token = makeAddr("token");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregator(8, 2_000e8);
        pyth = new MockPyth(PYTH_AGE, 1);
        adapter = new OracleAdapter(owner, address(pyth), address(0));
        vm.prank(owner);
        adapter.setAssetConfig(token, address(feed), STALENESS, PRICE_ID, PYTH_AGE, MAX_CONF_BPS);
    }

    // --- configuration ---

    function test_ConstructorSetsState() public view {
        assertEq(adapter.owner(), owner);
        assertEq(address(adapter.pyth()), address(pyth));
        assertEq(address(adapter.sequencerUptimeFeed()), address(0));
        assertEq(adapter.PRICE_DECIMALS(), 8);
    }

    function test_SetAssetConfig_StoresAndEmits() public {
        address other = makeAddr("other");
        MockAggregator f6 = new MockAggregator(6, 1e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit OracleAdapter.AssetConfigured(other, address(f6), 2 hours, PRICE_ID, 30, 50);
        vm.prank(owner);
        adapter.setAssetConfig(other, address(f6), 2 hours, PRICE_ID, 30, 50);

        OracleAdapter.AssetConfig memory cfg = adapter.getAssetConfig(other);
        assertEq(address(cfg.chainlinkFeed), address(f6));
        assertEq(cfg.chainlinkMaxStaleness, 2 hours);
        assertEq(cfg.chainlinkDecimals, 6);
        assertEq(cfg.pythPriceId, PRICE_ID);
        assertEq(cfg.pythMaxAge, 30);
        assertEq(cfg.pythMaxConfidenceBps, 50);
    }

    function test_RevertWhen_ConfigTokenIsZero() public {
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        adapter.setAssetConfig(address(0), address(feed), STALENESS, 0, 0, 0);
    }

    function test_RevertWhen_ConfigHasNoSource() public {
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(0), 0, bytes32(0), 0, 0);
    }

    function test_RevertWhen_ChainlinkStalenessIsZero() public {
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(feed), 0, bytes32(0), 0, 0);
    }

    function test_RevertWhen_FeedDecimalsTooHigh() public {
        MockAggregator f = new MockAggregator(19, 1);
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(f), STALENESS, bytes32(0), 0, 0);
    }

    function test_RevertWhen_PythConfiguredWithoutPythContract() public {
        OracleAdapter noPyth = new OracleAdapter(owner, address(0), address(0));
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        noPyth.setAssetConfig(token, address(feed), STALENESS, PRICE_ID, PYTH_AGE, MAX_CONF_BPS);
    }

    function test_RevertWhen_PythMaxAgeIsZero() public {
        vm.prank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(0), 0, PRICE_ID, 0, MAX_CONF_BPS);
    }

    function test_RevertWhen_PythConfidenceBpsInvalid() public {
        vm.startPrank(owner);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(0), 0, PRICE_ID, PYTH_AGE, 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        adapter.setAssetConfig(token, address(0), 0, PRICE_ID, PYTH_AGE, 10_001);
        vm.stopPrank();
    }

    function test_RevertWhen_NonOwnerConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setAssetConfig(token, address(feed), STALENESS, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.removeAsset(token);
        vm.stopPrank();
    }

    function test_RemoveAsset() public {
        vm.expectEmit(true, false, false, false, address(adapter));
        emit OracleAdapter.AssetRemoved(token);
        vm.prank(owner);
        adapter.removeAsset(token);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AssetNotConfigured.selector, token));
        adapter.getAssetPrice(token);
    }

    function test_RevertWhen_RemoveUnknownAsset() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AssetNotConfigured.selector, stranger));
        adapter.removeAsset(stranger);
    }

    function test_OwnershipIsTwoStep() public {
        vm.prank(owner);
        adapter.transferOwnership(stranger);
        assertEq(adapter.owner(), owner);
        vm.prank(stranger);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), stranger);
    }

    function test_RevertWhen_AssetNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.AssetNotConfigured.selector, stranger));
        adapter.getAssetPrice(stranger);
    }

    // --- Chainlink ---

    function test_Chainlink_ReturnsPriceAndSource() public view {
        (uint256 price, OracleAdapter.Source source) = adapter.getAssetPriceWithSource(token);
        assertEq(price, 2_000e8);
        assertEq(uint8(source), uint8(OracleAdapter.Source.Chainlink));
        assertEq(adapter.getAssetPrice(token), 2_000e8);
    }

    function test_Chainlink_WorksThroughTheLendingInterface() public view {
        assertEq(IPriceOracle(address(adapter)).getAssetPrice(token), 2_000e8);
    }

    function test_Chainlink_ScalesDownFrom18Decimals() public {
        MockAggregator f18 = new MockAggregator(18, 2_000e18);
        _configChainlinkOnly(address(f18));
        assertEq(adapter.getAssetPrice(token), 2_000e8);
    }

    function test_Chainlink_ScalesUpFrom6Decimals() public {
        MockAggregator f6 = new MockAggregator(6, 1_000_000); // 1.000000
        _configChainlinkOnly(address(f6));
        assertEq(adapter.getAssetPrice(token), 1e8);
    }

    function test_Chainlink_StalenessBoundary() public {
        vm.warp(block.timestamp + STALENESS);
        assertEq(adapter.getAssetPrice(token), 2_000e8); // exactly at the limit: valid

        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsZeroAndNegative() public {
        _configChainlinkOnly(address(feed));
        feed.set(0);
        _expectNoPrice();
        adapter.getAssetPrice(token);

        feed.set(-5);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsZeroUpdatedAt() public {
        _configChainlinkOnly(address(feed));
        feed.setRaw(1, 2_000e8, 0, 0, 1);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsAnsweredInOlderRound() public {
        _configChainlinkOnly(address(feed));
        feed.setRaw(5, 2_000e8, block.timestamp, block.timestamp, 4);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsFutureTimestamp() public {
        _configChainlinkOnly(address(feed));
        feed.setRaw(1, 2_000e8, block.timestamp, block.timestamp + 1, 1);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsPriceThatScalesToZero() public {
        MockAggregator f18 = new MockAggregator(18, 1e9); // 1e9 / 1e10 = 0
        _configChainlinkOnly(address(f18));
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Chainlink_RejectsRevertingFeed() public {
        _configChainlinkOnly(address(feed));
        feed.setBroken(true);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    // --- Pyth fallback ---

    function test_Fallback_UsesPythWhenChainlinkIsStale() public {
        vm.warp(block.timestamp + 2 hours);
        _push(2_100e8, 1e8, -8, uint64(block.timestamp));

        (uint256 price, OracleAdapter.Source source) = adapter.getAssetPriceWithSource(token);
        assertEq(price, 2_100e8);
        assertEq(uint8(source), uint8(OracleAdapter.Source.Pyth));
    }

    function test_Fallback_UsesPythWhenChainlinkReverts() public {
        feed.setBroken(true);
        _push(2_100e8, 1e8, -8, uint64(block.timestamp));
        assertEq(adapter.getAssetPrice(token), 2_100e8);
    }

    function test_Fallback_ChainlinkWinsWhenBothAreValid() public {
        _push(9_999e8, 1e8, -8, uint64(block.timestamp));
        (uint256 price, OracleAdapter.Source source) = adapter.getAssetPriceWithSource(token);
        assertEq(price, 2_000e8);
        assertEq(uint8(source), uint8(OracleAdapter.Source.Chainlink));
    }

    function test_Fallback_RevertsWhenBothFail() public {
        feed.setBroken(true);
        _expectNoPrice(); // Pyth has no price for the id
        adapter.getAssetPrice(token);
    }

    function test_Pyth_NormalizesExponents() public {
        feed.setBroken(true);
        _push(2_000e5, 1e3, -5, uint64(block.timestamp)); // 2000.00000
        assertEq(adapter.getAssetPrice(token), 2_000e8);

        vm.warp(block.timestamp + 1);
        _push(2_000e10, 1e8, -10, uint64(block.timestamp)); // 2000.0000000000
        assertEq(adapter.getAssetPrice(token), 2_000e8);

        vm.warp(block.timestamp + 1);
        _push(2, 0, 3, uint64(block.timestamp)); // 2 * 10^3
        assertEq(adapter.getAssetPrice(token), 2_000e8);
    }

    function test_Pyth_RejectsStalePrice() public {
        feed.setBroken(true);
        _push(2_000e8, 1e8, -8, uint64(block.timestamp));
        vm.warp(block.timestamp + PYTH_AGE); // exactly at the limit: valid
        assertEq(adapter.getAssetPrice(token), 2_000e8);

        vm.warp(block.timestamp + 1);
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Pyth_RejectsZeroAndNegativePrice() public {
        feed.setBroken(true);
        _push(0, 0, -8, uint64(block.timestamp));
        _expectNoPrice();
        adapter.getAssetPrice(token);

        vm.warp(block.timestamp + 1);
        _push(-1, 0, -8, uint64(block.timestamp));
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Pyth_ConfidenceBoundary() public {
        feed.setBroken(true);
        _push(10_000, 100, 0, uint64(block.timestamp)); // conf = 1 % of price: exactly the limit
        assertEq(adapter.getAssetPrice(token), 10_000 * 1e8);

        vm.warp(block.timestamp + 1);
        _push(10_000, 101, 0, uint64(block.timestamp)); // just above
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Pyth_RejectsAbsurdExponent() public {
        feed.setBroken(true);
        _push(1, 0, -30, uint64(block.timestamp));
        _expectNoPrice();
        adapter.getAssetPrice(token);

        vm.warp(block.timestamp + 1);
        _push(1, 0, 30, uint64(block.timestamp));
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_Pyth_RejectsPriceThatScalesToZero() public {
        feed.setBroken(true);
        _push(1, 0, -18, uint64(block.timestamp)); // 1e-18 USD -> 0 with 8 decimals
        _expectNoPrice();
        adapter.getAssetPrice(token);
    }

    function test_PythOnlyAsset() public {
        address pythOnly = makeAddr("pythOnly");
        vm.prank(owner);
        adapter.setAssetConfig(pythOnly, address(0), 0, PRICE_ID, PYTH_AGE, MAX_CONF_BPS);
        _push(2_000e8, 1e8, -8, uint64(block.timestamp));

        (uint256 price, OracleAdapter.Source source) = adapter.getAssetPriceWithSource(pythOnly);
        assertEq(price, 2_000e8);
        assertEq(uint8(source), uint8(OracleAdapter.Source.Pyth));
    }

    // --- L2 sequencer ---

    function test_Sequencer_NoFeedMeansNoCheck() public view {
        assertEq(adapter.getAssetPrice(token), 2_000e8);
    }

    function test_Sequencer_DownReverts() public {
        (OracleAdapter a, MockAggregator seq) = _adapterWithSequencer();
        seq.set(1);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        a.getAssetPrice(token);
    }

    function test_Sequencer_GracePeriod() public {
        (OracleAdapter a, MockAggregator seq) = _adapterWithSequencer();
        seq.set(0); // up since now

        vm.expectRevert(OracleAdapter.SequencerGracePeriodNotOver.selector);
        a.getAssetPrice(token);

        feed.set(2_000e8);
        vm.warp(block.timestamp + a.SEQUENCER_GRACE_PERIOD() - 1);
        feed.set(2_000e8);
        vm.expectRevert(OracleAdapter.SequencerGracePeriodNotOver.selector);
        a.getAssetPrice(token);

        vm.warp(block.timestamp + 1);
        feed.set(2_000e8);
        assertEq(a.getAssetPrice(token), 2_000e8);
    }

    function test_Sequencer_InvalidRoundReverts() public {
        (OracleAdapter a, MockAggregator seq) = _adapterWithSequencer();
        seq.setRaw(1, 0, 0, 0, 1); // startedAt == 0
        vm.expectRevert(OracleAdapter.SequencerGracePeriodNotOver.selector);
        a.getAssetPrice(token);
    }

    // --- helpers ---

    function _adapterWithSequencer() internal returns (OracleAdapter a, MockAggregator seq) {
        seq = new MockAggregator(0, 0);
        a = new OracleAdapter(owner, address(pyth), address(seq));
        vm.prank(owner);
        a.setAssetConfig(token, address(feed), STALENESS, PRICE_ID, PYTH_AGE, MAX_CONF_BPS);
    }

    function _configChainlinkOnly(address f) internal {
        vm.prank(owner);
        adapter.setAssetConfig(token, f, STALENESS, bytes32(0), 0, 0);
    }

    function _expectNoPrice() internal {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoValidPrice.selector, token));
    }

    function _push(int64 price, uint64 conf, int32 expo, uint64 publishTime) internal {
        bytes[] memory data = new bytes[](1);
        data[0] = pyth.createPriceFeedUpdateData(PRICE_ID, price, conf, expo, price, conf, publishTime);
        pyth.updatePriceFeeds{value: pyth.getUpdateFee(data)}(data);
    }
}
