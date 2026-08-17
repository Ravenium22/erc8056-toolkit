// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "./ScaledUIMath.sol";
import {
    ERC8056InterfaceIds,
    IERC8056Scheduled,
    IScaledUIAmount,
    IScaledUIAmountBalances,
    IScaledUIAmountNewUIMultiplier
} from "./interfaces/IERC8056.sol";

/**
 * @notice The result of a single ERC-8056 read.
 * @dev Every field comes from ONE read of the token at ONE point in time. That is
 *      the point of the struct: the multiplier travels with the amounts it was
 *      used to derive, so a caller can never apply it a second time, and can never
 *      pair a `uiAmount` with a multiplier fetched separately a block later.
 *
 * @param rawAmount     Token units -- what `balanceOf` returns and `transfer` moves.
 *                      USE THIS FOR ACCOUNTING.
 * @param uiAmount      Share-equivalents. Use for display and share-denominated quoting.
 * @param multiplier    The 1e18-scaled multiplier in force. Exactly `1e18` when
 *                      `isScaled` is false.
 * @param isScaled      Whether the token implements ERC-8056 at all.
 * @param changePending Whether a corporate action is GENUINELY scheduled in the
 *                      future. See {ScaledUIReader-readScaled} for why this is not
 *                      the obvious computation.
 * @param effectiveAt   When the pending change takes effect. Zero unless `changePending`.
 */
struct ScaledRead {
    uint256 rawAmount;
    uint256 uiAmount;
    uint256 multiplier;
    bool isScaled;
    bool changePending;
    uint256 effectiveAt;
}

/**
 * @title ScaledUIReader
 * @notice Safe reads of ERC-8056 tokens for consuming protocols.
 * @author erc8056-toolkit
 *
 * @dev THE TWO GUARANTEES
 *
 *      1. It never reverts because of the token. A non-compliant token, a token
 *         with no ERC-165, a token whose `supportsInterface` reverts or lies, a
 *         token that is not a contract at all -- each degrades to
 *         `isScaled = false, multiplier = 1e18` and a correct raw balance.
 *         Reverting on a plain ERC-20 would make this library unusable in the
 *         pools where stock tokens actually trade, since the other side of every
 *         pair (USDG, WETH) is a plain ERC-20.
 *
 *      2. It reads once. The multiplier is returned alongside the values derived
 *         from it, so the caller has nothing left to apply.
 *
 * @dev WHAT IT DELIBERATELY DOES NOT DO
 *
 *      No caching, no storage, no `block.timestamp`-dependent branching beyond the
 *      pending check. It is a `library` of `internal` functions: it links into the
 *      caller, so there is no deployment to trust and no address to get wrong.
 *
 *      It does not call `toUIAmount`/`fromUIAmount` (`IScaledUIAmountConversion`),
 *      because Robinhood Stock Tokens do not implement them --
 *      `supportsInterface(0x57854fc3)` returns false. Conversion goes through
 *      {ScaledUIMath}.
 *
 * @dev GAS
 *
 *      Every external call is a bounded-gas `staticcall`. A token cannot grief a
 *      consumer by burning the caller's gas in `supportsInterface`, which matters
 *      because the whole point is to call untrusted token contracts.
 */
