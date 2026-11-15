# Security

## Status

**This project has not been audited by any external party.** It is an educational portfolio project. Do not use it with real funds.

## Measures in `ChainlinkOracle`

| Measure | Where | Mitigates |
|---|---|---|
| `answer > 0` and non-zero result after scaling | `_tryChainlink` | Zero or negative prices valuing collateral or debt at nothing |
| Per-asset `maxStaleness` | `_tryChainlink` | A frozen feed returning its last price forever |
| `updatedAt != 0`, not in the future, `answeredInRound >= roundId` | `_tryChainlink` | Incomplete or carried-over rounds |
| Feed `decimals()` read at configuration time and normalized to 8 | `setAssetConfig`, `_scale` | Mixing 6, 8 and 18 decimal feeds |
| `try/catch` around the feed | `_tryChainlink` | A broken or reverting feed surfacing as an opaque revert; it becomes `NoValidPrice` |
| Revert `NoValidPrice` instead of returning 0 | `getAssetPrice` | Callers valuing assets with an invalid price |
| L2 sequencer uptime feed plus 1 h grace period | `_requireSequencerUp` | Stale prices right after a sequencer outage |
| `Ownable2Step`, zero-address and config validation | contract | Wrong owner, inconsistent configuration |

No `ReentrancyGuard` and no `SafeERC20`: the oracle only reads (`view`), moves no ETH or tokens and keeps no per-call state.

## Invariants (tested, with mutation check)

- `getAssetPrice` never returns zero.
- A price older than `maxStaleness` is never returned (checked by mutation: removing the staleness check breaks it).

## Design notes and limitations

- **Trust in the feed.** The oracle validates freshness and sanity, not correctness: a Chainlink feed that publishes a wrong but fresh price is trusted. There is no second source to compare with. `pyth-price-feeds` is a sibling oracle that a consumer can combine with this one.
- **Owner power.** The owner can reconfigure or remove any asset immediately, including pointing it to a malicious feed. A real deployment needs a multisig and a timelock (the `lending-protocol` governance delay is the model).
- **Feed addresses are not verified on-chain.** `setAssetConfig` reads `decimals()` but cannot know a feed is the right pair. The configuration must be reviewed against Chainlink's registry.
- **Absurd answers fail closed.** An answer large enough to overflow the scaling multiplication reverts the whole call.
- **`answeredInRound` is a legacy field.** Kept as a cheap sanity check; freshness relies on `updatedAt`.
- **Time.** Staleness and grace period use `block.timestamp`; a validator skew of seconds is irrelevant against windows of minutes or hours. Slither's `timestamp` detector is silenced inline with this reason.
- **Pair type.** Prices are per USD feed. Assets priced through another asset (for example stETH/ETH) are not supported.

## Tooling

Slither runs in CI with `fail-on: low`. Silenced findings, all inline with a comment: `unused-return` (only some fields of `latestRoundData` are needed) and `timestamp` (see above).

## Reporting a vulnerability

Use a private GitHub security advisory on this repository. Do not open a public issue for a vulnerability in `ChainlinkOracle`.
