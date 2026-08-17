// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ERC-8056 (Scaled UI Amount Extension) interfaces
 * @notice Canonical, spec-exact interface declarations for ERC-8056, plus the two
 *         non-ERC surfaces an integrator on Robinhood Chain actually encounters.
 *
 * @dev WHAT ERC-8056 IS
 *
 *      A tokenised equity has to survive corporate actions -- splits, reverse
 *      splits, reinvested dividends. Minting to every holder is unbounded work and
 *      breaks contract holders; rebasing `balanceOf` breaks every integration that
 *      cached a balance or relies on an AMM invariant.
 *
 *      ERC-8056 takes a third path. Balances are immutable ledger units. A single
 *      global multiplier, {IScaledUIAmount-uiMultiplier}, records how many SHARES
 *      one TOKEN currently represents. A 2:1 split doubles the multiplier. No
 *      balance moves and no `Transfer` fires.
 *
 *      The consequence is that these tokens carry two distinct units, and mixing
 *      them is the defining integration bug of the standard:
 *
 *      - RAW units      -- what `balanceOf` returns, what `transfer` moves, what a
 *                          pool holds. Invariant across corporate actions.
 *      - UI units       -- share-equivalents. What a brokerage statement prints.
 *
 *      The conversion is 18-decimal fixed point, independent of the token's own
 *      `decimals()`:
 *
 *          ui  = raw * uiMultiplier / 1e18
 *          raw = ui  * 1e18 / uiMultiplier
 *
 * @dev SPEC SOURCE
 *
 *      https://eips.ethereum.org/EIPS/eip-8056 (Draft, created 2025-10-20).
 *      Interface IDs below are quoted from the spec AND asserted against
 *      `type(I).interfaceId` in `test/Erc8165Ids.t.sol`, so a transcription error
 *      here fails the build rather than shipping to integrators.
 *
 * @dev ERC-165 IS MANDATORY
 *
 *      Compliant tokens MUST implement ERC-165. That is what makes safe
 *      degradation possible: a consumer probes for {IScaledUIAmount} and falls
 *      back to a multiplier of 1e18 for a plain ERC-20. See `ScaledUIReader`.
 */

/*//////////////////////////////////////////////////////////////////////////////
                        ERC-165 INTERFACE IDS (from the spec)
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @notice ERC-165 interface IDs defined by ERC-8056.
 * @dev Verified live against the canonical Robinhood AAPL token
 *      (0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) on Robinhood Chain (4663)
 *      at block 38,417,371:
 *
 *        SCALED_UI_AMOUNT             -> true
 *        SCALED_UI_AMOUNT_NEW         -> true
 *        SCALED_UI_AMOUNT_CONVERSION  -> false   <-- see note on IScaledUIAmountConversion
 *        SCALED_UI_AMOUNT_BALANCES    -> true
 */
library ERC8056InterfaceIds {
    /// @dev `type(IScaledUIAmount).interfaceId`
    bytes4 internal constant SCALED_UI_AMOUNT = 0xa60bf13d;

    /// @dev `type(IScaledUIAmountNewUIMultiplier).interfaceId`
    bytes4 internal constant SCALED_UI_AMOUNT_NEW = 0x4bd27648;

    /// @dev `type(IScaledUIAmountConversion).interfaceId`
    bytes4 internal constant SCALED_UI_AMOUNT_CONVERSION = 0x57854fc3;

    /// @dev `type(IScaledUIAmountBalances).interfaceId`
    bytes4 internal constant SCALED_UI_AMOUNT_BALANCES = 0xd890fd71;

    /// @dev `type(IERC165).interfaceId`. Present so a reader can distinguish
    ///      "token answers ERC-165 and says no" from "token has no ERC-165 at all".
    bytes4 internal constant ERC165 = 0x01ffc9a7;

    /// @dev Per ERC-165, a contract MUST return false for this ID. A token that
    ///      returns true is answering unconditionally and its other answers are
    ///      worthless -- treat every probe as unsupported.
    bytes4 internal constant ERC165_INVALID = 0xffffffff;
}

/*//////////////////////////////////////////////////////////////////////////////
                                  CORE INTERFACE
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @title IScaledUIAmount
 * @notice The mandatory ERC-8056 core interface. ERC-165 ID `0xa60bf13d`.
 */
