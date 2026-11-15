// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AggregatorV3Interface
/// @notice Minimal subset of Chainlink's `AggregatorV3Interface`, kept local to avoid importing the whole
///         Chainlink repository. The function signatures are identical to the official interface.
interface AggregatorV3Interface {
    /// @notice Number of decimals of the answers returned by the feed.
    function decimals() external view returns (uint8);

    /// @notice Latest round data.
    /// @return roundId Round id
    /// @return answer Price (the L2 sequencer uptime feed is read through `ISequencerUptimeFeed`)
    /// @return startedAt Timestamp when the round started
    /// @return updatedAt Timestamp of the last update
    /// @return answeredInRound Round in which the answer was computed (legacy field)
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
