# Plan

Origin: course workshop `Bloque-18` (Chainlink and Pyth oracles, basic and "checks" versions, no tests). Project type: reusable Chainlink `IPriceOracle` for `lending-protocol`; the Pyth part lives in `pyth-price-feeds`. No frontend.

| Date | Change |
|---|---|
| 2026-11-10 | Repo created with `forge init`, OpenZeppelin v5.4.0, Pyth SDK v2.2.0, pinned config, CI and Slither config. |
| 2026-11-10 | `OracleAdapter`: Chainlink primary and Pyth fallback behind the `IPriceOracle` of `lending-protocol`; staleness, round, confidence, exponent and decimal normalization, L2 sequencer check, `Ownable2Step`. Fixes the course fallback, which never triggered on stale prices. |
| 2026-11-10 | `src/naive/` kept the two naive oracles as contrast, each with an exploit test. |
| 2026-11-15 | `src/naive/` and `NaiveOracles.t.sol` removed: the repo keeps only the production-grade adapter. |
| 2026-11-10 | Tests: unit, exploits, fuzz, invariants checked by mutation, Sepolia fork test. 56 tests (+1 optional fork), 100 % line coverage, Slither 0 findings. First version of the invariants never exercised Pyth (handler had no ETH for the fee); found by reading the revert table and fixed. |
| 2026-11-10 | Real Sepolia check: ETH/USD read through the adapter (about 2035 USD), Pyth address has code. |
| 2026-11-15 | Split: Pyth moved to its own repo `pyth-price-feeds`. `OracleAdapter` renamed `ChainlinkOracle` (single source: no `Source` enum, no fallback, constructor `(owner, sequencerFeed)`, `setAssetConfig(token, feed, maxStaleness)`), Pyth submodule and remapping removed, invariants 3 to 2. 32 tests (+1 fork), 100 % coverage, Slither 0, stale invariant checked by mutation. |

## Pending

- Plug the oracle into `lending-protocol` (replace `MockPriceOracle` in `Deploy`) and run that repo's tests against it. Separate task, in that repo.
- Deploy to Sepolia and verify on Etherscan; configure a real asset.
- Optional: a `FallbackOracle(primary, secondary)` composing this oracle with `pyth-price-feeds`, with a deviation check and circuit breaker (separate task).
- Indirect pairs: support assets that only have a feed against another asset (for example stETH/ETH) by composing two feeds (stETH/ETH x ETH/USD, rescaled back to 8 decimals). `AssetConfig` would hold an optional second feed and each feed would pass its own checks; if either fails, revert. Listed as a limitation in `SECURITY.md` ("Pair type").
- Done 2026-11-10: first push, CI green, CI badge in README.
- GitHub About: "Chainlink-backed IPriceOracle in Solidity: rejects stale, zero and negative answers, normalizes decimals, checks the L2 sequencer, and reverts instead of returning 0. Tested with fuzz and invariants. Foundry."
- GitHub topics: `solidity`, `foundry`, `chainlink`, `oracle`, `price-feeds`, `defi`, `smart-contract-security`.
