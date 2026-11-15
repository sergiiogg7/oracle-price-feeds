// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ISequencerUptimeFeed} from "../interfaces/ISequencerUptimeFeed.sol";

/// @title ChainlinkOracle
/// @notice `IPriceOracle` implementation backed by a Chainlink USD price feed per token.
/// @dev Returns the USD price (8 decimals) of ONE WHOLE token, as `lending-protocol` expects. It NEVER returns zero:
///      when the feed does not give a valid price it reverts, so the caller cannot value an asset with a bad price.
///
///      Checks (each one is a real incident class):
///        - `answer > 0` (feeds can return zero or negative values)
///        - `updatedAt` not zero, not in the future and not older than `maxStaleness` (a frozen feed keeps
///          returning its last answer)
///        - `answeredInRound >= roundId` (legacy check for carried-over answers)
///        - the result, once normalized to 8 decimals, is still above zero
///        - optional L2 sequencer uptime feed plus a grace period after it comes back
contract ChainlinkOracle is IPriceOracle, Ownable2Step {
    /// @notice Per-token configuration. `feed == address(0)` means "not configured".
    /// @dev `decimals` is read from the feed once, in `setAssetConfig`.
    struct AssetConfig {
        AggregatorV3Interface feed;
        uint32 maxStaleness;
        uint8 decimals;
    }

    /// @notice Decimals of the prices returned by this oracle (Chainlink USD convention).
    uint8 public constant PRICE_DECIMALS = 8;
    /// @notice Time that must pass after the L2 sequencer comes back before prices are trusted again.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    /// @notice Maximum accepted feed decimals, keeps `10 ** n` far from overflow.
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice Chainlink L2 sequencer uptime feed (zero on L1).
    ISequencerUptimeFeed public immutable sequencerUptimeFeed;

    mapping(address token => AssetConfig config) private _configs;

    /// @notice Emitted when the configuration of `token` is set.
    event AssetConfigured(address indexed token, address feed, uint32 maxStaleness);
    /// @notice Emitted when `token` is removed.
    event AssetRemoved(address indexed token);

    /// @notice A zero address was supplied.
    error ZeroAddress();
    /// @notice The configuration is inconsistent (see `setAssetConfig`).
    error InvalidConfig();
    /// @notice `token` has no configuration.
    error AssetNotConfigured(address token);
    /// @notice The feed of `token` did not return a valid price.
    error NoValidPrice(address token);
    /// @notice The L2 sequencer is down.
    error SequencerDown();
    /// @notice The L2 sequencer came back less than `SEQUENCER_GRACE_PERIOD` ago.
    error SequencerGracePeriodNotOver();

    /// @param initialOwner Owner (configures assets)
    /// @param sequencerUptimeFeed_ Chainlink L2 sequencer uptime feed, or zero on L1
    constructor(address initialOwner, address sequencerUptimeFeed_) Ownable(initialOwner) {
        sequencerUptimeFeed = ISequencerUptimeFeed(sequencerUptimeFeed_);
    }

    /// @notice Configures the Chainlink feed of `token`.
    /// @param token Token to price (the address `getAssetPrice` receives)
    /// @param feed Chainlink USD feed (must not be zero)
    /// @param maxStaleness Max age in seconds of an answer, must not be zero (use the feed heartbeat plus a margin)
    function setAssetConfig(address token, address feed, uint32 maxStaleness) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxStaleness == 0) revert InvalidConfig();

        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        if (feedDecimals > MAX_DECIMALS) revert InvalidConfig();

        _configs[token] =
            AssetConfig({feed: AggregatorV3Interface(feed), maxStaleness: maxStaleness, decimals: feedDecimals});
        emit AssetConfigured(token, feed, maxStaleness);
    }

    /// @notice Removes the configuration of `token`; its price can no longer be read.
    function removeAsset(address token) external onlyOwner {
        if (address(_configs[token].feed) == address(0)) revert AssetNotConfigured(token);
        delete _configs[token];
        emit AssetRemoved(token);
    }

    /// @notice Returns the configuration of `token`.
    function getAssetConfig(address token) external view returns (AssetConfig memory) {
        return _configs[token];
    }

    /// @inheritdoc IPriceOracle
    /// @dev Reverts with `AssetNotConfigured`, a sequencer error or `NoValidPrice`.
    function getAssetPrice(address token) external view returns (uint256 price) {
        AssetConfig memory cfg = _configs[token];
        if (address(cfg.feed) == address(0)) revert AssetNotConfigured(token);

        _requireSequencerUp();

        bool ok;
        (ok, price) = _tryChainlink(cfg);
        if (!ok) revert NoValidPrice(token);
    }

    /// @dev Reverts if the L2 sequencer is down or came back less than `SEQUENCER_GRACE_PERIOD` ago.
    function _requireSequencerUp() internal view {
        if (address(sequencerUptimeFeed) == address(0)) return;
        // Only `answer` and `startedAt` matter for the sequencer feed.
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        // answer 0 = up, 1 = down. startedAt is when the status last changed (0 means an invalid round).
        if (answer != 0) revert SequencerDown();
        // Grace period: the feeds were not updated while the sequencer was down. Wait until they catch up.
        // slither-disable-next-line timestamp
        if (startedAt == 0 || block.timestamp < startedAt + SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriodNotOver();
        }
    }

    function _tryChainlink(AssetConfig memory cfg) internal view returns (bool ok, uint256 price) {
        // `startedAt` is not needed: freshness is judged with `updatedAt`.
        // slither-disable-next-line unused-return
        try cfg.feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (false, 0);
            if (updatedAt == 0 || answeredInRound < roundId) return (false, 0);
            // A timestamp in the future is also invalid. A feed cannot update ahead of the chain.
            // slither-disable-next-line timestamp
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.maxStaleness) {
                return (false, 0);
            }
            // Decimal places to add (+) or remove (-) to go from the feed's decimals to PRICE_DECIMALS.
            // Feed with 18 decimals: 8 - 18 = -10 -> divide by 1e10.
            // Feed with 6 decimals:  8 - 6  = +2  -> multiply by 1e2.
            // Feed with 8 decimals:  8 - 8  =  0  -> unchanged.
            // casting is safe: both values are at most `MAX_DECIMALS` (checked in `setAssetConfig`)
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 decimalsToAdd = int256(uint256(PRICE_DECIMALS)) - int256(uint256(cfg.decimals));
            // casting is safe: `answer > 0` was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            price = _scale(uint256(answer), decimalsToAdd);
            return (price != 0, price);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Moves `value` to a scale with `decimalsToAdd` more decimals (fewer when it is negative):
    ///      multiplies by `10 ** decimalsToAdd`, or divides by `10 ** -decimalsToAdd` (truncating the remainder).
    ///      `|decimalsToAdd| <= MAX_DECIMALS`.
    ///
    ///      | decimalsToAdd | Operation       | Example (value -> result) |
    ///      |---------------|-----------------|---------------------------|
    ///      | +2            | value * 10**2   | 2000_123456 -> 2000_12345600 |
    ///      |  0            | unchanged       | 2000_12345678 -> 2000_12345678 |
    ///      | -10           | value / 10**10  | 2000_123456789012345678 -> 2000_12345678 |
    function _scale(uint256 value, int256 decimalsToAdd) internal pure returns (uint256) {
        if (decimalsToAdd >= 0) {
            // casting is safe: `decimalsToAdd >= 0`
            // forge-lint: disable-next-line(unsafe-typecast)
            return value * 10 ** uint256(decimalsToAdd);
        }
        // casting is safe: `-decimalsToAdd > 0`
        // forge-lint: disable-next-line(unsafe-typecast)
        return value / 10 ** uint256(-decimalsToAdd);
    }
}
