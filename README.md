# Chainlink Price Feeds

[![CI](https://github.com/sergiiogg7/chainlink-price-feeds/actions/workflows/test.yml/badge.svg)](https://github.com/sergiiogg7/chainlink-price-feeds/actions/workflows/test.yml) ![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636) ![Foundry](https://img.shields.io/badge/Foundry-1.7.1-orange) ![Tests](https://img.shields.io/badge/tests-32-brightgreen)

A price oracle is the most attacked dependency of a DeFi protocol: a stale, zero or negative price lets an attacker borrow without collateral or liquidate healthy positions. This repo contains a **production-style `IPriceOracle` implementation on top of Chainlink price feeds**: staleness, round, decimals and L2 sequencer checks, and a revert instead of ever returning zero.

> **Status:** educational portfolio project, **not audited**. See [`SECURITY.md`](SECURITY.md).

Sibling project: [`pyth-price-feeds`](https://github.com/sergiiogg7/pyth-price-feeds) does the same for Pyth. Both implement the same `IPriceOracle` and are independent; combining them (primary plus fallback) is left to the consumer.

## What it does

[`ChainlinkOracle`](src/oracles/ChainlinkOracle.sol) implements the `IPriceOracle` interface used by `lending-protocol` (`getAssetPrice(token)` returns the USD price of one whole token, 8 decimals, and **reverts instead of returning 0**).

```text
getAssetPrice(token)
  |
  +-- token configured? ------------------------------------------------ no --> revert AssetNotConfigured
  |
  +-- L2 sequencer feed set? --> down or inside the 1 h grace period ---------> revert SequencerDown / SequencerGracePeriodNotOver
  |
  +-- feed reverts? ---------------------------------------------------- yes --> revert NoValidPrice
  +-- answer <= 0? ----------------------------------------------------- yes --> revert NoValidPrice
  +-- updatedAt = 0, in the future or older than maxStaleness? --------- yes --> revert NoValidPrice
  +-- answeredInRound < roundId? --------------------------------------- yes --> revert NoValidPrice
  +-- result rounds to 0 after scaling? -------------------------------- yes --> revert NoValidPrice
  |
  +-- return answer normalized to 8 decimals
```

Each configured asset has its own `maxStaleness` (`setAssetConfig`): use the feed's heartbeat plus a margin (ETH/USD is 1 h, a stablecoin may be 24 h).

## Why the checks matter

| Flaw (typical tutorial code) | What goes wrong | What `ChainlinkOracle` does |
|---|---|---|
| No staleness check | A frozen feed keeps returning its last price | Rejects answers older than `maxStaleness` |
| Returning `0` or negative answers | Collateral or debt valued at nothing, broken casts to `uint256` | Requires `answer > 0` and a non-zero result after scaling |
| Ignoring feed decimals | Prices off by powers of ten (6, 8 and 18 decimal feeds exist) | Reads `decimals()` once and normalizes to 8 |
| Ignoring the L2 sequencer | Stale prices accepted right after a sequencer outage | Sequencer uptime feed plus a 1 h grace period |
| Trusting `latestRoundData` not to revert | One broken feed takes the protocol down | `try/catch`, mapped to `NoValidPrice` |

## Run it

```bash
git clone --recurse-submodules <repo-url>
cd chainlink-price-feeds
forge build
forge test                                   # 32 tests (+1 skipped fork test)
FOUNDRY_PROFILE=ci forge test                # 5000 fuzz runs, 512x256 invariants
forge coverage --no-match-coverage "script|test" --report summary   # 100 % lines in src/
```

Fork test against the real Chainlink ETH/USD feed on Sepolia (optional, skipped without an RPC):

```bash
SEPOLIA_RPC_URL=<url> forge test --match-contract ChainlinkOracleForkTest -vv
```

Deploy and configure (Sepolia example):

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
cast send <oracle> "setAssetConfig(address,address,uint32)" \
  <token> 0x694AA1769357215DE4FAC081bf1f309aDC325306 3600 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## Tests

| File | Content |
|---|---|
| `test/ChainlinkOracle.t.sol` | Configuration and every custom error, ownership, price checks and boundaries, decimal scaling, sequencer |
| `test/ChainlinkOracleFuzz.t.sol` | Decimal scaling, staleness boundary, non-positive answers, "never returns zero" |
| `test/ChainlinkOracleInvariant.t.sol` | Under random feed updates, breakage and time: never a zero price, never a stale price |
| `test/fork/ChainlinkOracleFork.t.sol` | Real Sepolia ETH/USD feed through the oracle (optional) |

The stale-price invariant was checked by mutation: removing the staleness check makes it fail.

## Layout

```text
src/oracles/ChainlinkOracle.sol     the oracle
src/interfaces/                     IPriceOracle (same as lending-protocol), AggregatorV3Interface, ISequencerUptimeFeed
test/mocks/MockAggregator.sol       controllable Chainlink feed
script/Deploy.s.sol                 deployment from environment variables
```

`IPriceOracle` and the decimal scaling helper are duplicated in the sibling repo on purpose: two independent repos are simpler to read, deploy and audit than a shared library.

## Origin

Started from a course workshop (`Bloque-18`) with four contracts (basic and "checks" versions for Chainlink and Pyth, no tests). The Chainlink oracle, the sequencer check, the decimal normalization, the invariants and the fork test are new. The Pyth part lives in `pyth-price-feeds`.
