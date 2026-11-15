# CLAUDE.md

Production-style price oracle adapter. Takes precedence over the parent folder `CLAUDE.md`.

## Commands

```bash
forge build && forge test                    # 49 tests, fork test skipped without SEPOLIA_RPC_URL
FOUNDRY_PROFILE=ci forge test                # exhaustive fuzz and invariants
forge fmt --check
forge coverage --no-match-coverage "script|test" --report summary
forge snapshot --check                       # run `forge snapshot` after intentional gas changes
slither . --exclude-dependencies --config-file slither.config.json --fail-low   # needs a venv, not installed globally
SEPOLIA_RPC_URL=<url> forge test --match-contract OracleAdapterForkTest -vv
```

## Architecture

- `src/oracles/OracleAdapter.sol`: `IPriceOracle` (same interface as `lending-protocol`): Chainlink first, Pyth second, sequencer check, revert instead of 0.
- `src/interfaces/`: `IPriceOracle` (copy of the lending one, keep both identical) a minimal `AggregatorV3Interface` (price feeds) and `ISequencerUptimeFeed` (L2 sequencer uptime feed, same `latestRoundData` signature, different meaning).
- Pyth comes from the `lib/pyth-sdk-solidity` submodule (v2.2.0) with remapping `@pythnetwork/pyth-sdk-solidity/`; tests use its `MockPyth`.

## Tests

`OracleAdapter.t.sol` (unit), `...Fuzz.t.sol`, `...Invariant.t.sol` (handler with ghost variables; the handler needs ETH to pay Pyth fees, check the revert table when adding handlers), `fork/` (optional). Naming: `test_`, `test_RevertWhen_`, `testFuzz_`, `invariant_`.

## Conventions

- Never claim an audit.
- Slither silences are inline, with the reason. No global detector exclusion.
- No commit or push without the owner's approval. No `Co-Authored-By` lines.
- Real keys only in `.env` (ignored).
