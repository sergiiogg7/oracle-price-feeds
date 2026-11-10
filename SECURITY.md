# Security

## Status

**This project has not been audited by any external party.** It is an educational portfolio project. Do not use it with real funds.

The contracts in `src/naive/` are **intentionally naive** and must never be used to value assets. Only `src/oracles/OracleAdapter.sol` is meant to show a sound design.

## Measures in `OracleAdapter`

| Measure | Where | Mitigates |
|---|---|---|
| `answer > 0` and non-zero result after scaling | `_tryChainlink`, `_tryPyth` | Zero or negative prices valuing collateral or debt at nothing |
| Per-asset `chainlinkMaxStaleness` | `_tryChainlink` | A frozen feed returning its last price forever |
| `updatedAt != 0`, not in the future, `answeredInRound >= roundId` | `_tryChainlink` | Incomplete or carried-over rounds |
| Feed `decimals()` read at configuration time and normalized to 8 | `setAssetConfig`, `_scale` | Mixing 6, 8 and 18 decimal feeds |
| Pyth `getPriceNoOlderThan` with `pythMaxAge` | `_tryPyth` | Stale Pyth prices |
| Pyth confidence interval bounded by `pythMaxConfidenceBps` | `_tryPyth` | Prices the oracle itself marks as uncertain |
| Pyth exponent normalization with magnitude limit | `_tryPyth` | Wrong scale, `10 ** n` overflow |
| `try/catch` around both sources | `_tryChainlink`, `_tryPyth` | A broken or reverting source taking the protocol down when the other is healthy |
| Revert `NoValidPrice` instead of returning 0 | `getAssetPriceWithSource` | Callers valuing assets with an invalid price |
| L2 sequencer uptime feed plus 1 h grace period | `_requireSequencerUp` | Stale prices right after a sequencer outage |
| `Ownable2Step`, zero-address and config validation | contract | Wrong owner, inconsistent configuration |

No `ReentrancyGuard` and no `SafeERC20`: the adapter only reads (`view`), moves no ETH or tokens and keeps no per-call state.

## Invariants (tested, with mutation checks)

- `getAssetPrice` never returns zero.
- A Chainlink price older than `maxStaleness` is never returned.
- A Pyth price older than `maxAge` is never returned.

## Design notes and limitations

- **Trust in the feeds.** The adapter validates freshness and sanity, not correctness: a Chainlink or Pyth feed that publishes a wrong but fresh price is trusted. There is no deviation check between sources (when Chainlink is valid, Pyth is not read). A circuit breaker comparing both and reverting above a threshold would be a natural extension.
- **Fallback hides a Chainlink outage.** `getAssetPriceWithSource` tells which source answered; consumers or monitoring should alert when Pyth is used.
- **Pyth needs pushed updates.** If nobody submits an update, Pyth reads fail and, with Chainlink also invalid, the call reverts (fail closed).
- **Owner power.** The owner can reconfigure or remove any asset immediately, including pointing it to a malicious feed. A real deployment needs a multisig and a timelock (the `lending-protocol` governance delay is the model).
- **Feed addresses are not verified on-chain.** `setAssetConfig` reads `decimals()` but cannot know a feed is the right pair. The configuration must be reviewed against Chainlink's and Pyth's registries.
- **Absurd answers fail closed.** A Chainlink answer large enough to overflow the scaling multiplication reverts the whole call.
- **`answeredInRound` is a legacy field.** Kept as a cheap sanity check; freshness relies on `updatedAt`.
- **Time.** Staleness and grace period use `block.timestamp`; a validator skew of seconds is irrelevant against windows of minutes or hours. Slither's `timestamp` detector is silenced inline with this reason.
- **Pair type.** Prices are per USD feed. Assets priced through another asset (for example stETH/ETH) are not supported.

## Tooling

Slither runs in CI with `fail-on: low`. Silenced findings, all inline with a comment: `unused-return` (only some fields of `latestRoundData` are needed), `pyth-unchecked-confidence` in the adapter (the confidence **is** checked, with a different formula), `timestamp` (see above), and the `unused-return`/`pyth-unchecked-*` findings in `src/naive/` (they are the flaws being demonstrated).

## Reporting a vulnerability

Use a private GitHub security advisory on this repository. Do not open a public issue for a vulnerability in `OracleAdapter`. Findings in `src/naive/` are known by design.
