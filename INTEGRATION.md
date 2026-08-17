# Integrating ERC-8056 tokens safely

For engineers writing a contract that will **hold, price, quote, lend against or
settle** Robinhood Stock Tokens or any other ERC-8056 token.

This guide is deliberately narrow. It covers the on-chain decisions that go wrong
and are not obvious. For the general shape of the standard — what the multiplier
is, how to index it, caching policy off chain — read
[`nirholas/robinhood-chain-erc8056`'s INTEGRATION.md](https://github.com/nirholas/robinhood-chain-erc8056/blob/main/INTEGRATION.md),
which covers that ground well and is not duplicated here.

Read [FINDINGS.md](FINDINGS.md) first if you have not. The short version: **AAPL's
multiplier is no longer 1.0**, so these are live concerns rather than future ones.

---

## Contents

1. [The one rule: store raw, derive UI](#1-the-one-rule-store-raw-derive-ui)
2. [Pricing without double-counting](#2-pricing-without-double-counting)
3. [What to do when `oraclePaused` is set](#3-what-to-do-when-oraclepaused-is-set)
4. [Positions that straddle `effectiveAt`](#4-positions-that-straddle-effectiveat)
5. [Rounding](#5-rounding)
6. [Detecting the token at all](#6-detecting-the-token-at-all)
7. [Auditor checklist](#7-auditor-checklist)

---

## 1. The one rule: store raw, derive UI

An ERC-8056 token has two units. Only one of them is safe to persist.

| | `balanceOf` — **raw** | `balanceOfUI` — **share-equivalent** |
|---|---|---|
| What `transfer` moves | ✅ yes | ❌ no |
| Stable across a corporate action | ✅ yes | ❌ **no** |
| Safe to store in your accounting | ✅ **yes** | ❌ no |
| Correct for display / share quoting | ❌ no | ✅ yes |

**Store raw. Derive UI at the point of display.**

The failure mode is not theoretical. Store a share-equivalent balance, let a 2:1
split land, and every stored figure is silently half of what it should be — or
double, depending which way you read it. No transaction failed. No event fired
against your position. Your ledger just stopped matching the chain.

```solidity
// WRONG -- this number's meaning changes underneath you
position.shares = token.balanceOfUI(user);

// RIGHT -- this number is what transfer() moves, and it never changes by itself
position.raw = token.balanceOf(user);
```

`test_CachedUiAmountGoesWrongAcrossASplit` in `test/ScaledUIReader.t.sol`
demonstrates exactly this.

There is one more trap in the same family: **a corporate action emits no
`Transfer`.** If your accounting reconciles by watching `Transfer` events, it will
drift the moment a multiplier changes and give you no signal that it has. Watch
`UIMultiplierUpdated` too — and see [FINDINGS §4.2](FINDINGS.md#42-the-emitted-event-name-does-not-match-the-spec)
for the event-name divergence that will otherwise cost you an afternoon.

---

## 2. Pricing without double-counting

**Chainlink's Robinhood feeds already include the multiplier.** The published
answer is the price of one *raw* token.

```solidity
// WRONG -- squares the multiplier.
// 5.66 bps too high on AAPL today. 100% too high after a 2:1 split.
(, int256 price,,,) = feed.latestRoundData();
uint256 shares = token.balanceOf(user) * token.uiMultiplier() / 1e18;
uint256 value  = shares * uint256(price) / 1e18;

// RIGHT -- the feed already did the conversion.
(, int256 price,,,) = feed.latestRoundData();
uint256 value = token.balanceOf(user) * uint256(price) / 1e18;
```

The wrong version is *more* thoughtful-looking than the right one, which is why it
gets written and why it survives review. And at a multiplier of exactly 1.0 the
two produce identical output — so it passes every test until the day it doesn't.

Or skip the question entirely:

```solidity
uint256 value = oracle.valueOfHolder(user);   // ScaledUIOracle
```

`ScaledUIOracle` returns a `ScaledPrice` struct rather than a bare `uint256`
precisely so the convention cannot be lost between the read and the use. It
reports `multiplier` as context for display — that value is **already inside**
`price`; do not apply it.

> **If you take one thing from this document:** search your codebase for
> `uiMultiplier`. Every occurrence next to a price is a bug until proven otherwise.

---

## 3. What to do when `oraclePaused` is set

When the flag is set, the feed **stops publishing and holds its last value**. From
your contract's point of view:

- `latestRoundData()` succeeds.
- The answer is positive.
- `roundId == answeredInRound`.
- **Nothing in the response indicates a problem.**

A staleness check does not reliably save you. `updatedAt` freezes, so a generous
threshold passes the held price outright; a strict one rejects it without telling
you whether the feed is paused or broken.

**Treat a paused oracle as "price temporarily unavailable" — not as zero, not as
stale, and not as the last good price.**

| Operation | While `oraclePaused` |
|---|---|
| Open a position, add collateral | **Refuse** |
| Quote a swap, mint an LP position | **Refuse** |
| Liquidate | **Refuse by default.** Liquidating on a mark the issuer has disowned is how a corporate action becomes a mass liquidation event. If your protocol genuinely cannot pause liquidations, say so explicitly in your docs and use `latestPriceUnsafe()` so the decision is visible in the diff. |
| Withdraw collateral, repay debt | Safe to allow — these reduce risk and do not need a fresh mark |
| Display a balance | Allow, clearly labelled as a stale mark |

```solidity
// Reverts OraclePaused when the issuer has flagged the price
uint256 value = oracle.valueOfHolder(user);

// Or check first, without reverting
if (!oracle.isPriceUsable()) revert PriceUnavailable();
```

**Do not treat an absent flag as paused.** Plain ERC-20s (USDG, WETH) have no
`oraclePaused()`, and they are the other side of nearly every stock-token pair.
`ScaledUIOracle.oraclePaused()` returns `(paused, known)` so you can tell "not
paused" from "cannot tell".

---

## 4. Positions that straddle `effectiveAt`

A scheduled corporate action means a position can be opened under one multiplier
and closed under another. If any part of your accounting is denominated in
share-equivalents, that changes its meaning mid-flight.

### Detecting a pending change is genuinely subtle

`newUIMultiplier()` and `effectiveAt()` are **never cleared after a change is
applied**. Live AAPL right now:

```
uiMultiplier()    = 1000566080061092436
newUIMultiplier() = 1000566080061092436     <-- identical: already applied
effectiveAt()     = 1786720366              <-- 2026-08-14, in the past
```

So:

```solidity
// WRONG -- false-positives on live AAPL right now
bool pending = token.newUIMultiplier() != 0;

// WRONG -- same
bool pending = token.effectiveAt() != 0;

// RIGHT -- both conditions are required
bool pending = token.newUIMultiplier() != token.uiMultiplier()
            && token.effectiveAt()     >  block.timestamp;
```

A protocol that halts while a change is pending would, using either naive test,
refuse **every** AAPL position from 2026-08-14 onward — a permanent denial of
service that looks like a safety feature and will be diagnosed as an outage.

```solidity
ScaledRead memory r = ScaledUIReader.readScaled(token);
if (r.changePending) { /* r.effectiveAt is when */ }
```

### What to actually do about it

The library surfaces the information; the policy is yours. Reasonable ones:

- **Refuse to open** positions whose term crosses `effectiveAt`. Simplest, and
  right for fixed-term products.
- **Settle in raw units.** If nothing you persist is share-denominated, a
  multiplier change cannot reprice a position mid-flight and you may not need a
  policy at all. This is the best answer where it is available.
- **Re-read the multiplier at settlement**, never reuse the one from entry. If you
  cached a `ScaledRead` at open, it is a *record of the past*, not a current fact.

The one thing not to do is nothing: quoting across `effectiveAt` with a cached
multiplier means entry and exit disagree about what a share is.

---

## 5. Rounding

Conversions are lossy by up to 1 wei per leg. `ScaledUIMath` puts the direction in
the function name so it is visible at the call site:

| Situation | Use | Why |
|---|---|---|
| Crediting a user's collateral | `toUIDown` | Never credit more than is backed |
| Debt denominated in shares | `toUIUp` | Never under-state a liability |
| Raw tokens to transfer **out** | `toRawDown` | Send no more than owed |
| Raw tokens to pull **in** | `toRawUp` | Collect no less than due |

The rule: **round in the direction that costs the caller.** Picking the convenient
direction at each site is how rounding-dust extraction becomes an exploit.

The round trip is **not** the identity — `toRawDown(toUIDown(x, m), m) <= x`, and
can be strictly less. Never assert exact equality in a reconciliation check.

---

## 6. Detecting the token at all

ERC-165 detection is mandatory for compliant tokens, so probe rather than assume:

```solidity
ScaledRead memory r = ScaledUIReader.readBalance(token, user);
// r.isScaled == false and r.multiplier == 1e18 for a plain ERC-20.
// Never reverts, whatever the token does.
```

Three specific hazards:

- **`IScaledUIAmountConversion` is not implemented** by Robinhood Stock Tokens
  (`supportsInterface(0x57854fc3)` → `false`). `toUIAmount`/`fromUIAmount` do not
  exist. Do your own arithmetic.
- **Resolve tokens by address, never by symbol.** `loxAAPL`
  (`0xDa62…8f48`) is a live token with the AAPL ticker and is not a Robinhood
  Stock Token. There is also a second `NVDA` at a different address. Use the
  canonical list at
  [docs.robinhood.com/chain/contracts](https://docs.robinhood.com/chain/contracts).
- **A token that returns `true` for `0xffffffff`** is answering unconditionally
  and its other answers are worthless. `ScaledUIReader` checks this sentinel and
  distrusts such tokens; if you roll your own detection, do the same.

---

## 7. Auditor checklist

For reviewing any contract that touches ERC-8056 tokens.

**Units**
- [ ] Is anything **persisted** in share-equivalents? It should be raw.
- [ ] Does a multiplier change alter the meaning of any stored value?
- [ ] Is a cached `uiAmount` or multiplier ever reused across a block boundary?
- [ ] Does reconciliation depend on `Transfer` events alone? Corporate actions emit none.

**Pricing**
- [ ] Search for `uiMultiplier`. Is it applied anywhere near a Chainlink answer?
- [ ] Does the test suite exercise a multiplier **other than `1e18`**? If not, it has verified nothing — at 1.0 correct and incorrect code agree exactly.
- [ ] Is `oraclePaused()` read at all? Is it *enforced*?
- [ ] Is an absent `oraclePaused()` treated as "not pausable" rather than "paused"?
- [ ] Is there a staleness check, and is the threshold derived from the feed's heartbeat rather than convenience?
- [ ] Are `answer <= 0` and `answeredInRound < roundId` handled?

**Pending changes**
- [ ] Is pending detection `newUIMultiplier() != 0`? That false-positives on live AAPL.
- [ ] Does it require **both** `next != current` **and** `effectiveAt > block.timestamp`?
- [ ] Can a position be opened and settled under different multipliers? Is that intended?

**Token handling**
- [ ] Are tokens resolved by canonical address, never by symbol?
- [ ] Does the contract survive a plain ERC-20 (multiplier `1e18`, no revert)?
- [ ] Does it survive a token whose `supportsInterface` reverts, or claims everything?
- [ ] Are external token calls gas-bounded? They are untrusted.

**Rounding**
- [ ] Is the direction documented at each conversion, and does it favour the protocol?
- [ ] Does any invariant assume an exact round trip?

---

## Reference

- [ERC-8056](https://eips.ethereum.org/EIPS/eip-8056) (Draft)
- [BEP-677](https://github.com/bnb-chain/BEPs/blob/master/BEPs/BEP-677.md) — adds `hasPendingMultiplier()`, absent on Robinhood Chain
- [Robinhood Chain: Building with Stock Tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/)
- [Chainlink: Robinhood Tokenized Equities](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)

---

*This library is **unaudited**. Read it before you rely on it. Nothing here
custodies funds, but that is mitigation, not assurance.*
