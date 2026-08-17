// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3, ScaledPrice, ScaledUIOracle} from "../src/ScaledUIOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockScaledUIToken} from "./mocks/MockScaledUIToken.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice A plausible, wrong integration.
 *
 * @dev Nothing here is careless. It reads a Chainlink feed, checks the answer is
 *      positive, and converts the holder's balance into share-equivalents before
 *      valuing it -- which is exactly the thoughtful thing to do if you have just
 *      learned that ERC-8056 tokens have two units.
 *
 *      That last step is the bug. The feed's answer is ALREADY the price of one
 *      raw token, multiplier included. Applying `uiMultiplier` again squares it.
 *
 *      This is the code this repository exists to prevent, so it is kept here and
 *      run against the safe path rather than merely described.
 */
contract NaiveIntegration {
    IAggregatorV3 public immutable feed;
    MockScaledUIToken public immutable token;

    constructor(IAggregatorV3 feed_, MockScaledUIToken token_) {
        feed = feed_;
        token = token_;
    }

    /// @dev The mistake, in one line: `* token.uiMultiplier() / 1e18`.
    function valueOfHolder(address account) external view returns (uint256) {
        (, int256 price,,,) = feed.latestRoundData();
        require(price > 0, "bad price");

        uint256 shares = (token.balanceOf(account) * token.uiMultiplier()) / 1e18;
        // Safe: `price > 0` is required above. The bug in this contract is the
        // line before, not this cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (shares * uint256(price)) / 1e18;
    }
}

/**
 * @title DoubleCountDemoTest
 * @notice Demonstrates the double-counting trap and the paused-oracle trap.
 *
 * @dev Run it and read the logs:
 *
 *          forge test --match-contract DoubleCountDemo -vv
 */