interface IScaledUIAmount {
    /**
     * @notice Emitted whenever the multiplier is changed or a change is scheduled.
     * @dev This is the ONLY authoritative corporate-action signal. No `Transfer`
     *      accompanies a corporate action, so an indexer that watches `Transfer`
     *      alone silently drifts from reality after the first split.
     * @param oldMultiplier          Multiplier in force before this update (1e18 = 1.0).
     * @param newMultiplier          Multiplier in force from `effectiveAtTimestamp` (1e18 = 1.0).
     * @param effectiveAtTimestamp   Unix time at which `newMultiplier` takes effect.
     *                               Equal to `block.timestamp` for an immediate action.
     */
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    /**
     * @notice Companion to ERC-20 `Transfer`, carrying the UI amount alongside the raw amount.
     *
     * @dev IMPLEMENTATION DIVERGENCE -- READ BEFORE BUILDING AN INDEXER.
     *
     *      The ERC names this event `TransferWithUIAmount`:
     *          topic0 = 0x0226a2f5c1ae0e071aeec3d4ebafcefdc5c549be11f40ed27e76e802acccf374
     *
     *      Live Robinhood Stock Tokens instead emit `TransferWithScaledUI` with the
     *      same parameter list:
     *          topic0 = 0x37e7f0db430edc9dd31bc66f25f8449353aa0818f503b906747dd8f286cd3802
     *
     *      Observed on AAPL (0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9): 23 of the
     *      last 50 logs carry the `TransferWithScaledUI` topic; the ERC's topic
     *      appears zero times. An indexer written to the ERC as published matches
     *      nothing on mainnet.
     *
     *      Both declarations are provided. Subscribe to BOTH topic0 values.
     *      See FINDINGS.md for the reproduction.
     */
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    /// @notice The `TransferWithScaledUI` spelling actually emitted on Robinhood Chain.
    /// @dev See the divergence note on {TransferWithUIAmount}.
    event TransferWithScaledUI(address indexed from, address indexed to, uint256 value, uint256 uiValue);

    /**
     * @notice Shares represented by one raw token, as 18-decimal fixed point.
     * @dev `1e18` means 1.0, i.e. no corporate action has been applied. This scale
     *      is fixed at 18 by the ERC and is unrelated to the token's `decimals()`.
     * @return The current multiplier.
     */
    function uiMultiplier() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////////////////////
                          REQUIRED EXTENSION: PENDING CHANGE
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @title IScaledUIAmountNewUIMultiplier
 * @notice Required ERC-8056 extension exposing a scheduled multiplier change.
 *         ERC-165 ID `0x4bd27648`.
 *
 * @dev DO NOT INFER "PENDING" FROM THESE VALUES NAIVELY.
 *
 *      Both fields are plain storage and are NOT cleared once a change has been
 *      applied. On live AAPL today they read:
 *
 *          uiMultiplier()    = 1000566080061092436
 *          newUIMultiplier() = 1000566080061092436   (identical -- already applied)
 *          effectiveAt()     = 1786720366            (2026-08-14, in the past)
 *
 *      So the intuitive tests are wrong:
 *
 *          newUIMultiplier() != 0            -> true   WRONG, false positive
 *          effectiveAt()     != 0            -> true   WRONG, false positive
 *
 *      A change is genuinely pending only when BOTH hold:
 *
 *          newUIMultiplier() != uiMultiplier()  &&  effectiveAt() > block.timestamp
 *
 *      `ScaledUIReader.readScaled` implements exactly this. BEP-677 added
 *      {IERC8056Scheduled} specifically to remove this ambiguity, but it is a BSC
 *      addition and is absent on Robinhood Chain.
 */
interface IScaledUIAmountNewUIMultiplier {
    /// @notice The multiplier that takes effect at {effectiveAt}.
    /// @dev Stale after the change applies -- see the interface-level note.
    function newUIMultiplier() external view returns (uint256);

    /// @notice Unix timestamp at which {newUIMultiplier} takes effect.
    /// @dev May be in the past. Not cleared after application.
    function effectiveAt() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////////////////////
                            OPTIONAL EXTENSIONS
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @title IScaledUIAmountConversion
 * @notice Optional ERC-8056 extension: token-side conversion helpers.
 *         ERC-165 ID `0x57854fc3`.
 *
 * @dev NOT AVAILABLE ON ROBINHOOD CHAIN. `supportsInterface(0x57854fc3)` returns
 *      false on the canonical AAPL token. Any integration that routes conversion
 *      through these functions does not work against real stock tokens. Use
 *      `ScaledUIMath` instead, which is why that library is load-bearing rather
 *      than a convenience.
 */
interface IScaledUIAmountConversion {
    /// @notice Convert a raw amount to share-equivalents.
    function toUIAmount(uint256 rawAmount) external view returns (uint256);

