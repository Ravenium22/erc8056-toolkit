# Findings: ERC-8056 on Robinhood Chain

**Observed at block 38,433,326 · chain 4663 · 2026-08-17T01:13:43Z**

Everything below is reproducible with `./script/survey.sh`. If you only read one
line, read this one:

> **The Robinhood AAPL token no longer has a `uiMultiplier` of 1.0.**
> It reads `1000566080061092436` — about 1.000566 — effective 2026-08-14.
> Every integration that assumed 1.0 is now quietly wrong about AAPL.

---

## Contents

1. [The multiplier is no longer 1.0](#1-the-multiplier-is-no-longer-10)
2. [The double-counting trap](#2-the-double-counting-trap)
3. [`oraclePaused` is advisory and unenforced](#3-oraclepaused-is-advisory-and-unenforced)
4. [Two detection bugs](#4-two-detection-bugs)
5. [Reproducing this](#5-reproducing-this)
6. [What we could not verify](#6-what-we-could-not-verify)

---

## 1. The multiplier is no longer 1.0

ERC-8056 lets a token issuer record a corporate action as a multiplier rather
than by moving balances. Until 2026-08-14, every Robinhood Stock Token read
exactly `1e18`, so the distinction between raw token units and share-equivalents
was invisible: the two were numerically identical, and every integration that
conflated them happened to be right.

That is no longer true.

```
SYMBOL   ADDRESS                                      uiMultiplier           effectiveAt  paused  ERC-8056?
AAPL     0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9   1000566080061092436    1786720366   false   true
TSLA     0x322F0929c4625eD5bAd873c95208D54E1c003b2d   1000000000000000000    0            false   true
NVDA     0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC   1000000000000000000    0            false   true
MSFT     0xe93237C50D904957Cf27E7B1133b510C669c2e74   1000000000000000000    0            false   true
AMZN     0x12f190a9F9d7D37a250758b26824B97CE941bF54   1000000000000000000    0            false   true
GOOGL    0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3   1000000000000000000    0            false   true
META     0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35   1000000000000000000    0            false   true
NFLX     0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8   1000000000000000000    0            false   true
SPY      0x117cc2133c37B721F49dE2A7a74833232B3B4C0C   1000000000000000000    0            false   true
QQQ      0xD5f3879160bc7c32ebb4dC785F8a4F505888de68   1000000000000000000    0            false   true
JNJ      0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80   1000000000000000000    0            false   true
XOM      0xf9B46d3D1B22199D4D1025a9cEDB540A33F1a2d5   1000000000000000000    0            false   true
PFE      0x7066A64c24e4206CD62E83bf198c1E7EB361F51e   1000000000000000000    0            false   true
USDG     0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168   -                      -            -       false      (plain ERC-20)
WETH     0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73   -                      -            -       no ERC-165 (plain ERC-20)
loxAAPL  0xDa62854B8Ae99beb09ca2A9950317b75FaD28f48   -                      -            -       no ERC-165 (NOT a Robinhood token)
```

`effectiveAt = 1786720366` is **2026-08-14T15:12:46Z**.

The divergence shows up directly in the token's own supply figures:

```
totalSupply()   = 5986452108820000000000     (5986.4521 raw tokens)
totalSupplyUI() = 5989840919995487767925     (5989.8409 share-equivalents)
                                             ------------------------
                                    delta      3.3888 shares
```

Those are the same tokens, described two ways. Any system that reports one number
where it means the other is now off by 5.66 basis points on AAPL — and by 100% on
whichever ticker splits next.

### Why this matters more than the size of the number

5.66 bps sounds ignorable. It is not, for three reasons:

1. **It is the first one.** The mechanism now demonstrably fires in production. The
   next corporate action could be a 2:1 split, which is a 100% error, and it will
   arrive with no more warning than this one did.
2. **Real DeFi is already exposed.** Robinhood Chain carries live Uniswap, MYX
   Finance and Quiver AAPL/USDG pools. They hold the token that diverged.
3. **Nothing reverts.** There is no error state, no failed transaction, no alert.
   A wrong position simply looks like a position.

### Live tokens are not a test fixture

Twelve of the thirteen stock tokens above still read exactly `1e18`. An
integration tested only against those has verified nothing at all — it cannot
distinguish correct code from code that ignores the multiplier entirely, because
at 1.0 the two produce identical output.

Test against a non-unit multiplier. `test/mocks/MockScaledUIToken.sol` in this
repo exists for that, and `ScaledUIMath.isUnitMultiplier` is there so a test can
assert it is *not* looking at the degenerate case.

---

## 2. The double-counting trap

This is the expensive one.

Chainlink's Robinhood tokenized-equity feeds report

```
answer = underlying equity market price × uiMultiplier
```

with the multiplier **already applied**, read by the oracle directly from the
token contract. The published answer is the price of **one raw token**.

If you are thinking in shares — and the name `uiMultiplier` invites you to — the
natural next step is to apply the multiplier yourself:

```solidity
// WRONG. The feed already did this.
(, int256 price,,,) = feed.latestRoundData();
uint256 value = uint256(price) * token.uiMultiplier() / 1e18;
```

That squares the multiplier. Today on AAPL it over-values a position by 5.66 bps.
After a 2:1 split it over-values it by **100%** — a collateral valuation that says
a position is worth twice what it is.

```solidity
// RIGHT. The feed's answer is already price-per-raw-token.
(, int256 price,,,) = feed.latestRoundData();
uint256 value = uint256(price) * rawBalance / 1e18;
```

The trap is that both versions compile, neither reverts, and **at a multiplier of
1.0 they return identical values** — which is why an integration can pass every
test written before 2026-08-14 and still be wrong today.

`test/DoubleCountDemo.t.sol` in this repo runs both side by side and asserts the
divergence at AAPL's real multiplier.

---

## 3. `oraclePaused` is advisory and unenforced

Robinhood Stock Tokens expose `oraclePaused()`. When it is set, the Chainlink feed
stops publishing and **holds its last value**.

Consider what a consumer sees during that window:

- `latestRoundData()` returns successfully.
- The answer is positive and structurally valid.
- `roundId` and `answeredInRound` agree.
- Nothing in the Chainlink response indicates anything is wrong.

The only signal is on the token, in a flag that **nothing on chain enforces**. A
contract that does not explicitly read it will price, quote, swap or liquidate
against a frozen mark during precisely the window — dividends, splits — when that
mark is least trustworthy.

Worse, a naive staleness check does not save you. `updatedAt` is frozen, so a
sufficiently generous threshold passes; a strict threshold rejects the price for
the wrong reason and gives no way to distinguish "feed is paused deliberately"
from "feed is broken".

`src/ScaledUIOracle.sol` reverts on this flag by default, with a separately-named
opt-out for callers who genuinely want the unsafe read.

---

## 4. Two detection bugs

### 4.1 `newUIMultiplier() != 0` is a false positive

ERC-8056 requires `newUIMultiplier()` and `effectiveAt()` for scheduled changes.
Neither field is cleared once a change has been applied. Live AAPL right now:

```
uiMultiplier()    = 1000566080061092436
newUIMultiplier() = 1000566080061092436     <-- identical: already applied
effectiveAt()     = 1786720366              <-- 2026-08-14, in the PAST
```

So both intuitive tests report a pending change that does not exist:

| test | result | correct? |
|---|---|---|
| `newUIMultiplier() != 0` | pending | ✗ false positive |
| `effectiveAt() != 0` | pending | ✗ false positive |
| `newUIMultiplier() != uiMultiplier() && effectiveAt() > block.timestamp` | none | ✓ |

A protocol that blocks new positions while a change is pending would, using either
naive check, refuse to open **any** AAPL position from 2026-08-14 onward — a
permanent, silent denial of service that looks like a safety feature.

BNB Chain hit this too. BEP-677 added `hasPendingMultiplier()` specifically to
remove the ambiguity. That extension is **not** part of ERC-8056 and is **not**
present on Robinhood Chain, so on this chain the inference rule is all you have.

`ScaledUIReader.readScaled` implements the correct rule.

### 4.2 The emitted event name does not match the spec

ERC-8056 specifies:

```solidity
event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);
// topic0 = 0x0226a2f5c1ae0e071aeec3d4ebafcefdc5c549be11f40ed27e76e802acccf374
```

Live Robinhood Stock Tokens emit, with the same parameter list:

```solidity
event TransferWithScaledUI(address indexed from, address indexed to, uint256 value, uint256 uiValue);
// topic0 = 0x37e7f0db430edc9dd31bc66f25f8449353aa0818f503b906747dd8f286cd3802
```

Of AAPL's 50 most recent logs: **23 carry `TransferWithScaledUI`**, 23 carry the
standard ERC-20 `Transfer`, 4 carry `Approval`, and **zero** carry the topic the
ERC specifies.

An indexer built from the published ERC matches nothing on mainnet. Subscribe to
both topics. The Robinhood documentation uses the `TransferWithScaledUI` spelling,
so the divergence appears to be between the ERC text and the implementation rather
than a deployment error — but since ERC-8056 is still **Draft**, this is worth
resolving upstream, and we have raised it as a question rather than a defect.

### 4.3 `IScaledUIAmountConversion` is not available

```
0xa60bf13d  IScaledUIAmount                 -> true
0x4bd27648  IScaledUIAmountNewUIMultiplier  -> true
0x57854fc3  IScaledUIAmountConversion       -> false   <--
0xd890fd71  IScaledUIAmountBalances         -> true
0x01ffc9a7  IERC165                         -> true
0xffffffff  ERC-165 invalid sentinel        -> false   (correct)
```

`toUIAmount` / `fromUIAmount` do not exist on Robinhood Stock Tokens. Any
integration that routes conversion through them does not work. You must own the
arithmetic — see `src/ScaledUIMath.sol`, which is why that library is
load-bearing rather than a convenience.

The four spec-published interface IDs are otherwise correct and match
`type(I).interfaceId` exactly; `test/ERC165Ids.t.sol` pins this.

---

## 5. Reproducing this

```bash
./script/survey.sh
# or against your own endpoint:
./script/survey.sh https://your-rpc
```

Individual claims:

```bash
RPC=https://rpc.mainnet.chain.robinhood.com
AAPL=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9

# The multiplier has diverged
cast call $AAPL "uiMultiplier()(uint256)"    --rpc-url $RPC
cast call $AAPL "totalSupply()(uint256)"     --rpc-url $RPC
cast call $AAPL "totalSupplyUI()(uint256)"   --rpc-url $RPC

# The stale pending-change state
cast call $AAPL "newUIMultiplier()(uint256)" --rpc-url $RPC
cast call $AAPL "effectiveAt()(uint256)"     --rpc-url $RPC

# Conversion extension is absent
cast call $AAPL "supportsInterface(bytes4)(bool)" 0x57854fc3 --rpc-url $RPC

# The event topic that is actually emitted
cast keccak "TransferWithScaledUI(address,address,uint256,uint256)"
```

And the tests:

```bash
forge test                       # unit + fuzz, no network needed
RH_RPC_URL=$RPC forge test --match-path 'test/fork/*'
```

### A note on block pinning

These readings are recorded with an observation block, not pinned to one, because
**the public Robinhood Chain RPC is not an archive node.** Measured retention is
roughly 6,000 blocks at ~100 ms per block — about **ten minutes** of historical
state. Older queries fail:

```
error code -32000: metadata is not found
```

So `--block <n>` reproduction is impossible on the public endpoint beyond that
window, and fork tests in this repo run at `latest` and assert invariants rather
than pinning to a block. Exact historical reproduction requires a third-party
archive endpoint.

---

## 6. What we could not verify

Stated plainly, because a findings document that hides its gaps is not worth
trusting.

- **Chainlink feed addresses — and no on-chain aggregator activity.** The
  Robinhood tokenized-equity feeds are not enumerable: no registry contract, no
  address table in either the Chainlink or Robinhood documentation, and no match
  by name on the block explorer.

  We then searched on chain by event signature, which is how a push-based
  aggregator is normally found, and got nothing:

  ```bash
  RPC=https://rpc.mainnet.chain.robinhood.com
  L=$(cast block-number --rpc-url $RPC)
  for sig in "AnswerUpdated(int256,uint256,uint256)" \
             "NewRound(uint256,address,uint256)" \
             "NewTransmission(uint32,int192,address,uint32,int192[],bytes,bytes32)"; do
    cast logs --from-block $((L-50000)) --to-block latest "$sig" --rpc-url $RPC
  done
  # -> no results for any signature
  ```

  **No contract on Robinhood Chain emitted a standard Chainlink aggregator event
  over the ~85-minute queryable window.** (Control: an unfiltered `eth_getLogs`
  over 2,000 blocks exceeds the RPC's 10,000-log cap, so logs are plentiful and
  the query path works.)

  We do not know why. Candidate explanations, none confirmed: the feeds publish
  less often than the window; they are deployed but idle; or pricing is delivered
  by a pull-based mechanism rather than the push aggregators the Robinhood
  documentation shows. The documentation is explicit that consumers should call
  `latestRoundData()`, so a conventional aggregator is the intended surface.

  The consequence for this repository: the double-counting mechanism is
  documented by both Chainlink and Robinhood and modelled faithfully in
  `test/mocks/MockAggregatorV3.sol`, but **we have not read a live feed**, so the
  5.66 bps figure is derived from the multiplier rather than measured against a
  production oracle. `ScaledUIOracle` takes a caller-supplied feed address, so
  this does not affect its design — only the depth of its fork testing.

  This is the open question most worth putting to Chainlink and Robinhood
  directly.

- **The `UIMultiplierUpdated` event for the AAPL action.** The state change is
  confirmed by direct reads, but the emitting transaction sits outside the RPC's
  ~10-minute retention window and the explorer's recent-logs page does not reach
  it. The event signature and topic hash are confirmed; the specific historical
  log is not.

- **Whether the event-name divergence is intentional.** We report the mismatch as
  observed. We have not confirmed which of the ERC text or the deployed
  implementation is considered authoritative.

---

*This document is a factual record, not advice. The library in this repository is
**unaudited** — read it before you rely on it.*
