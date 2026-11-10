# Oracle Price Feeds

[![CI](https://github.com/sergiiogg7/oracle-price-feeds/actions/workflows/test.yml/badge.svg)](https://github.com/sergiiogg7/oracle-price-feeds/actions/workflows/test.yml) ![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636) ![Foundry](https://img.shields.io/badge/Foundry-1.7.1-orange) ![Tests](https://img.shields.io/badge/tests-56-brightgreen)

A price oracle is the most attacked dependency of a DeFi protocol: a stale, zero or manipulated price lets an attacker borrow without collateral or liquidate healthy positions. This repo contains a **production-style `IPriceOracle` adapter** (Chainlink as primary source, Pyth as fallback, L2 sequencer check) and, next to it, the **naive versions most tutorials show**, with the exploit that breaks each one.

> **Status:** educational portfolio project, **not audited**. See [`SECURITY.md`](SECURITY.md). The contracts in `src/naive/` are insecure on purpose.

## What it does

[`OracleAdapter`](src/oracles/OracleAdapter.sol) implements the `IPriceOracle` interface used by `lending-protocol` (`getAssetPrice(token)` returns the USD price of one whole token, 8 decimals, and **reverts instead of returning 0**).

```text
getAssetPrice(token)
  |
  +-- L2 sequencer feed configured? --> down or inside the 1 h grace period ----> revert
  |
  +-- Chainlink valid? (price > 0, fresh, round complete, scales to > 0) -------> return (decimals normalized to 8)
  |        | no
  +-- Pyth valid? (not older than maxAge, price > 0, confidence <= maxBps) -----> return (exponent normalized to 8)
  |        | no
  +-- revert NoValidPrice(token)
```

Each configured asset has its own limits (`setAssetConfig`): Chainlink `maxStaleness` (use the feed's heartbeat plus a margin: ETH/USD is 1 h, a stablecoin may be 24 h), Pyth `maxAge` and `maxConfidenceBps`.

## Naive vs adapter

| Naive contract | Flaw | Exploit test | Adapter |
|---|---|---|---|
| [`NaiveChainlinkOracle`](src/naive/NaiveChainlinkOracle.sol) | No staleness check: a frozen feed keeps returning its last price | `test_Exploit_NaiveChainlink_AcceptsStalePrice` | Rejects answers older than `maxStaleness` |
| same | Returns `0` and negative answers as prices | `..._ReturnsZero`, `..._ReturnsNegative` | Requires `answer > 0` and a non-zero result after scaling |
| [`NaivePythOracle`](src/naive/NaivePythOracle.sol) | `getPriceUnsafe`: a week-old price is "current" | `test_Exploit_NaivePyth_AcceptsOldPrice` | `getPriceNoOlderThan` with `maxAge` |
| same | Ignores the confidence interval (100 +/- 100 is valid) | `test_Exploit_NaivePyth_IgnoresWideConfidence` | Rejects `conf / price` above `maxConfidenceBps` |
| both | Ignore feed decimals / exponent and the L2 sequencer | decimals and sequencer tests | Normalizes to 8 decimals; sequencer uptime and grace period |

Also fixed relative to the original course version: the "checks" contract fell back to the secondary feed only on a **revert**, never when the primary price was stale (the `require`s inside the `try` block reverted the whole call), and it called `latestRoundData` twice.

## Why Chainlink first and Pyth second

- **Chainlink** pushes prices on-chain on a heartbeat/deviation basis: reading it is a plain `view`, no keeper needed.
- **Pyth** is pull-based: prices are only on-chain when someone submits the signed update (`IPyth.updatePriceFeeds`, paying a fee). As a *fallback* that is acceptable, because a protocol keeper or any user can push an update before the call. The adapter stays `view` and never handles ETH.

## Run it

```bash
git clone --recurse-submodules <repo-url>
cd oracle-price-feeds
forge build
forge test                                   # 56 tests (+1 skipped fork test)
FOUNDRY_PROFILE=ci forge test                # 5000 fuzz runs, 512x256 invariants
forge coverage --no-match-coverage "script|test" --report summary   # 100 % lines in src/
```

Fork test against the real Chainlink ETH/USD feed on Sepolia (optional, skipped without an RPC):

```bash
SEPOLIA_RPC_URL=<url> forge test --match-contract OracleAdapterForkTest -vv
```

Deploy and configure (Sepolia example):

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
cast send <adapter> "setAssetConfig(address,address,uint32,bytes32,uint32,uint16)" \
  <token> 0x694AA1769357215DE4FAC081bf1f309aDC325306 3600 <pythPriceId> 60 100 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## Tests

| File | Content |
|---|---|
| `test/NaiveOracles.t.sol` | Exploits against the naive contracts, each rejected by the adapter |
| `test/OracleAdapter.t.sol` | Configuration and every custom error, Chainlink checks and boundaries, Pyth fallback and normalization, sequencer |
| `test/OracleAdapterFuzz.t.sol` | Decimal scaling, staleness boundary, non-positive answers, Pyth exponent and confidence, "never returns zero" |
| `test/OracleAdapterInvariant.t.sol` | Under random Chainlink/Pyth updates, breakage and time: never a zero price, never a stale Chainlink price, never a stale Pyth price |
| `test/fork/OracleAdapterFork.t.sol` | Real Sepolia ETH/USD feed through the adapter (optional) |

The invariants were checked by mutation: removing the Chainlink staleness check, or switching Pyth to `getPriceUnsafe`, makes the matching invariant fail.

## Layout

```text
src/oracles/OracleAdapter.sol       Chainlink primary, Pyth fallback, sequencer check
src/interfaces/                     IPriceOracle (same as lending-protocol), minimal AggregatorV3Interface
src/naive/                          the two intentionally naive oracles
test/mocks/MockAggregator.sol       controllable Chainlink feed (Pyth uses its official MockPyth)
script/Deploy.s.sol                 deployment from environment variables
```

## Origin

Started from a course workshop with four contracts (basic and "checks" versions for Chainlink and Pyth, no tests). The adapter, the exploit tests, the sequencer check, the decimal normalization, the invariants and the fork test are new.