    /// @notice Convert share-equivalents to a raw amount.
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}

/**
 * @title IScaledUIAmountBalances
 * @notice Optional ERC-8056 extension: balances pre-scaled to UI units.
 *         ERC-165 ID `0xd890fd71`. Supported by Robinhood Stock Tokens.
 *
 * @dev Prefer these over computing locally when supported: the token is the
 *      authority on its own rounding. `ScaledUIReader` does exactly that and falls
 *      back to `ScaledUIMath` otherwise.
 *
 *      These are for DISPLAY and for share-denominated quoting. Protocol
 *      accounting -- what you store, what you transfer, what collateralises a
 *      position -- must stay in raw units, because raw units are what `transfer`
 *      actually moves. See INTEGRATION.md.
 */
interface IScaledUIAmountBalances {
    /// @notice `balanceOf(account)` expressed in share-equivalents.
    function balanceOfUI(address account) external view returns (uint256);

    /// @notice `totalSupply()` expressed in share-equivalents.
    function totalSupplyUI() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////////////////////
                        NON-ERC SURFACES (declared, clearly labelled)
//////////////////////////////////////////////////////////////////////////////*/

/**
 * @title IERC8056Scheduled
 * @notice BEP-677 extension. NOT part of ERC-8056 and NOT present on Robinhood Chain.
 *
 * @dev BNB Chain adopted ERC-8056 as BEP-677 and added this interface to fix the
 *      stale-state ambiguity documented on {IScaledUIAmountNewUIMultiplier}: it
 *      returns the pending change as a tuple and provides an explicit boolean
 *      guard, so a consumer never has to infer intent from two unclamped storage
 *      slots.
 *
 *      Declared here for cross-chain parity. A consumer targeting BSC should
 *      prefer {hasPendingMultiplier} over the inference rule. `ScaledUIReader`
 *      uses it when present and falls back to the inference rule otherwise.
 *
 *      Source: https://github.com/bnb-chain/BEPs/blob/master/BEPs/BEP-677.md
 */
interface IERC8056Scheduled {
    /// @notice Emitted when a scheduled change replaces an earlier, unapplied one.
    event UIMultiplierChangeOverwritten(
        uint256 overwrittenMultiplier, uint256 overwrittenEffectiveAt, uint256 newMultiplier, uint256 newEffectiveAt
    );

    /// @notice The pending change, as a tuple. Meaningful only when {hasPendingMultiplier} is true.
    function pendingMultiplier() external view returns (uint256 multiplier, uint256 effectiveAt);

    /// @notice Whether a change is genuinely pending. Authoritative -- no inference needed.
    function hasPendingMultiplier() external view returns (bool);
}

/**
 * @title IRobinhoodOraclePausable
 * @notice Robinhood-specific. NOT part of ERC-8056, NOT part of BEP-677, and NOT
 *         discoverable via ERC-165.
 *
 * @dev Robinhood Stock Tokens expose a flag signalling that the token's price is
 *      unreliable -- typically around dividends and splits. The Chainlink feed
 *      honours it by ceasing to publish and holding its last value.
 *
 *      THE FLAG IS ADVISORY. Nothing on chain enforces it. A consumer that does
 *      not read it will price, swap, quote or liquidate against a held-stale mark
 *      during precisely the window in which that mark is least trustworthy --
 *      and `latestRoundData()` gives no indication anything is wrong, because a
 *      held price is not a reverting price.
 *
 *      `ScaledUIOracle` enforces this flag: it reverts by default when set, with
 *      a separately-named opt-out for callers who genuinely want the unsafe read.
 *
 *      Because it is undiscoverable, probe it with a low-level call and treat a
 *      failure as "not pausable", never as "paused" and never as a revert.
 */
interface IRobinhoodOraclePausable {
    /// @notice True when the issuer has signalled that this token's price is unreliable.
    function oraclePaused() external view returns (bool);
}
