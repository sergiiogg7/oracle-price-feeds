// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ISequencerUptimeFeed
/// @notice Minimal view of Chainlink's L2 sequencer uptime feed. It is read through the same `latestRoundData`
///         function as a price feed (the signature is identical to `AggregatorV3Interface`), but the data means
///         something else: it reports whether the L2 sequencer is running, not a price. It has no `decimals()` use.
interface ISequencerUptimeFeed {
    /// @notice Latest status of the sequencer.
    /// @return roundId Round id
    /// @return answer Sequencer status: 0 = up, 1 = down
    /// @return startedAt Timestamp when the status last changed (0 means an invalid round)
    /// @return updatedAt Timestamp of the last update (not used by `OracleAdapter`)
    /// @return answeredInRound Round in which the answer was computed (not used by `OracleAdapter`)
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
