// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAggregatorV3, ScaledPrice, ScaledUIOracle} from "../src/ScaledUIOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockPlainERC20} from "./mocks/MockPlainERC20.sol";
import {MockScaledUIToken} from "./mocks/MockScaledUIToken.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Validation, degradation and configuration behaviour of {ScaledUIOracle}.
/// @dev The double-counting and paused-oracle narratives live in
///      `DoubleCountDemo.t.sol`; this file covers the surrounding guards.
contract ScaledUIOracleTest is Test {
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant PRICE = 220e8;
    uint256 internal constant MAX_STALENESS = 1 hours;
    address internal constant HOLDER = address(0xB0B);

    MockScaledUIToken internal token;
    MockPlainERC20 internal plain;
    MockAggregatorV3 internal feed;
    ScaledUIOracle internal oracle;

    function setUp() public {
        vm.warp(1_786_928_145);

        token = new MockScaledUIToken("Apple - Robinhood Token", "AAPL");
        token.mint(HOLDER, 1000e18);

        plain = new MockPlainERC20("Global Dollar", "USDG", 18);
        plain.mint(HOLDER, 1000e18);

        feed = new MockAggregatorV3(FEED_DECIMALS, PRICE, "AAPL / USD");
        oracle = new ScaledUIOracle(IAggregatorV3(address(feed)), address(token), MAX_STALENESS);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTION
    //////////////////////////////////////////////////////////////////////////*/

    function test_ImmutablesAreSetFromConstructorOnly() public view {
        assertEq(address(oracle.feed()), address(feed));
        assertEq(oracle.token(), address(token));
        assertEq(oracle.maxStaleness(), MAX_STALENESS);
        assertEq(oracle.priceDecimals(), FEED_DECIMALS, "precision cached from the feed itself");
    }

    function test_RevertWhen_FeedIsZeroAddress() public {
        vm.expectRevert(ScaledUIOracle.ZeroAddress.selector);
        new ScaledUIOracle(IAggregatorV3(address(0)), address(token), MAX_STALENESS);
    }

    function test_RevertWhen_TokenIsZeroAddress() public {
        vm.expectRevert(ScaledUIOracle.ZeroAddress.selector);
        new ScaledUIOracle(IAggregatorV3(address(feed)), address(0), MAX_STALENESS);
    }

    /// @dev A zero staleness ceiling would reject every answer, including good
    ///      ones. Refuse the configuration rather than deploy a brick.
    function test_RevertWhen_StalenessIsZero() public {
        vm.expectRevert(ScaledUIOracle.ZeroStaleness.selector);
        new ScaledUIOracle(IAggregatorV3(address(feed)), address(token), 0);
    }

    /// @dev No owner, no setters: nothing about a deployed instance can change.
    function test_HasNoAdminSurface() public view {
        bytes4[4] memory forbidden = [
            bytes4(keccak256("owner()")),
            bytes4(keccak256("setMaxStaleness(uint256)")),
            bytes4(keccak256("setFeed(address)")),
            bytes4(keccak256("transferOwnership(address)"))
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(oracle).staticcall(abi.encodeWithSelector(forbidden[i]));
            assertFalse(ok, "ScaledUIOracle must expose no admin surface");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 ANSWER VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_HappyPath() public view {
        ScaledPrice memory p = oracle.latestPrice();
        assertEq(p.price, 220e8);
        assertEq(p.decimals, FEED_DECIMALS);
        assertEq(p.updatedAt, block.timestamp);
        assertEq(p.multiplier, 1e18);
        assertFalse(p.oraclePaused);
        assertTrue(p.pausableKnown);
    }

    function test_RevertWhen_PriceIsStale() public {
        uint256 published = block.timestamp;
        vm.warp(published + MAX_STALENESS + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ScaledUIOracle.StalePrice.selector, published, MAX_STALENESS + 1, MAX_STALENESS)
        );
        oracle.latestPrice();
    }

    /// @dev Exactly at the ceiling is still acceptable; the check is `>`, not `>=`.
    function test_PriceAtExactlyMaxStalenessIsAccepted() public {
        vm.warp(block.timestamp + MAX_STALENESS);
        assertEq(oracle.latestPrice().price, 220e8, "the boundary is inclusive");
    }

    function test_RevertWhen_PriceIsZero() public {
        feed.setRawAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.NonPositivePrice.selector, int256(0)));
        oracle.latestPrice();
    }

    function test_RevertWhen_PriceIsNegative() public {
        feed.setRawAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.NonPositivePrice.selector, int256(-1)));
        oracle.latestPrice();
    }

    function test_RevertWhen_RoundIsIncomplete() public {
        feed.setIncompleteRound();
        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.IncompleteRound.selector, uint80(2), uint80(1)));
        oracle.latestPrice();
    }

    /// @dev A future timestamp means the feed's clock is wrong; the answer cannot
    ///      be trusted and, unhandled, would underflow the age subtraction.
    function test_RevertWhen_UpdatedAtIsInTheFuture() public {
        uint256 future = block.timestamp + 1 days;
        feed.setUpdatedAt(future);
        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.FuturePrice.selector, future, block.timestamp));
        oracle.latestPrice();
    }

    /// @dev The unsafe path skips ONLY the pause check. It is not a bypass of the
    ///      sanity checks -- a stale answer is still refused.
    function test_UnsafePathStillEnforcesStaleness() public {
        token.setOraclePaused(true);
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        vm.expectRevert();
        oracle.latestPriceUnsafe();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  isPriceUsable
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Must agree with whether latestPrice() actually reverts, in every case.
    ///      A disagreement would send a router down a path that then reverts.
    function test_IsPriceUsableAgreesWithLatestPrice() public {
        _assertUsableAgrees("healthy");

        token.setOraclePaused(true);
        _assertUsableAgrees("paused");
        token.setOraclePaused(false);

        feed.setRawAnswer(0);
        _assertUsableAgrees("zero price");
        feed.setRawAnswer(PRICE);

        vm.warp(block.timestamp + MAX_STALENESS + 1);
        _assertUsableAgrees("stale");
    }

    function _assertUsableAgrees(string memory label) private view {
        bool usable = oracle.isPriceUsable();
        try oracle.latestPrice() returns (ScaledPrice memory) {
            assertTrue(usable, string.concat("isPriceUsable false but latestPrice succeeded: ", label));
        } catch {
            assertFalse(usable, string.concat("isPriceUsable true but latestPrice reverted: ", label));
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-ROBINHOOD TOKEN DEGRADATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev A plain ERC-20 has no `oraclePaused()`. That must read as "not
    ///      pausable", never as paused -- otherwise the wrapper is unusable for
    ///      the counter-asset in every stock-token pool.
    function test_PlainErc20IsNotPausableAndStillPrices() public {
        ScaledUIOracle o = new ScaledUIOracle(IAggregatorV3(address(feed)), address(plain), MAX_STALENESS);

        (bool paused, bool known) = o.oraclePaused();
        assertFalse(paused, "absent flag must not read as paused");
        assertFalse(known, "and the caller must be able to tell it is absent");

        ScaledPrice memory p = o.latestPrice();
        assertEq(p.price, 220e8);
        assertEq(p.multiplier, 1e18, "plain ERC-20 defaults to a unit multiplier");
        assertFalse(p.pausableKnown);
        assertTrue(o.isPriceUsable());
    }

    /// @dev A token whose `oraclePaused()` reverts must be treated the same way:
    ///      unknown, not paused, never bubbled.
    function test_RevertingOraclePausedDegradesToUnknown() public {
        token.setOraclePausedAbsent(true);

        (bool paused, bool known) = oracle.oraclePaused();
        assertFalse(paused);
        assertFalse(known);
        assertEq(oracle.latestPrice().price, 220e8, "must still price");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    VALUATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValueOfRawAndValueOfHolderAgree() public view {
        assertEq(oracle.valueOfRaw(1000e18), oracle.valueOfHolder(HOLDER), "same holding, same value");
        assertEq(oracle.valueOfRaw(1000e18), 220_000e8);
    }

    function test_ValueOfHolderIsZeroForNonHolder() public view {
        assertEq(oracle.valueOfHolder(address(0xDEAD)), 0);
    }

    /// @dev Valuation rounds DOWN, so it is subadditive rather than exactly
    ///      linear: `value(a) + value(b) <= value(a + b)`.
    ///
    ///      That direction is the one that matters. It means splitting a position
    ///      into pieces can never value it at MORE than valuing it whole, so a
    ///      caller cannot farm the rounding by fragmenting an operation. The gap
    ///      is bounded by one unit of the feed's precision per split.
    function testFuzz_ValuationIsSubadditive(uint256 a, uint256 b) public view {
        a = bound(a, 0, 1e30);
        b = bound(b, 0, 1e30);

        uint256 split = oracle.valueOfRaw(a) + oracle.valueOfRaw(b);
        uint256 whole = oracle.valueOfRaw(a + b);

        assertLe(split, whole, "splitting must never value a position at more than the whole");
        assertLe(whole - split, 1, "and the rounding gap is at most one unit");
    }

    /// @dev Zero in, zero out -- no phantom value from an empty position.
    function test_ValuationOfZeroIsZero() public view {
        assertEq(oracle.valueOfRaw(0), 0);
    }

    /// @dev A corporate action must NOT change the raw valuation: the holder's raw
    ///      balance did not move, and the feed already reflects the action.
    function testFuzz_CorporateActionDoesNotChangeRawValuation(uint256 multiplier) public {
        multiplier = bound(multiplier, 1e15, 1e21);
        uint256 before = oracle.valueOfHolder(HOLDER);

        token.applyImmediateAction(multiplier);

        assertEq(oracle.valueOfHolder(HOLDER), before, "raw valuation is invariant across a corporate action");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONTEXT
    //////////////////////////////////////////////////////////////////////////*/

    function test_ScaledContextExposesMultiplierAndPendingState() public {
        uint256 when = block.timestamp + 2 days;
        token.scheduleAction(2e18, when);

        assertTrue(oracle.scaledContext().changePending, "pending change is visible to a consumer");
        assertEq(oracle.scaledContext().effectiveAt, when);

        // A quote straddling `effectiveAt` is the case to refuse. The oracle
        // surfaces the information; the policy belongs to the integrator.
        assertTrue(oracle.isPriceUsable(), "a pending change does not itself invalidate the price");
    }
}
