// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title ScaledUIMath
 * @notice Conversion between ERC-8056 raw token units and UI (share-equivalent) units.
 * @author erc8056-toolkit
 *
 * @dev WHY THIS EXISTS AT ALL
 *
 *      ERC-8056 defines an optional token-side conversion extension
 *      (`IScaledUIAmountConversion`, ERC-165 `0x57854fc3`). Robinhood Stock Tokens
 *      do NOT implement it -- `supportsInterface(0x57854fc3)` returns false on the
 *      canonical AAPL token. So an integrator on Robinhood Chain has to own this
 *      arithmetic. That makes the rounding decisions below consequential rather
 *      than cosmetic.
 *
 * @dev THE CONVERSION
 *
 *          ui  = raw * multiplier / 1e18
 *          raw = ui  * 1e18 / multiplier
 *
 *      `multiplier` is 18-decimal fixed point (`1e18` == 1.0) as mandated by the
 *      ERC, independent of the token's own `decimals()`. Do not substitute
 *      `10 ** token.decimals()` for {SCALE}; they are unrelated quantities that
 *      happen to both be 1e18 on every Robinhood Stock Token today.
 *
 * @dev OVERFLOW
 *
 *      The ERC explicitly requires implementations to handle `raw * multiplier`
 *      overflow, and consumers inherit that obligation. Every function here routes
 *      through OpenZeppelin `Math.mulDiv`, which computes the 512-bit intermediate
 *      product and only then divides. `raw` and `multiplier` may therefore each
 *      approach `type(uint256).max` without a spurious revert; the operation
 *      reverts only when the true mathematical RESULT exceeds `uint256`.
 *
 * @dev ROUNDING -- THE RULE THIS LIBRARY ENFORCES
 *
 *      Rounding direction is in the FUNCTION NAME, never a boolean argument. A
 *      boolean at a call site is invisible in review; `toRawUp` is not.
 *
 *      There is no universally safe direction, because "favour the protocol"
 *      depends on which side of the trade the value sits on. The rule:
 *
 *          value the protocol OWES a user      -> round DOWN  (pay no more than owed)
 *          value a user OWES the protocol      -> round UP    (collect no less than due)
 *
 *      Applied to a lending market holding stock tokens as collateral:
 *
 *          collateral credited to a borrower   -> toUIDown   (credit no more than held)
 *          debt denominated in shares          -> toUIUp     (never under-state debt)
 *          raw tokens to transfer OUT          -> toRawDown  (send no more than owed)
 *          raw tokens to pull IN               -> toRawUp    (collect no less than due)
 *
 *      Picking the convenient direction at each site is how rounding-dust
 *      extraction becomes an exploit. Pick the direction that costs the caller.
 *
 * @dev PRECISION
 *
 *      The round trip is lossy by at most 1 wei per conversion, and is NOT the
 *      identity. `toRawDown(toUIDown(x, m), m) <= x` -- it can be strictly less.
 *      Never assert exact equality on a round trip; the tolerance bounds proved in
 *      `test/ScaledUIMath.t.sol` are the contract this library offers.
 */
library ScaledUIMath {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fixed-point scale of an ERC-8056 multiplier. `SCALE` == 1.0.
    /// @dev Mandated as 18 decimals by the ERC. Unrelated to token `decimals()`.
    uint256 internal constant SCALE = 1e18;

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Thrown when a conversion is attempted with a zero multiplier.
     * @dev A zero multiplier is never legitimate: it would make every holder's
     *      share-equivalent balance zero and make {toRawDown}/{toRawUp} a division
     *      by zero. Reaching this means a malformed token or a failed read that
     *      defaulted to zero -- both of which must fail loudly rather than silently
     *      valuing a position at nothing.
     */
    error ZeroMultiplier();

    /*//////////////////////////////////////////////////////////////////////////
                              RAW  ->  UI (share-equivalents)
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Convert raw token units to share-equivalents, rounding DOWN.
     * @dev Use when crediting a user: never credit more shares than are backed.
     *      This is the correct default for collateral valuation and for display.
     * @param rawAmount   Amount in raw token units, as `balanceOf` returns.
     * @param multiplier  ERC-8056 multiplier, 1e18-scaled. Must be non-zero.
     * @return uiAmount   Share-equivalents, rounded toward zero.
     */
    function toUIDown(uint256 rawAmount, uint256 multiplier) internal pure returns (uint256 uiAmount) {
        if (multiplier == 0) revert ZeroMultiplier();
        uiAmount = Math.mulDiv(rawAmount, multiplier, SCALE, Math.Rounding.Floor);
    }

    /**
     * @notice Convert raw token units to share-equivalents, rounding UP.
     * @dev Use when the result is a liability the user owes: never under-state it.
     * @param rawAmount   Amount in raw token units.
     * @param multiplier  ERC-8056 multiplier, 1e18-scaled. Must be non-zero.
     * @return uiAmount   Share-equivalents, rounded away from zero.
     */
    function toUIUp(uint256 rawAmount, uint256 multiplier) internal pure returns (uint256 uiAmount) {
        if (multiplier == 0) revert ZeroMultiplier();
        uiAmount = Math.mulDiv(rawAmount, multiplier, SCALE, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              UI (share-equivalents)  ->  RAW
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Convert share-equivalents to raw token units, rounding DOWN.
     * @dev Use when computing an amount to send OUT: transfer no more than owed.
     * @param uiAmount    Amount in share-equivalents.
     * @param multiplier  ERC-8056 multiplier, 1e18-scaled. Must be non-zero.
     * @return rawAmount  Raw token units, rounded toward zero.
     */
    function toRawDown(uint256 uiAmount, uint256 multiplier) internal pure returns (uint256 rawAmount) {
        if (multiplier == 0) revert ZeroMultiplier();
        rawAmount = Math.mulDiv(uiAmount, SCALE, multiplier, Math.Rounding.Floor);
    }

    /**
     * @notice Convert share-equivalents to raw token units, rounding UP.
     * @dev Use when computing an amount to pull IN: collect no less than due.
     * @param uiAmount    Amount in share-equivalents.
     * @param multiplier  ERC-8056 multiplier, 1e18-scaled. Must be non-zero.
     * @return rawAmount  Raw token units, rounded away from zero.
     */
    function toRawUp(uint256 uiAmount, uint256 multiplier) internal pure returns (uint256 rawAmount) {
        if (multiplier == 0) revert ZeroMultiplier();
        rawAmount = Math.mulDiv(uiAmount, SCALE, multiplier, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether a multiplier represents exactly 1.0, i.e. no corporate action applied.
     * @dev Useful as a fast path and, more importantly, as a test guard: an
     *      integration verified only at `1e18` has verified nothing. Every live
     *      Robinhood Stock Token read `1e18` until AAPL diverged on 2026-08-14.
     * @param multiplier ERC-8056 multiplier, 1e18-scaled.
     * @return True when `multiplier == SCALE`.
     */
    function isUnitMultiplier(uint256 multiplier) internal pure returns (bool) {
        return multiplier == SCALE;
    }
}
