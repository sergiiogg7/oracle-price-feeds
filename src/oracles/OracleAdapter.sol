// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title OracleAdapter
/// @notice `IPriceOracle` implementation with Chainlink as the primary source and Pyth as the fallback.
/// @dev Returns the USD price (8 decimals) of ONE WHOLE token, as `lending-protocol` expects. It NEVER returns zero:
///      when no source gives a valid price it reverts, so the caller cannot value an asset with a bad price.
///
///      Chainlink checks (each one is a real incident class, see `src/naive/` and the exploit tests):
///        - `answer > 0` (feeds can return zero or negative values)
///        - `updatedAt` not zero and not older than `maxStaleness` (a frozen feed keeps returning its last answer)
///        - `answeredInRound >= roundId` (legacy check for carried-over answers)
///        - the result, once normalized to 8 decimals, is still above zero
///        - optional L2 sequencer uptime feed plus a grace period after it comes back
///
///      Pyth checks: `getPriceNoOlderThan` (reverts on stale prices), `price > 0`, confidence interval below
///      `maxConfidenceBps` of the price, and exponent normalization.
///
///      Pyth prices are pushed: anyone can call `IPyth.updatePriceFeeds` (with the Wormhole update data and the fee)
///      directly on the Pyth contract. This adapter only reads, so `getAssetPrice` stays a `view`.
contract OracleAdapter is IPriceOracle, Ownable2Step {
    /// @notice Which source produced a price.
    enum Source {
        Chainlink,
        Pyth
    }

    /// @notice Per-token configuration.
    /// @dev `chainlinkFeed == address(0)` disables Chainlink and `pythPriceId == bytes32(0)` disables Pyth.
    struct AssetConfig {
        AggregatorV3Interface chainlinkFeed;
        uint32 chainlinkMaxStaleness;
        uint8 chainlinkDecimals;
        bytes32 pythPriceId;
        uint32 pythMaxAge;
        uint16 pythMaxConfidenceBps;
    }

    /// @notice Decimals of the prices returned by this oracle (Chainlink USD convention).
    uint8 public constant PRICE_DECIMALS = 8;
    /// @notice Time that must pass after the L2 sequencer comes back before prices are trusted again.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    /// @notice Upper bound of `pythMaxConfidenceBps` (100 %).
    uint16 public constant MAX_BPS = 10_000;
    /// @notice Maximum accepted decimals / exponent magnitude, keeps `10 ** n` far from overflow.
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice Pyth contract of the chain (zero if Pyth is not used).
    IPyth public immutable pyth;
    /// @notice Chainlink L2 sequencer uptime feed (zero on L1).
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    mapping(address token => AssetConfig config) private _configs;

    /// @notice Emitted when the configuration of `token` is set.
    event AssetConfigured(
        address indexed token,
        address chainlinkFeed,
        uint32 chainlinkMaxStaleness,
        bytes32 pythPriceId,
        uint32 pythMaxAge,
        uint16 pythMaxConfidenceBps
    );
    /// @notice Emitted when `token` is removed.
    event AssetRemoved(address indexed token);

    /// @notice A zero address was supplied.
    error ZeroAddress();
    /// @notice The configuration is inconsistent (see `setAssetConfig`).
    error InvalidConfig();
    /// @notice `token` has no configuration.
    error AssetNotConfigured(address token);
    /// @notice No configured source returned a valid price for `token`.
    error NoValidPrice(address token);
    /// @notice The L2 sequencer is down.
    error SequencerDown();
    /// @notice The L2 sequencer came back less than `SEQUENCER_GRACE_PERIOD` ago.
    error SequencerGracePeriodNotOver();

    /// @param initialOwner Owner (configures assets)
    /// @param pyth_ Pyth contract, or zero when Pyth is not used
    /// @param sequencerUptimeFeed_ Chainlink L2 sequencer uptime feed, or zero on L1
    constructor(address initialOwner, address pyth_, address sequencerUptimeFeed_) Ownable(initialOwner) {
        pyth = IPyth(pyth_);
        sequencerUptimeFeed = AggregatorV3Interface(sequencerUptimeFeed_);
    }

    /// @notice Configures the price sources of `token`.
    /// @param token Token to price (the address `getAssetPrice` receives)
    /// @param chainlinkFeed Chainlink USD feed, or zero to disable Chainlink
    /// @param chainlinkMaxStaleness Max age in seconds of a Chainlink answer (use the feed heartbeat plus a margin)
    /// @param pythPriceId Pyth price id, or zero to disable Pyth
    /// @param pythMaxAge Max age in seconds of a Pyth price
    /// @param pythMaxConfidenceBps Max `conf / price` ratio in basis points (e.g. 100 = 1 %)
    function setAssetConfig(
        address token,
        address chainlinkFeed,
        uint32 chainlinkMaxStaleness,
        bytes32 pythPriceId,
        uint32 pythMaxAge,
        uint16 pythMaxConfidenceBps
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (chainlinkFeed == address(0) && pythPriceId == bytes32(0)) revert InvalidConfig();

        uint8 feedDecimals = 0;
        if (chainlinkFeed != address(0)) {
            if (chainlinkMaxStaleness == 0) revert InvalidConfig();
            feedDecimals = AggregatorV3Interface(chainlinkFeed).decimals();
            if (feedDecimals > MAX_DECIMALS) revert InvalidConfig();
        }
        if (pythPriceId != bytes32(0)) {
            if (address(pyth) == address(0) || pythMaxAge == 0) revert InvalidConfig();
            if (pythMaxConfidenceBps == 0 || pythMaxConfidenceBps > MAX_BPS) revert InvalidConfig();
        }

        _configs[token] = AssetConfig({
            chainlinkFeed: AggregatorV3Interface(chainlinkFeed),
            chainlinkMaxStaleness: chainlinkMaxStaleness,
            chainlinkDecimals: feedDecimals,
            pythPriceId: pythPriceId,
            pythMaxAge: pythMaxAge,
            pythMaxConfidenceBps: pythMaxConfidenceBps
        });
        emit AssetConfigured(token, chainlinkFeed, chainlinkMaxStaleness, pythPriceId, pythMaxAge, pythMaxConfidenceBps);
    }

    /// @notice Removes the configuration of `token`; its price can no longer be read.
    function removeAsset(address token) external onlyOwner {
        if (_configs[token].chainlinkFeed == AggregatorV3Interface(address(0)) && _configs[token].pythPriceId == 0) {
            revert AssetNotConfigured(token);
        }
        delete _configs[token];
        emit AssetRemoved(token);
    }

    /// @notice Returns the configuration of `token`.
    function getAssetConfig(address token) external view returns (AssetConfig memory) {
        return _configs[token];
    }

    /// @inheritdoc IPriceOracle
    function getAssetPrice(address token) external view returns (uint256 price) {
        (price,) = getAssetPriceWithSource(token);
    }

    /// @notice Same as `getAssetPrice`, also telling which source produced the price.
    /// @dev Reverts with `NoValidPrice` when every configured source is invalid.
    function getAssetPriceWithSource(address token) public view returns (uint256 price, Source source) {
        AssetConfig memory cfg = _configs[token];
        bool hasChainlink = address(cfg.chainlinkFeed) != address(0);
        bool hasPyth = cfg.pythPriceId != bytes32(0);
        if (!hasChainlink && !hasPyth) revert AssetNotConfigured(token);

        _requireSequencerUp();

        bool ok;
        if (hasChainlink) {
            (ok, price) = _tryChainlink(cfg);
            if (ok) return (price, Source.Chainlink);
        }
        if (hasPyth) {
            (ok, price) = _tryPyth(cfg);
            if (ok) return (price, Source.Pyth);
        }
        revert NoValidPrice(token);
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
        try cfg.chainlinkFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (false, 0);
            if (updatedAt == 0 || answeredInRound < roundId) return (false, 0);
            // A timestamp in the future is also invalid. A feed cannot update ahead of the chain.
            // slither-disable-next-line timestamp
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.chainlinkMaxStaleness) {
                return (false, 0);
            }
            // casting is safe: `answer > 0` was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            price = _scale(uint256(answer), int256(uint256(PRICE_DECIMALS)) - int256(uint256(cfg.chainlinkDecimals)));
            return (price != 0, price);
        } catch {
            return (false, 0);
        }
    }

    function _tryPyth(AssetConfig memory cfg) internal view returns (bool ok, uint256 price) {
        // The confidence interval IS checked below (`p.conf * MAX_BPS > rawPrice * maxConfidenceBps`).
        // slither-disable-next-line pyth-unchecked-confidence
        try pyth.getPriceNoOlderThan(cfg.pythPriceId, cfg.pythMaxAge) returns (PythStructs.Price memory p) {
            if (p.price <= 0) return (false, 0);
            // casting is safe: `p.price > 0` was checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 rawPrice = uint256(uint64(p.price));
            // Confidence interval too wide relative to the price: the oracle itself says it is unsure.
            if (uint256(p.conf) * MAX_BPS > rawPrice * cfg.pythMaxConfidenceBps) return (false, 0);
            // Real price = rawPrice * 10^expo. Target scale: 10^-PRICE_DECIMALS.
            int256 shift = int256(p.expo) + int256(uint256(PRICE_DECIMALS));
            if (shift > int256(uint256(MAX_DECIMALS)) || shift < -int256(uint256(MAX_DECIMALS))) return (false, 0);
            price = _scale(rawPrice, shift);
            return (price != 0, price);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Multiplies `value` by `10 ** shift` (divides when `shift` is negative). `|shift| <= MAX_DECIMALS`.
    function _scale(uint256 value, int256 shift) internal pure returns (uint256) {
        if (shift >= 0) {
            // casting is safe: `shift >= 0`
            // forge-lint: disable-next-line(unsafe-typecast)
            return value * 10 ** uint256(shift);
        }
        // casting is safe: `-shift > 0`
        // forge-lint: disable-next-line(unsafe-typecast)
        return value / 10 ** uint256(-shift);
    }
}
