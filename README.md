# erc8056-toolkit

**Safe integration primitives for ERC-8056 (Scaled UI Amount) tokens.**
Solidity · Foundry · MIT · unaudited

---

On 2026-08-14 the Robinhood AAPL stock token stopped reporting a `uiMultiplier`
of 1.0:

```
$ cast call 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "uiMultiplier()(uint256)" \
    --rpc-url https://rpc.mainnet.chain.robinhood.com

1000566080061092436          # 1.000566, not 1.0
```

Until that moment, raw token balances and share-equivalents were numerically
identical on every token on the chain, so every integration that conflated them
was accidentally correct. They are no longer identical. The integrations did not
change.

Twelve of the other thirteen stock tokens still read exactly `1e18` — which means
testing against live tokens still cannot tell correct code from code that ignores
the multiplier entirely.

**[→ Read FINDINGS.md](FINDINGS.md)** for the full evidence, reproducible with
`./script/survey.sh`.

---

## What this library does

Three things go wrong when a contract consumes an ERC-8056 token. This library
addresses each one, on chain, in Solidity.

| | The trap | The fix |
|---|---|---|
| **1** | Chainlink's feed already multiplies by `uiMultiplier`. Applying it again double-counts — 5.66 bps on AAPL today, **100% after a 2:1 split**. Nothing reverts. | `ScaledUIOracle` returns price in one documented convention, so there is nothing left to apply. |
| **2** | `oraclePaused()` signals an untrustworthy price. **Nothing enforces it**, and a paused feed returns a perfectly well-formed held-stale answer. | `ScaledUIOracle` reverts on the flag by default; the unsafe read is a separately-named opt-out. |
| **3** | Detecting a scheduled change is genuinely subtle. The obvious test, `newUIMultiplier() != 0`, **false-positives on live AAPL right now**. | `ScaledUIReader` implements the correct rule and is tested against the exact live state that breaks the naive one. |

## Install

```bash
forge install Ravenium22/erc8056-toolkit
```

```solidity
import {ScaledUIReader, ScaledRead} from "erc8056-toolkit/src/ScaledUIReader.sol";
import {ScaledUIMath} from "erc8056-toolkit/src/ScaledUIMath.sol";
```

## Use

Read once, and get everything back together — so the multiplier cannot be applied
a second time by accident:

```solidity
ScaledRead memory r = ScaledUIReader.readBalance(token, user);

r.rawAmount      // token units, what `transfer` moves      -> use for accounting
r.uiAmount       // share-equivalents                        -> use for display
r.multiplier     // 1e18 for a plain ERC-20
r.isScaled       // false for a plain ERC-20 (never reverts)
r.changePending  // a genuinely scheduled future change
r.effectiveAt    // 0 unless changePending
```

Price it without double-counting:

```solidity
ScaledUIOracle oracle = new ScaledUIOracle(feed, token, 1 hours);

// Reverts if oraclePaused is set, or if the answer is stale or malformed.
uint256 usd = oracle.valueOfHolder(user);
```

Convert with the rounding direction stated at the call site:

```solidity
ScaledUIMath.toUIDown(raw, m);   // crediting a user     -> round down
ScaledUIMath.toUIUp(raw, m);     // charging a user      -> round up
ScaledUIMath.toRawDown(ui, m);   // paying out           -> round down
ScaledUIMath.toRawUp(ui, m);     // pulling in           -> round up
```

Rounding direction is in the function name, never a boolean argument — a boolean
at a call site is invisible in review.

## Contents

```
src/interfaces/IERC8056.sol   All four ERC-8056 interfaces + published ERC-165 ids,
                              plus BEP-677 and Robinhood-specific surfaces, labelled.
src/ScaledUIMath.sol          Pure conversion. Overflow-safe, rounding documented.
src/ScaledUIReader.sol        Safe reads. ERC-165 detection, graceful degradation.
src/ScaledUIOracle.sol        Chainlink wrapper. Enforces oraclePaused + staleness.
```

## Design rules

1. **Stateless where possible.** Libraries over deployed singletons. Nothing to
   trust, nothing to rug, nothing to upgrade.
2. **No admin keys.** The one deployable contract is ownerless; every
   configurable value is a constructor immutable.
3. **Fail loudly on unsafe reads, silently on unsupported tokens.** A paused
   oracle reverts. A plain ERC-20 just works, with a multiplier of `1e18`.
4. **Pinned pragma** — `0.8.28`, not `^0.8.x`.
5. **Every rounding decision documented in the code itself.**
6. **OpenZeppelin is the only dependency.**

## Test

```bash
forge test                                        # unit + fuzz, no network
FOUNDRY_PROFILE=ci forge test                     # 100k fuzz runs
RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path 'test/fork/*' -vv       # live tokens AND live Chainlink feeds
```

The fork suite values one raw token of AAPL, TSLA, NVDA and SPY against their
real Chainlink feeds, correctly and naively side by side:

```
AAPL  safe $305.47782706   naive $305.65075196   -> 5.66 bps over-valued
TSLA  safe $342.95500000   naive $342.95500000   -> identical (multiplier 1.0)
NVDA  safe $225.02999999   naive $225.02999999   -> identical (multiplier 1.0)
SPY   safe $777.07999999   naive $777.07999999   -> identical (multiplier 1.0)
```

Three of the four cannot tell a correct integration from a broken one.

Feed addresses are in [FINDINGS.md §7](FINDINGS.md#7-the-feed-addresses) — they
are not in the Robinhood or Chainlink docs and are not resolvable on chain.

Fork tests read at `latest` and assert invariants rather than pinning to a block:
the public Robinhood Chain RPC is not an archive node and retains roughly ten
minutes of state. See [FINDINGS.md §5](FINDINGS.md#5-reproducing-this).

## Status and scope

**Unaudited. Read it before you rely on it.** No contract here custodies funds,
and the surface area is deliberately small, but that is mitigation rather than
assurance.

ERC-8056 is still **Draft**. This library tracks it and will change with it.

This is the *integrator* side only — what a consuming protocol imports. It is
deliberately not a token implementation, a conformance suite, or a formal
verification effort. Prior work worth knowing about:

- [`nirholas/robinhood-chain-erc8056`](https://github.com/nirholas/robinhood-chain-erc8056)
  — reference token implementation, explainer, and TypeScript helpers.
- [`jumpboxtech/erc-8056-conformance`](https://github.com/jumpboxtech/erc-8056-conformance)
  — Foundry conformance suite for implementers.
- [`normanxbt/erc-8056-security-fv-review`](https://github.com/normanxbt/erc-8056-security-fv-review)
  — Certora specs against a pinned implementation.
- [`bnb-chain/bep-677-contracts`](https://github.com/bnb-chain/bep-677-contracts)
  — the BSC adoption, which adds `hasPendingMultiplier()`.

## References

- [ERC-8056: Scaled UI Amount Extension for ERC-20 Tokens](https://eips.ethereum.org/EIPS/eip-8056) (Draft)
- [BEP-677](https://github.com/bnb-chain/BEPs/blob/master/BEPs/BEP-677.md)
- [Robinhood Chain: Building with Stock Tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/)
- [Chainlink: Robinhood Tokenized Equities](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)

## Licence

MIT.
