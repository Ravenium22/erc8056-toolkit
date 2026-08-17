// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../src/ScaledUIMath.sol";
import {ScaledUIMathHarness} from "./harness/ScaledUIMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ScaledUIMathTest
 * @notice Property tests for the raw <-> UI conversion.
 *
 * @dev The invariants proved here ARE the contract the library offers. In
 *      particular the round trip is deliberately NOT asserted to be the identity:
 *      it is lossy by at most 1 wei per conversion, and an integrator who assumes
 *      exactness will write an accounting check that fails on dust.
 *
 *      `AAPL_MULTIPLIER` is the real value read from the canonical Robinhood AAPL
 *      token at block 38,417,371. It is included in every fixed-vector test
 *      because a suite that only exercises 1e18 proves nothing -- that was
 *      precisely the state of the world until 2026-08-14.
 */
contract ScaledUIMathTest is Test {
    using ScaledUIMath for uint256;

    uint256 internal constant SCALE = 1e18;

    /// @dev Live AAPL multiplier, 2026-08-14 corporate action. ~1.000566.
    uint256 internal constant AAPL_MULTIPLIER = 1_000_566_080_061_092_436;

    /// @dev See {ScaledUIMathHarness} -- needed so reverts occur at a lower call depth.
    ScaledUIMathHarness internal harness;

    function setUp() public {
        harness = new ScaledUIMathHarness();
    }

    /// @dev Multipliers spanning the plausible and the adversarial.
    function _vectors() internal pure returns (uint256[7] memory) {
        return [
            uint256(1), // smallest non-zero: 1e-18x
            SCALE - 1, // just below 1.0
            SCALE, // exactly 1.0
            AAPL_MULTIPLIER, // live value today
            2 * SCALE, // 2:1 split
            SCALE / 2, // 1:2 reverse split
            1e36 // 1e18x, absurd but must not corrupt
        ];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 ZERO MULTIPLIER
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_MultiplierIsZero_toUIDown() public {
        vm.expectRevert(ScaledUIMath.ZeroMultiplier.selector);
        harness.toUIDown(1e18, 0);
    }

    function test_RevertWhen_MultiplierIsZero_toUIUp() public {
        vm.expectRevert(ScaledUIMath.ZeroMultiplier.selector);
        harness.toUIUp(1e18, 0);
    }

    function test_RevertWhen_MultiplierIsZero_toRawDown() public {
        vm.expectRevert(ScaledUIMath.ZeroMultiplier.selector);
        harness.toRawDown(1e18, 0);
    }

    function test_RevertWhen_MultiplierIsZero_toRawUp() public {
        vm.expectRevert(ScaledUIMath.ZeroMultiplier.selector);
        harness.toRawUp(1e18, 0);
    }

    /// @dev Zero must revert even on a zero amount: the caller's multiplier read
    ///      failed, and returning 0 would launder that failure into a valid-looking
    ///      "this position is worth nothing".
    function testFuzz_RevertWhen_MultiplierIsZero_EvenForZeroAmount(uint256 amount) public {
        vm.expectRevert(ScaledUIMath.ZeroMultiplier.selector);
        harness.toUIDown(amount, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    IDENTITY
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev At 1.0 every conversion is exact in both directions, with no rounding
    ///      gap at all. This is why the bug class stayed invisible for so long.
    function testFuzz_UnitMultiplierIsExactIdentity(uint256 amount) public pure {
        assertEq(ScaledUIMath.toUIDown(amount, SCALE), amount, "toUIDown at 1.0");
        assertEq(ScaledUIMath.toUIUp(amount, SCALE), amount, "toUIUp at 1.0");
        assertEq(ScaledUIMath.toRawDown(amount, SCALE), amount, "toRawDown at 1.0");
        assertEq(ScaledUIMath.toRawUp(amount, SCALE), amount, "toRawUp at 1.0");
    }

    function test_IsUnitMultiplier() public pure {
        assertTrue(ScaledUIMath.isUnitMultiplier(SCALE));
        assertFalse(ScaledUIMath.isUnitMultiplier(AAPL_MULTIPLIER));
        assertFalse(ScaledUIMath.isUnitMultiplier(0));
    }

    /*//////////////////////////////////////////////////////////////////////////
                              ROUNDING DIRECTION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Up is never below down, and the two never differ by more than 1 wei.
    ///      Any wider gap means the rounding is not a single-ulp decision and the
    ///      "direction favours the protocol" reasoning no longer bounds the loss.
    function testFuzz_UpBoundsDownWithinOneWei(uint256 amount, uint256 multiplier) public pure {
        amount = bound(amount, 0, type(uint128).max);
        multiplier = bound(multiplier, 1, type(uint128).max);

        uint256 uiDown = ScaledUIMath.toUIDown(amount, multiplier);
        uint256 uiUp = ScaledUIMath.toUIUp(amount, multiplier);
        assertLe(uiDown, uiUp, "toUIDown must not exceed toUIUp");
        assertLe(uiUp - uiDown, 1, "toUI rounding gap must be at most 1 wei");

        uint256 rawDown = ScaledUIMath.toRawDown(amount, multiplier);
        uint256 rawUp = ScaledUIMath.toRawUp(amount, multiplier);
        assertLe(rawDown, rawUp, "toRawDown must not exceed toRawUp");
        assertLe(rawUp - rawDown, 1, "toRaw rounding gap must be at most 1 wei");
    }

    /// @dev An exact conversion leaves no gap at all -- up and down must agree.
    ///      Guards against a ceil implementation that adds 1 unconditionally.
    ///
    ///      The two directions divide by different denominators, so each needs its
    ///      own exactly-divisible input:
    ///        toUI  computes `amount * m / SCALE` -> exact when SCALE | amount
    ///        toRaw computes `amount * SCALE / m` -> exact when m     | amount
    function testFuzz_ExactConversionHasNoGap(uint256 k) public pure {
        k = bound(k, 0, type(uint128).max);
        uint256 multiplier = 3e18;

        uint256 uiExact = k * SCALE; // divisible by SCALE
        assertEq(
            ScaledUIMath.toUIDown(uiExact, multiplier),
            ScaledUIMath.toUIUp(uiExact, multiplier),
            "exact toUI must not round up"
        );

        uint256 rawExact = k * multiplier; // divisible by multiplier
        assertEq(
            ScaledUIMath.toRawDown(rawExact, multiplier),
            ScaledUIMath.toRawUp(rawExact, multiplier),
            "exact toRaw must not round up"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   ROUND TRIP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The safe round trip for value LEAVING the protocol: convert up on the
    ///      way out to shares, down on the way back to raw, and you can never
    ///      recover more raw than you started with.
    function testFuzz_RoundTripNeverInflates(uint256 raw, uint256 multiplier) public pure {
        raw = bound(raw, 0, type(uint128).max);
        multiplier = bound(multiplier, 1, type(uint128).max);

        uint256 back = ScaledUIMath.toRawDown(ScaledUIMath.toUIDown(raw, multiplier), multiplier);
        assertLe(back, raw, "down/down round trip must not inflate the raw amount");
    }

    /// @dev The mirror: rounding up on both legs never LOSES value, so a protocol
    ///      collecting a debt cannot under-collect through the conversion.
    function testFuzz_RoundTripUpNeverDeflates(uint256 raw, uint256 multiplier) public pure {
        raw = bound(raw, 0, type(uint128).max);
        multiplier = bound(multiplier, 1, type(uint128).max);

        uint256 back = ScaledUIMath.toRawUp(ScaledUIMath.toUIUp(raw, multiplier), multiplier);
        assertGe(back, raw, "up/up round trip must not deflate the raw amount");
    }

    /// @dev Round-trip error is bounded in absolute terms, not merely signed.
    ///      Bounded to realistic magnitudes: this is the claim an integrator can
    ///      rely on when writing a reconciliation check.
    function testFuzz_RoundTripErrorIsBounded(uint256 raw, uint256 multiplier) public pure {
        raw = bound(raw, 0, 1e30);
        multiplier = bound(multiplier, 1e15, 1e21); // 0.001x .. 1000x

        uint256 back = ScaledUIMath.toRawDown(ScaledUIMath.toUIDown(raw, multiplier), multiplier);
        uint256 err = raw > back ? raw - back : back - raw;

        // One ulp is lost per leg; the second leg's ulp is magnified by 1/multiplier.
        uint256 tolerance = 1 + Math_mulDivUp(SCALE, 1, multiplier);
        assertLe(err, tolerance, "round-trip error exceeds the documented bound");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    OVERFLOW
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The ERC requires `raw * multiplier` overflow to be handled. mulDiv
    ///      computes the 512-bit product first, so operands whose naive product
    ///      would overflow uint256 still convert cleanly as long as the RESULT
    ///      fits. A naive `raw * multiplier / SCALE` reverts on all of these.
    function testFuzz_NoSpuriousOverflowOnLargeOperands(uint256 raw) public pure {
        raw = bound(raw, 0, type(uint256).max / 2);
        uint256 multiplier = 2 * SCALE; // naive product overflows for raw > max/2e18

        uint256 ui = ScaledUIMath.toUIDown(raw, multiplier);
        assertEq(ui, raw * 2, "2:1 split must double the share count without overflowing");
    }

    /// @dev Concretely: a raw amount that CANNOT be squared into uint256 still
    ///      converts, because only the true result has to fit.
    function test_LargeOperandsThatOverflowNaively() public pure {
        uint256 raw = type(uint256).max / 1e17; // raw * 1e18 overflows uint256
        uint256 ui = ScaledUIMath.toUIDown(raw, SCALE);
        assertEq(ui, raw, "identity must survive operands whose naive product overflows");
    }

    /// @dev When the true result genuinely exceeds uint256, it must revert rather
    ///      than wrap. Failing loudly is correct here; a wrapped balance is not.
    function test_RevertWhen_ResultExceedsUint256() public {
        vm.expectRevert();
        harness.toUIDown(type(uint256).max, 2 * SCALE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              FIXED VECTORS (incl. live AAPL)
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Every invariant must hold across the full multiplier vector set, not
    ///      just at the value that happens to be live today.
    function testFuzz_InvariantsHoldAcrossVectors(uint256 raw, uint256 index) public pure {
        raw = bound(raw, 0, 1e30);
        uint256[7] memory ms = _vectors();
        uint256 multiplier = ms[bound(index, 0, ms.length - 1)];

        assertLe(ScaledUIMath.toUIDown(raw, multiplier), ScaledUIMath.toUIUp(raw, multiplier));
        assertLe(ScaledUIMath.toRawDown(raw, multiplier), ScaledUIMath.toRawUp(raw, multiplier));
        assertLe(ScaledUIMath.toRawDown(ScaledUIMath.toUIDown(raw, multiplier), multiplier), raw);
    }

    /// @dev The exact numbers from the live chain. One whole AAPL token is worth
    ///      more than one share today, and this is the arithmetic that makes it so.
    function test_LiveAaplVector() public pure {
        uint256 oneToken = 1e18;
        assertEq(ScaledUIMath.toUIDown(oneToken, AAPL_MULTIPLIER), AAPL_MULTIPLIER, "1 AAPL token in shares");
        assertGt(ScaledUIMath.toUIDown(oneToken, AAPL_MULTIPLIER), oneToken, "AAPL has diverged from 1.0");

        // The mainnet supply figures, reproduced from the conversion alone.
        uint256 totalSupply = 5_986_452_108_820_000_000_000;
        uint256 observedTotalSupplyUI = 5_989_840_919_995_487_767_925;
        assertApproxEqAbs(
            ScaledUIMath.toUIDown(totalSupply, AAPL_MULTIPLIER),
            observedTotalSupplyUI,
            1,
            "computed totalSupplyUI must match the value AAPL reports on chain"
        );
    }

    /// @dev A 2:1 split doubles share-equivalents and leaves raw balances untouched.
    function test_SplitDoublesSharesNotBalances() public pure {
        uint256 raw = 100e18;
        assertEq(ScaledUIMath.toUIDown(raw, SCALE), 100e18, "pre-split");
        assertEq(ScaledUIMath.toUIDown(raw, 2 * SCALE), 200e18, "post-split shares double");
        assertEq(ScaledUIMath.toRawDown(200e18, 2 * SCALE), raw, "raw balance is unchanged by the split");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function Math_mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        return (a * b + d - 1) / d;
    }
}