library ScaledUIReader {
    /// @dev Gas ceiling for each probe. Ample for a storage read plus dispatch;
    ///      far too little for a griefing loop.
    uint256 private constant PROBE_GAS = 30_000;

    /*//////////////////////////////////////////////////////////////////////////
                                  PUBLIC ENTRY POINTS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Read `account`'s balance together with the multiplier context.
     * @param token   The token to read. Need not be ERC-8056, or even a contract.
     * @param account The holder.
     * @return r      A complete, self-consistent {ScaledRead}.
     */
    function readBalance(address token, address account) internal view returns (ScaledRead memory r) {
        r = readScaled(token);
        r.rawAmount = _rawBalanceOf(token, account);
        r.uiAmount = _uiFor(token, r, _uiBalanceSelector(), abi.encode(account));
    }

    /**
     * @notice Read total supply together with the multiplier context.
     * @param token The token to read.
     * @return r    A complete, self-consistent {ScaledRead}.
     */
    function readTotalSupply(address token) internal view returns (ScaledRead memory r) {
        r = readScaled(token);
        r.rawAmount = _rawTotalSupply(token);
        r.uiAmount = _uiFor(token, r, _uiSupplySelector(), "");
    }

    /**
     * @notice Read only the multiplier context, with no amounts.
     * @dev `rawAmount` and `uiAmount` are left zero.
     *
     *      THE PENDING-CHANGE RULE. This is the subtle part of the whole library.
     *
     *      `newUIMultiplier()` and `effectiveAt()` are plain storage and are NOT
     *      cleared once a change has been applied. On live AAPL right now:
     *
     *          uiMultiplier()    = 1000566080061092436
     *          newUIMultiplier() = 1000566080061092436   (identical, already applied)
     *          effectiveAt()     = 1786720366            (2026-08-14, in the past)
     *
     *      So both obvious tests are WRONG:
     *
     *          newUIMultiplier() != 0   -> reports pending. False positive.
     *          effectiveAt()     != 0   -> reports pending. False positive.
     *
     *      A protocol that halts on `changePending` would, using either, refuse
     *      every AAPL position from 2026-08-14 onward -- a permanent denial of
     *      service dressed up as a safety feature.
     *
     *      A change is pending only when BOTH hold:
     *
     *          newUIMultiplier() != uiMultiplier()   AND   effectiveAt() > block.timestamp
     *
     *      When the token implements BEP-677's {IERC8056Scheduled}, its
     *      `hasPendingMultiplier()` is authoritative and is preferred; that
     *      extension exists precisely to remove this ambiguity, but it is absent
     *      on Robinhood Chain.
     *
     * @param token The token to read.
     * @return r    Multiplier context. `multiplier` is `1e18` for a plain ERC-20.
     */
    function readScaled(address token) internal view returns (ScaledRead memory r) {
        r.multiplier = ScaledUIMath.SCALE;

        if (!_supportsInterface(token, ERC8056InterfaceIds.SCALED_UI_AMOUNT)) {
            return r; // plain ERC-20: isScaled false, multiplier 1e18
        }

        (bool ok, uint256 current) = _readUint(token, abi.encodeCall(IScaledUIAmount.uiMultiplier, ()));

        // Claims ERC-8056 but cannot answer, or answers zero. A zero multiplier
        // would make every conversion revert or value the position at nothing, so
        // treat the token as unscaled rather than propagating a number we know is
        // wrong. Reported via `isScaled == false`.
        if (!ok || current == 0) return r;

        r.isScaled = true;
        r.multiplier = current;

        (r.changePending, r.effectiveAt) = _pendingChange(token, current);
    }

    /**
     * @notice Whether a genuinely future corporate action is scheduled.
     * @dev Convenience over {readScaled}. See that function for why the obvious
     *      implementation is wrong.
     */
    function isMultiplierPending(address token) internal view returns (bool) {
        return readScaled(token).changePending;
    }

    /**
     * @notice Seconds until the pending change takes effect.
     * @return Zero when nothing is pending -- never a misleading countdown derived
     *         from a stale `effectiveAt`.
     */
    function secondsUntilEffective(address token) internal view returns (uint256) {
        ScaledRead memory r = readScaled(token);
        if (!r.changePending) return 0;
        return r.effectiveAt - block.timestamp; // > 0 by the pending rule
    }

    /**
     * @notice The multiplier alone, defaulting to `1e18` for non-ERC-8056 tokens.
     * @dev Prefer {readScaled} or {readBalance}: taking the multiplier on its own
     *      is what makes it possible to apply it twice.
     */
    function multiplierOf(address token) internal view returns (uint256) {
        return readScaled(token).multiplier;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               PENDING-CHANGE DETECTION
    //////////////////////////////////////////////////////////////////////////*/

    function _pendingChange(address token, uint256 current)
        internal
        view
        returns (bool changePending, uint256 effectiveAt)
    {
        // BEP-677 path. Authoritative where available -- no inference needed.
        (bool hasOk, bool has) = _readBool(token, abi.encodeCall(IERC8056Scheduled.hasPendingMultiplier, ()));
        if (hasOk) {
            if (!has) return (false, 0);
            (bool pOk, uint256 pending) = _readUintAt(token, abi.encodeCall(IERC8056Scheduled.pendingMultiplier, ()), 1);
            if (pOk && pending > block.timestamp) return (true, pending);
            // Claims pending but will not say when: fall through to inference
            // rather than reporting a pending change with no timestamp.
        }

        // ERC-8056 path. Requires BOTH conditions -- see {readScaled}.
        if (!_supportsInterface(token, ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW)) return (false, 0);

        (bool nOk, uint256 next) = _readUint(token, abi.encodeCall(IScaledUIAmountNewUIMultiplier.newUIMultiplier, ()));
        if (!nOk || next == current) return (false, 0);

        (bool eOk, uint256 when) = _readUint(token, abi.encodeCall(IScaledUIAmountNewUIMultiplier.effectiveAt, ()));
        if (!eOk || when <= block.timestamp) return (false, 0);

        return (true, when);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    UI AMOUNTS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Prefer the token's own `balanceOfUI`/`totalSupplyUI` when it advertises
     *      `IScaledUIAmountBalances`: the token is the authority on its own
     *      rounding, and a locally computed figure that disagrees with what the
     *      token reports is a reconciliation bug waiting to happen.
     *
     *      Falls back to {ScaledUIMath} (rounding DOWN, the safe direction for a
     *      credited balance) when the extension is absent or the call fails.
     */
    function _uiFor(address token, ScaledRead memory r, bytes4 selector, bytes memory args)
        private
        view
        returns (uint256)
    {
        if (!r.isScaled) return r.rawAmount; // multiplier is exactly 1e18

        if (_supportsInterface(token, ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES)) {
            (bool ok, uint256 value) = _readUint(token, bytes.concat(selector, args));
            if (ok) return value;
        }

        return ScaledUIMath.toUIDown(r.rawAmount, r.multiplier);
    }

    function _uiBalanceSelector() private pure returns (bytes4) {
        return IScaledUIAmountBalances.balanceOfUI.selector;
    }

    function _uiSupplySelector() private pure returns (bytes4) {
        return IScaledUIAmountBalances.totalSupplyUI.selector;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  LOW-LEVEL PROBES
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev ERC-165 probe that treats every failure mode as "unsupported".
     *
     *      Rejects a token that returns true for the `0xffffffff` sentinel. ERC-165
     *      requires that ID to be false; a token answering true is answering
     *      unconditionally, so its answer for any other ID carries no information.
     *      Without this check such a token would be read as supporting every
     *      extension, and the reader would call functions that do not exist.
     */
    function _supportsInterface(address token, bytes4 id) private view returns (bool) {
        if (token.code.length == 0) return false;

        (bool ok, bool supported) =
            _readBool(token, abi.encodeWithSelector(ERC8056InterfaceIds.ERC165, ERC8056InterfaceIds.ERC165_INVALID));
        if (ok && supported) return false; // answers true for everything -- useless

        (bool ok2, bool has) = _readBool(token, abi.encodeWithSelector(ERC8056InterfaceIds.ERC165, id));
        return ok2 && has;
    }

    function _readUint(address token, bytes memory data) private view returns (bool ok, uint256 value) {
        return _readUintAt(token, data, 0);
    }

    /**
     * @dev Static-call `token` and decode the word at `wordIndex` of the return
     *      data. `wordIndex` exists for tuple returns such as
     *      `pendingMultiplier() -> (uint256, uint256)`.
     *
     *      Returns `ok = false` rather than reverting on: a non-contract, a
     *      revert, or return data too short to contain the requested word. A short
     *      return is a real hazard -- `abi.decode` on it would revert and defeat
     *      the never-reverts guarantee.
     */
    function _readUintAt(address token, bytes memory data, uint256 wordIndex)
        private
        view
        returns (bool ok, uint256 value)
    {
        if (token.code.length == 0) return (false, 0);

        (bool success, bytes memory ret) = token.staticcall{gas: PROBE_GAS}(data);
        if (!success || ret.length < 32 * (wordIndex + 1)) return (false, 0);

        assembly ("memory-safe") {
            value := mload(add(ret, add(0x20, mul(0x20, wordIndex))))
        }
        return (true, value);
    }

    /**
     * @dev As {_readUintAt}, decoding a bool. A word other than 0 or 1 is rejected
     *      rather than coerced: a token returning 0x02 for a bool is malformed, and
     *      guessing what it meant is worse than treating it as unreadable.
     */
    function _readBool(address token, bytes memory data) private view returns (bool ok, bool value) {
        (bool got, uint256 word) = _readUintAt(token, data, 0);
        if (!got || word > 1) return (false, false);
        return (true, word == 1);
    }

    function _rawBalanceOf(address token, address account) private view returns (uint256) {
        (, uint256 value) = _readUint(token, abi.encodeWithSignature("balanceOf(address)", account));
        return value;
    }

    function _rawTotalSupply(address token) private view returns (uint256) {
        (, uint256 value) = _readUint(token, abi.encodeWithSignature("totalSupply()"));
        return value;
    }
}