contract DoubleCountDemoTest is Test {
    /// @dev Live AAPL multiplier as of 2026-08-14. ~1.000566.
    uint256 internal constant AAPL_MULTIPLIER = 1_000_566_080_061_092_436;

    /// @dev Chainlink equity feeds quote at 8 decimals. $220.00 per raw token.
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant PRICE = 220e8;

    address internal constant HOLDER = address(0xB0B);
    uint256 internal constant HOLDING = 1000e18; // 1000 raw AAPL tokens

    MockScaledUIToken internal token;
    MockAggregatorV3 internal feed;
    ScaledUIOracle internal safe;
    NaiveIntegration internal naive;

    function setUp() public {
        vm.warp(1_786_928_145); // 2026-08-17

        token = new MockScaledUIToken("Apple - Robinhood Token", "AAPL");
        token.mint(HOLDER, HOLDING);

        feed = new MockAggregatorV3(FEED_DECIMALS, PRICE, "AAPL / USD");
        safe = new ScaledUIOracle(IAggregatorV3(address(feed)), address(token), 1 hours);
        naive = new NaiveIntegration(IAggregatorV3(address(feed)), token);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        WHY NOBODY NOTICED UNTIL 2026-08-14
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev At a multiplier of exactly 1.0 the wrong and right implementations
    ///      agree to the wei. Every test written before the first corporate action
    ///      passed for both. This is the whole reason the bug is latent rather
    ///      than obvious.
    function test_AtUnityMultiplier_NaiveAndSafeAgreeExactly() public {
        uint256 naiveValue = naive.valueOfHolder(HOLDER);
        uint256 safeValue = safe.valueOfHolder(HOLDER);

        assertEq(naiveValue, safeValue, "at 1.0 the bug is invisible");
        assertEq(safeValue, 220_000e8, "1000 tokens x $220 = $220,000");

        emit log_named_uint("multiplier    ", token.uiMultiplier());
        emit log_named_uint("naive value   ", naiveValue);
        emit log_named_uint("safe  value   ", safeValue);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          THE TRAP, AT AAPL'S REAL MULTIPLIER
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The same code, the same holding, after the real 2026-08-14 action.
    ///      The naive integration now over-values the position by 5.66 bps.
    function test_AtLiveAaplMultiplier_NaiveOverValuesBy566Bps() public {
        token.applyImmediateAction(AAPL_MULTIPLIER);

        uint256 naiveValue = naive.valueOfHolder(HOLDER);
        uint256 safeValue = safe.valueOfHolder(HOLDER);

        assertGt(naiveValue, safeValue, "the naive path over-values the position");

        uint256 overageBps = ((naiveValue - safeValue) * 10_000) / safeValue;
        assertEq(overageBps, 5, "5.66 bps, truncated to 5");

        emit log_named_uint("multiplier      ", token.uiMultiplier());
        emit log_named_uint("naive value     ", naiveValue);
        emit log_named_uint("safe  value     ", safeValue);
        emit log_named_uint("over-valued by  ", naiveValue - safeValue);
        emit log_named_uint("over-valued bps ", overageBps);

        // The safe value is unchanged by the corporate action, which is correct:
        // the holder's raw balance did not move, and the feed already reflects the
        // action in its price.
        assertEq(safeValue, 220_000e8, "a corporate action must not change the raw valuation");
    }

    /// @dev The same bug after a 2:1 split: a 100% over-valuation. A lending market
    ///      using the naive path would let a borrower draw twice what their
    ///      collateral is worth.
    function test_AfterTwoForOneSplit_NaiveDoublesTheValuation() public {
        token.applyImmediateAction(2e18);

        uint256 naiveValue = naive.valueOfHolder(HOLDER);
        uint256 safeValue = safe.valueOfHolder(HOLDER);

        assertEq(naiveValue, 2 * safeValue, "a 2:1 split makes the naive path 100% wrong");

        emit log_named_uint("multiplier   ", token.uiMultiplier());
        emit log_named_uint("naive value  ", naiveValue);
        emit log_named_uint("safe  value  ", safeValue);
        emit log_named_string("verdict      ", "naive over-values by 100%");
    }

    /// @dev The error scales with the multiplier for every plausible value, so the
    ///      bug is not a rounding artefact -- it is squaring.
    function testFuzz_NaiveErrorIsExactlyTheSquaredMultiplier(uint256 multiplier) public {
        multiplier = bound(multiplier, 1e18, 100e18); // 1x .. 100x
        token.applyImmediateAction(multiplier);

        uint256 naiveValue = naive.valueOfHolder(HOLDER);
        uint256 safeValue = safe.valueOfHolder(HOLDER);

        // naive == safe * multiplier / 1e18, i.e. the multiplier applied twice.
        assertApproxEqRel(
            naiveValue,
            (safeValue * multiplier) / 1e18,
            1e12, // 0.0001%
            "the naive error is precisely one extra application of the multiplier"
        );
        assertGe(naiveValue, safeValue, "naive never under-values for multiplier >= 1");
    }

    /*//////////////////////////////////////////////////////////////////////////
                              THE PAUSED-ORACLE TRAP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev With `oraclePaused` set, the feed holds its last value. The Chainlink
    ///      response stays perfectly well-formed, so the naive path prices happily
    ///      against a mark the issuer has explicitly disowned. The safe path
    ///      refuses.
    function test_WhenOraclePaused_NaivePricesHappilyAndSafeReverts() public {
        token.setOraclePaused(true);
        feed.setHoldStale(true);

        // Nothing about the feed response signals a problem.
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = feed.latestRoundData();
        assertGt(answer, 0, "the held answer is still positive");
        assertEq(roundId, answeredInRound, "the round still looks complete");

        uint256 naiveValue = naive.valueOfHolder(HOLDER);
        assertEq(naiveValue, 220_000e8, "the naive path prices against a disowned mark");

        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.OraclePaused.selector, address(token)));
        safe.valueOfHolder(HOLDER);

        assertFalse(safe.isPriceUsable(), "and says so without reverting, if asked");

        emit log_named_uint("naive value while paused", naiveValue);
        emit log_named_string("safe  path              ", "reverted OraclePaused");
    }

    /// @dev The opt-out exists, is explicitly named, and reports the flag.
    function test_UnsafePathIsAvailableAndFlagsThePause() public {
        token.setOraclePaused(true);

        ScaledPrice memory p = safe.latestPriceUnsafe();
        assertTrue(p.oraclePaused, "the unsafe read must surface the flag");
        assertTrue(p.pausableKnown);
        assertEq(p.price, 220e8);
    }

    /// @dev Unpausing restores the safe path, so the guard is a gate and not a brick.
    function test_UnpausingRestoresTheSafePath() public {
        token.setOraclePaused(true);
        vm.expectRevert();
        safe.valueOfHolder(HOLDER);

        token.setOraclePaused(false);
        assertEq(safe.valueOfHolder(HOLDER), 220_000e8, "safe path recovers");
        assertTrue(safe.isPriceUsable());
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 CONVENTION CLARITY
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The multiplier IS reported, for display and reconciliation -- but the
    ///      price already includes it. The struct's documentation is the defence;
    ///      this test pins the relationship the documentation describes.
    function test_ReportedMultiplierIsContextNotAFactorToApply() public {
        token.applyImmediateAction(AAPL_MULTIPLIER);

        ScaledPrice memory p = safe.latestPrice();
        assertEq(p.multiplier, AAPL_MULTIPLIER, "context is reported");
        assertEq(p.price, 220e8, "price is per RAW token and already includes it");
        assertEq(p.decimals, FEED_DECIMALS, "precision travels with the value");

        // Applying it again is precisely the bug.
        uint256 doubleCounted = (p.price * p.multiplier) / 1e18;
        assertGt(doubleCounted, p.price, "this is what NOT to do");
    }
}
