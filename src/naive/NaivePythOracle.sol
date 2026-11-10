// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title NaivePythOracle
/// @notice INTENTIONALLY NAIVE. Educational only, never use it to value assets.
/// @dev Flaws: uses `getPriceUnsafe`, which returns the last price however old it is, and returns the confidence
///      interval and exponent without ever looking at them (a price of 100 +/- 100 is "valid"). `OracleAdapter`
///      uses `getPriceNoOlderThan` and bounds the confidence interval.
contract NaivePythOracle {
    /// @notice Pyth contract.
    IPyth public immutable pyth;
    /// @notice Pyth price id consumed by this contract.
    bytes32 public immutable priceId;

    /// @param pythContract Pyth contract of the chain
    /// @param id Pyth price feed id
    constructor(address pythContract, bytes32 id) {
        pyth = IPyth(pythContract);
        priceId = id;
    }

    /// @notice Last price, with no recency or confidence check.
    function getLatestPrice() external view returns (int64 price, uint64 conf, int32 expo) {
        // Reading the price without checking `publishTime` or `conf` is the flaw this contract demonstrates.
        // slither-disable-next-line pyth-unchecked-confidence,pyth-unchecked-publishtime
        PythStructs.Price memory p = pyth.getPriceUnsafe(priceId);
        return (p.price, p.conf, p.expo);
    }
}
