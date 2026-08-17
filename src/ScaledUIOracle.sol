// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledRead, ScaledUIReader} from "./ScaledUIReader.sol";
import {IRobinhoodOraclePausable} from "./interfaces/IERC8056.sol";

/// @notice The subset of Chainlink's AggregatorV3Interface this wrapper needs.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @notice A price reading with its convention attached.
 *
 * @dev The convention travels WITH the number, because the entire bug class this
 *      contract addresses comes from a bare `uint256` whose units were ambiguous.
 *
 * @param price          USD per ONE RAW TOKEN, at `decimals` precision.
 *                       THE CORPORATE-ACTION MULTIPLIER IS ALREADY INCLUDED.
 *                       Do NOT multiply by `uiMultiplier()`.
 * @param decimals       Fixed-point precision of `price`, from the feed itself.
 * @param updatedAt      When the feed last published.
 * @param multiplier     The token's multiplier at read time. Provided for display
 *                       and reconciliation ONLY -- it is already baked into `price`.
 * @param oraclePaused   Whether the issuer has flagged this price as unreliable.
 *                       Always false from the safe path, which reverts instead.
 * @param pausableKnown  False when the token has no `oraclePaused()` at all, so a
 *                       caller can tell "not paused" from "cannot tell".
 */
struct ScaledPrice {
    uint256 price;
    uint8 decimals;
    uint256 updatedAt;
    uint256 multiplier;
    bool oraclePaused;
    bool pausableKnown;
}

/**
 * @title ScaledUIOracle
 * @notice A Chainlink wrapper for ERC-8056 stock tokens that refuses to hand back
 *         a price you should not be using.
 * @author erc8056-toolkit
 *
 * @dev GAP 1 -- DOUBLE-COUNTING THE MULTIPLIER
 *
 *      Chainlink's Robinhood tokenized-equity feeds publish
 *
 *          answer = underlying equity market price * uiMultiplier
 *
 *      with the multiplier ALREADY APPLIED, read by the oracle from the token
 *      itself. The answer is the price of one RAW token.
 *
 *      Because the field is named `uiMultiplier`, the natural next step for an
 *      integrator thinking in shares is to apply it again -- which squares it.
 *      On AAPL today that over-values a position by 5.66 basis points. After a
 *      2:1 split it over-values it by 100%.
 *
 *      Nothing reverts. At a multiplier of exactly 1.0 the wrong and right
 *      versions return IDENTICAL values, so the bug passes every test written
 *      before a corporate action occurs.
 *
 *      This contract removes the ambiguity by construction: it returns
 *      {ScaledPrice}, whose documentation states the convention, and there is no
 *      accessor that hands back a bare number for a caller to reinterpret.
 *
 * @dev GAP 2 -- `oraclePaused` IS ADVISORY
 *
 *      Robinhood tokens expose `oraclePaused()`, set when a price is unreliable
 *      (dividends, splits). The feed honours it by ceasing to publish and HOLDING
 *      its last value. Nothing on chain enforces it.
 *
 *      From a consumer's perspective during that window, `latestRoundData()`
 *      succeeds, the answer is positive, and `roundId == answeredInRound`. There
 *      is no signal in the Chainlink response at all. A staleness check does not
 *      reliably save you either: it cannot distinguish a deliberately paused feed
 *      from a broken one, and a generous threshold passes a held price outright.
 *
 *      {latestPrice} therefore REVERTS on the flag. {latestPriceUnsafe} is the
 *      opt-out, named so that it is visible in review and in a diff.
 *
 * @dev DESIGN
 *
 *      Ownerless. No admin keys, no upgrade path, no setters. Every parameter is a
 *      constructor immutable, so what a reviewer reads at deployment is what runs
 *      forever. One wrapper instance per (feed, token) pair.
 */
