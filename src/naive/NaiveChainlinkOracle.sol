// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title NaiveChainlinkOracle
/// @notice INTENTIONALLY NAIVE. Educational only, never use it to value assets.
/// @dev Flaws: returns the answer of `latestRoundData` with no checks. A frozen feed keeps returning its last answer
///      (no staleness check), and a zero or negative answer is returned as is. It also ignores the feed decimals and
///      the L2 sequencer status. `OracleAdapter` fixes all of them.
contract NaiveChainlinkOracle {
    /// @notice Price feed consumed by this contract.
    AggregatorV3Interface public immutable priceFeed;

    /// @param feed Chainlink aggregator, e.g. ETH/USD on Sepolia 0x694AA1769357215DE4FAC081bf1f309aDC325306
    constructor(address feed) {
        priceFeed = AggregatorV3Interface(feed);
    }

    /// @notice Latest answer, unchecked.
    function getLatestPrice() external view returns (int256 price) {
        // Ignoring the rest of the round data is the flaw this contract demonstrates.
        // slither-disable-next-line unused-return
        (, price,,,) = priceFeed.latestRoundData();
    }
}
