// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Chainlink feed with fully controllable data, including a "broken" mode that reverts.
contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable decimals;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    bool public broken;

    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        set(initialAnswer);
    }

    /// @notice New round with `newAnswer`, updated now.
    function set(int256 newAnswer) public {
        roundId++;
        answeredInRound = roundId;
        answer = newAnswer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    /// @notice Overwrites every field of the latest round.
    function setRaw(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed broken");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