contract ScaledUIOracle {
    /*//////////////////////////////////////////////////////////////////////////
                                    IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The Chainlink aggregator. Its answer already includes the multiplier.
    IAggregatorV3 public immutable feed;

    /// @notice The ERC-8056 token this feed prices.
    address public immutable token;

    /// @notice Maximum age of a feed answer, in seconds, before it is rejected.
    uint256 public immutable maxStaleness;

    /// @notice Fixed-point precision of {ScaledPrice-price}, cached from the feed.
    uint8 public immutable priceDecimals;

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The issuer has flagged this token's price as unreliable.
    /// @dev The flag Robinhood publishes but does not enforce. Enforced here.
    error OraclePaused(address token);

    /// @notice The feed's answer is older than {maxStaleness}.
    /// @param updatedAt    When the feed last published.
    /// @param age          How old that is now, in seconds.
    /// @param maxStaleness The configured ceiling.
    error StalePrice(uint256 updatedAt, uint256 age, uint256 maxStaleness);

    /// @notice The feed returned a zero or negative answer. Never a valid price.
    error NonPositivePrice(int256 answer);

    /// @notice The feed returned an answer from an earlier round than it reports.
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);

    /// @notice The feed reports a timestamp in the future. The clock is wrong.
    error FuturePrice(uint256 updatedAt, uint256 nowTimestamp);

    error ZeroAddress();
    error ZeroStaleness();

    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @param feed_         Chainlink aggregator for this token.
     * @param token_        The ERC-8056 token. May be a plain ERC-20, in which
     *                      case the multiplier reads as `1e18` and the pause flag
     *                      as unknown.
     * @param maxStaleness_ Maximum answer age in seconds. Choose from the feed's
     *                      heartbeat, not from convenience: too generous and a
     *                      paused-and-held price sails through the staleness
     *                      check, leaving {OraclePaused} as the only thing
     *                      standing between you and a frozen mark.
     */
    constructor(IAggregatorV3 feed_, address token_, uint256 maxStaleness_) {
        if (address(feed_) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (maxStaleness_ == 0) revert ZeroStaleness();

        feed = feed_;
        token = token_;
        maxStaleness = maxStaleness_;
        priceDecimals = feed_.decimals();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   THE SAFE PATH
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The current price, or a revert.
     * @dev Reverts when the issuer has paused the oracle, or the answer is stale,
     *      non-positive, from an incomplete round, or timestamped in the future.
     *      Returning a flagged struct instead would just relocate the decision to
     *      a caller who, by construction, is not thinking about it.
     * @return p USD per raw token, multiplier already included.
     */
    function latestPrice() public view returns (ScaledPrice memory p) {
        (bool paused, bool known) = _oraclePaused();
        if (paused) revert OraclePaused(token);

        (uint256 price, uint256 updatedAt) = _validatedAnswer();

        p = ScaledPrice({
            price: price,
            decimals: priceDecimals,
            updatedAt: updatedAt,
            multiplier: ScaledUIReader.multiplierOf(token),
            oraclePaused: false,
            pausableKnown: known
        });
    }

    /**
     * @notice USD value of a raw token amount.
     * @dev The correct one-line integration. The multiplier appears nowhere,
     *      because the feed already applied it.
     * @param rawAmount Amount in raw token units, as `balanceOf` returns.
     * @return value    Value at {priceDecimals} precision, scaled by the token's
     *                  own 18 decimals. Every Robinhood Stock Token is 18-decimal.
     */
    function valueOfRaw(uint256 rawAmount) public view returns (uint256 value) {
        ScaledPrice memory p = latestPrice();
        return _value(rawAmount, p.price);
    }

    /**
     * @notice USD value of an account's holding.
     * @dev Reads the balance and the price through the safe paths, so neither the
     *      pause flag nor the multiplier convention can be sidestepped.
     */
    function valueOfHolder(address account) external view returns (uint256 value) {
        ScaledRead memory r = ScaledUIReader.readBalance(token, account);
        ScaledPrice memory p = latestPrice();
        return _value(r.rawAmount, p.price);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  THE OPT-OUT
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The current price WITHOUT enforcing the pause flag.
     *
     * @dev Deliberately named so that it is conspicuous at the call site and in
     *      review. Valid uses are narrow: displaying a last-known mark clearly
     *      labelled as such, or a liquidation path that has independently decided
     *      a frozen price is preferable to no price.
     *
     *      Do NOT use it to open positions, quote swaps, or value collateral. If
     *      `oraclePaused` is set, the issuer is telling you this number is wrong.
     *
     *      Still enforces staleness, positivity and round completeness -- opting
     *      out of the pause check is not opting out of sanity checks. Inspect
     *      {ScaledPrice-oraclePaused} on the result.
     */
    function latestPriceUnsafe() public view returns (ScaledPrice memory p) {
        (bool paused, bool known) = _oraclePaused();
        (uint256 price, uint256 updatedAt) = _validatedAnswer();

        p = ScaledPrice({
            price: price,
            decimals: priceDecimals,
            updatedAt: updatedAt,
            multiplier: ScaledUIReader.multiplierOf(token),
            oraclePaused: paused,
            pausableKnown: known
        });
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    INSPECTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Whether {latestPrice} would revert right now, without reverting.
    /// @dev For a router deciding whether to route, or a keeper deciding to wait.
    function isPriceUsable() external view returns (bool) {
        (bool paused,) = _oraclePaused();
        if (paused) return false;

        (bool ok,,) = _tryAnswer();
        return ok;
    }

    /// @notice The issuer's pause flag, and whether the token exposes one at all.
    /// @return paused Whether the flag is set. False when unknown.
    /// @return known  False when the token has no `oraclePaused()`.
    function oraclePaused() external view returns (bool paused, bool known) {
        return _oraclePaused();
    }

    /// @notice The token's multiplier context, for display and reconciliation.
    /// @dev Provided so a UI can show share-equivalents. It is ALREADY included in
    ///      {ScaledPrice-price} -- do not apply it to a price from this contract.
    function scaledContext() external view returns (ScaledRead memory) {
        return ScaledUIReader.readScaled(token);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    INTERNALS
    //////////////////////////////////////////////////////////////////////////*/

    function _value(uint256 rawAmount, uint256 price) private pure returns (uint256) {
        // Rounds DOWN: this values a holding, and a valuation should never credit
        // more than is held. See ScaledUIMath's rounding rule.
        return (rawAmount * price) / 1e18;
    }

    /// @dev Validates the feed answer, reverting with a specific error per failure
    ///      so an operator can tell a paused feed from a broken one.
    function _validatedAnswer() private view returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer, uint256 answeredAt, uint80 answeredInRound) = _rawAnswer();

        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);
        if (answer <= 0) revert NonPositivePrice(answer);
        // Oracle freshness is a wall-clock property; block.timestamp is the only
        // clock available to compare a feed's `updatedAt` against. Sequencer drift
        // is orders of magnitude below any sane `maxStaleness`.
        if (answeredAt > block.timestamp) revert FuturePrice(answeredAt, block.timestamp);

        uint256 age = block.timestamp - answeredAt;
        if (age > maxStaleness) revert StalePrice(answeredAt, age, maxStaleness);

        // Safe: `answer <= 0` reverted above, so `answer` is strictly positive and
        // the int256 -> uint256 cast cannot change its value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(answer), answeredAt);
    }

    /// @dev Non-reverting mirror of {_validatedAnswer}, for {isPriceUsable}.
    function _tryAnswer() private view returns (bool ok, uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer, uint256 answeredAt, uint80 answeredInRound) = _rawAnswer();

        if (answeredInRound < roundId) return (false, 0, answeredAt);
        if (answer <= 0) return (false, 0, answeredAt);
        // Mirrors {_validatedAnswer}; same reasoning, same clock.
        if (answeredAt > block.timestamp) return (false, 0, answeredAt);
        if (block.timestamp - answeredAt > maxStaleness) return (false, 0, answeredAt);

        // Safe: `answer <= 0` returned early above, so `answer` is strictly positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, uint256(answer), answeredAt);
    }

    function _rawAnswer()
        private
        view
        returns (uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer,, updatedAt, answeredInRound) = feed.latestRoundData();
    }

    /**
     * @dev `oraclePaused()` is Robinhood-specific and NOT discoverable via
     *      ERC-165, so it is probed with a bounded-gas staticcall.
     *
     *      A token without it is "not pausable", NOT "paused" -- treating an
     *      absent flag as paused would brick every plain ERC-20 pairing. It is
     *      also never a revert: bubbling here would make the wrapper unusable for
     *      the counter-asset in every stock-token pool.
     *
     *      A malformed word (neither 0 nor 1) is treated as unknown rather than
     *      coerced to true.
     */
    function _oraclePaused() private view returns (bool paused, bool known) {
        if (token.code.length == 0) return (false, false);

        (bool success, bytes memory ret) =
            token.staticcall{gas: 30_000}(abi.encodeCall(IRobinhoodOraclePausable.oraclePaused, ()));

        if (!success || ret.length < 32) return (false, false);

        uint256 word = abi.decode(ret, (uint256));
        if (word > 1) return (false, false);

        return (word == 1, true);
    }
}
