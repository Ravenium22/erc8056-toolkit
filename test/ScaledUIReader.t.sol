// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../src/ScaledUIMath.sol";
import {ScaledRead, ScaledUIReader} from "../src/ScaledUIReader.sol";
import {ERC8056InterfaceIds} from "../src/interfaces/IERC8056.sol";
import {MockPlainERC20} from "./mocks/MockPlainERC20.sol";
import {MockScaledUIToken} from "./mocks/MockScaledUIToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev External wrapper: `ScaledUIReader` is a library of internal functions, so
///      its calls inline into the test. Routing through a contract gives reverts
///      somewhere to happen and models how a real consumer uses it.
contract ReaderConsumer {
    function readBalance(address token, address account) external view returns (ScaledRead memory) {
        return ScaledUIReader.readBalance(token, account);
    }

    function readTotalSupply(address token) external view returns (ScaledRead memory) {
        return ScaledUIReader.readTotalSupply(token);
    }

    function readScaled(address token) external view returns (ScaledRead memory) {
        return ScaledUIReader.readScaled(token);
    }

    function isMultiplierPending(address token) external view returns (bool) {
        return ScaledUIReader.isMultiplierPending(token);
    }

    function secondsUntilEffective(address token) external view returns (uint256) {
        return ScaledUIReader.secondsUntilEffective(token);
    }

    function multiplierOf(address token) external view returns (uint256) {
        return ScaledUIReader.multiplierOf(token);
    }
}

/// @dev The naive implementations this library exists to replace. Kept in the
///      test suite so the claim "the obvious version is wrong" is demonstrated
///      rather than asserted.
library NaiveDetection {
    function pendingByNonZeroNew(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("newUIMultiplier()"));
        return ok && abi.decode(ret, (uint256)) != 0;
    }

    function pendingByNonZeroEffectiveAt(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("effectiveAt()"));
        return ok && abi.decode(ret, (uint256)) != 0;
    }
}

contract ScaledUIReaderTest is Test {
    /// @dev Live AAPL multiplier, applied 2026-08-14.
    uint256 internal constant AAPL_MULTIPLIER = 1_000_566_080_061_092_436;
    uint256 internal constant SCALE = 1e18;

    ReaderConsumer internal consumer;
    MockScaledUIToken internal aapl;
    MockPlainERC20 internal usdg;

    address internal constant HOLDER = address(0xB0B);

    function setUp() public {
        consumer = new ReaderConsumer();

        aapl = new MockScaledUIToken("Apple - Robinhood Token", "AAPL");
        aapl.mint(HOLDER, 100e18);

        usdg = new MockPlainERC20("Global Dollar", "USDG", 18);
        usdg.mint(HOLDER, 5000e18);

        // Timestamps must exceed the real effectiveAt for the live-state tests.
        vm.warp(1_786_928_145); // 2026-08-17
    }

    /*//////////////////////////////////////////////////////////////////////////
             THE HEADLINE: NAIVE PENDING DETECTION FAILS ON LIVE AAPL STATE
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Reproduces AAPL exactly as it reads on mainnet today:
     *          uiMultiplier()    == newUIMultiplier()   (change already applied)
     *          effectiveAt()     == a PAST timestamp    (never cleared)
     *
     *      Both naive tests report a pending change. There is none.
     */
    function test_NaivePendingDetectionFalsePositives_OnLiveAaplState() public {
        vm.warp(1_786_720_366); // the real effectiveAt
        aapl.applyImmediateAction(AAPL_MULTIPLIER);
        vm.warp(1_786_928_145); // ~2.4 days later, as now

        // Sanity: the mock really is in AAPL's live state.
        assertEq(aapl.uiMultiplier(), AAPL_MULTIPLIER, "multiplier applied");
        assertEq(aapl.newUIMultiplier(), aapl.uiMultiplier(), "new == current, as on chain");
        assertEq(aapl.effectiveAt(), 1_786_720_366, "effectiveAt is in the past, as on chain");
        assertLt(aapl.effectiveAt(), block.timestamp, "effectiveAt has passed");

        // The two obvious implementations. Both wrong.
        assertTrue(
            NaiveDetection.pendingByNonZeroNew(address(aapl)),
            "naive `newUIMultiplier() != 0` claims a change is pending"
        );
        assertTrue(
            NaiveDetection.pendingByNonZeroEffectiveAt(address(aapl)),
            "naive `effectiveAt() != 0` claims a change is pending"
        );

        // The library. Correct.
        assertFalse(
            consumer.isMultiplierPending(address(aapl)),
            "ScaledUIReader must NOT report a pending change: it already happened"
        );
        assertEq(consumer.secondsUntilEffective(address(aapl)), 0, "no countdown for an applied change");

        ScaledRead memory r = consumer.readScaled(address(aapl));
        assertTrue(r.isScaled);
        assertEq(r.multiplier, AAPL_MULTIPLIER);
        assertFalse(r.changePending);
        assertEq(r.effectiveAt, 0, "effectiveAt must be zeroed when nothing is pending");
    }

    /// @dev The mirror: a genuinely scheduled change must be detected.
    function test_GenuinelyPendingChangeIsDetected() public {
        uint256 when = block.timestamp + 3 days;
        aapl.scheduleAction(2 * SCALE, when);

        ScaledRead memory r = consumer.readScaled(address(aapl));
        assertTrue(r.changePending, "a future change must be reported");
        assertEq(r.effectiveAt, when);
        assertEq(consumer.secondsUntilEffective(address(aapl)), 3 days);

        // Still reports the CURRENT multiplier, not the pending one.
        assertEq(r.multiplier, SCALE, "must not pre-apply a scheduled change");
    }

    /// @dev The moment it becomes effective, it stops being pending.
    function test_PendingBecomesNotPendingAtEffectiveAt() public {
        uint256 when = block.timestamp + 1 days;
        aapl.scheduleAction(2 * SCALE, when);
        assertTrue(consumer.isMultiplierPending(address(aapl)));

        vm.warp(when - 1);
        assertTrue(consumer.isMultiplierPending(address(aapl)), "still pending one second before");

        vm.warp(when);
        assertFalse(
            consumer.isMultiplierPending(address(aapl)), "not pending at the boundary: effectiveAt > now is strict"
        );
        assertEq(consumer.secondsUntilEffective(address(aapl)), 0);
    }

    /// @dev An identical "change" is not a change, even scheduled in the future.
    ///      Guards the `next != current` half of the rule.
    function test_ScheduledNoOpIsNotPending() public {
        aapl.scheduleAction(SCALE, block.timestamp + 5 days); // same as current
        assertFalse(consumer.isMultiplierPending(address(aapl)), "a no-op change is not a change");
    }

    /*//////////////////////////////////////////////////////////////////////////
                              GRACEFUL DEGRADATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_PlainErc20DegradesToUnitMultiplier() public view {
        ScaledRead memory r = consumer.readBalance(address(usdg), HOLDER);
        assertFalse(r.isScaled, "plain ERC-20 is not scaled");
        assertEq(r.multiplier, SCALE, "must default to 1e18");
        assertEq(r.rawAmount, 5000e18);
        assertEq(r.uiAmount, r.rawAmount, "ui == raw at a unit multiplier");
        assertFalse(r.changePending);
    }

    function test_NonContractAddressDoesNotRevert() public view {
        ScaledRead memory r = consumer.readBalance(address(0xDEAD), HOLDER);
        assertFalse(r.isScaled);
        assertEq(r.multiplier, SCALE);
        assertEq(r.rawAmount, 0);
        assertEq(r.uiAmount, 0);
    }

    function test_EoaAddressDoesNotRevert() public view {
        ScaledRead memory r = consumer.readScaled(HOLDER); // an EOA, no code
        assertFalse(r.isScaled);
        assertEq(r.multiplier, SCALE);
    }

    function test_RevertingSupportsInterfaceDegradesGracefully() public {
        aapl.setRevertOnSupportsInterface(true);
        ScaledRead memory r = consumer.readBalance(address(aapl), HOLDER);
        assertFalse(r.isScaled, "unreadable ERC-165 means treat as plain ERC-20");
        assertEq(r.multiplier, SCALE);
        assertEq(r.rawAmount, 100e18, "raw balance must still be read correctly");
    }

    /// @dev A token that returns true for the 0xffffffff sentinel is answering
    ///      unconditionally. Trusting it would make the reader call functions that
    ///      do not exist.
    function test_TokenThatClaimsEveryInterfaceIsRejected() public {
        aapl.setEvilSupportsInterface(true);
        ScaledRead memory r = consumer.readScaled(address(aapl));
        assertFalse(r.isScaled, "a token claiming every interface must be distrusted");
        assertEq(r.multiplier, SCALE);
    }

    function test_RevertingMultiplierDegradesGracefully() public {
        aapl.setRevertOnMultiplier(true);
        ScaledRead memory r = consumer.readBalance(address(aapl), HOLDER);
        assertFalse(r.isScaled, "claims ERC-8056 but cannot answer");
        assertEq(r.multiplier, SCALE);
        assertEq(r.rawAmount, 100e18);
    }

    /// @dev A zero multiplier would make every conversion revert or value the
    ///      position at nothing. Degrade instead of propagating it.
    function test_ZeroMultiplierIsTreatedAsUnscaled() public {
        aapl.setMultiplier(0);
        ScaledRead memory r = consumer.readBalance(address(aapl), HOLDER);
        assertFalse(r.isScaled, "a zero multiplier is never legitimate");
        assertEq(r.multiplier, SCALE);
        assertEq(r.uiAmount, r.rawAmount);
    }

    /// @dev The never-reverts guarantee, over arbitrary addresses.
    function testFuzz_NeverRevertsOnArbitraryAddress(address token, address account) public view {
        ScaledRead memory r = consumer.readBalance(token, account);
        assertGe(r.multiplier, 1, "multiplier is never zero");
        if (!r.isScaled) assertEq(r.multiplier, SCALE);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    UI AMOUNTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_UsesTokenNativeBalanceOfUiWhenAvailable() public {
        aapl.applyImmediateAction(AAPL_MULTIPLIER);
        ScaledRead memory r = consumer.readBalance(address(aapl), HOLDER);

        assertEq(r.rawAmount, 100e18, "raw is untouched by the corporate action");
        assertEq(r.uiAmount, aapl.balanceOfUI(HOLDER), "must match the token's own figure");
        assertGt(r.uiAmount, r.rawAmount, "share-equivalents exceed raw after the action");
    }

    /// @dev With the Balances extension absent the reader computes locally; both
    ///      paths must agree, otherwise a consumer's reconciliation breaks when a
    ///      token happens not to implement the extension.
    function testFuzz_NativeAndComputedUiAgree(uint256 balance, uint256 multiplier) public {
        balance = bound(balance, 0, 1e30);
        multiplier = bound(multiplier, 1, 1e24);

        MockScaledUIToken t = new MockScaledUIToken("T", "T");
        t.mint(HOLDER, balance);
        t.setMultiplier(multiplier);

        uint256 native = consumer.readBalance(address(t), HOLDER).uiAmount;

        t.setInterfaceSupported(ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES, false);
        uint256 computed = consumer.readBalance(address(t), HOLDER).uiAmount;

        assertApproxEqAbs(native, computed, 1, "native and computed UI amounts must agree within 1 wei");
    }

    function test_TotalSupplyRead() public {
        aapl.applyImmediateAction(AAPL_MULTIPLIER);
        ScaledRead memory r = consumer.readTotalSupply(address(aapl));
        assertEq(r.rawAmount, 100e18);
        assertEq(r.uiAmount, aapl.totalSupplyUI());
        assertEq(r.multiplier, AAPL_MULTIPLIER);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          THE SPLIT, END TO END
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev What a 2:1 split does to a holder: raw balance unchanged, shares
    ///      doubled, and no `Transfer` event to notice it by.
    function test_SplitDoublesSharesLeavesRawUntouched() public {
        ScaledRead memory before = consumer.readBalance(address(aapl), HOLDER);
        assertEq(before.rawAmount, 100e18);
        assertEq(before.uiAmount, 100e18);

        aapl.applyImmediateAction(2 * SCALE);

        ScaledRead memory afterSplit = consumer.readBalance(address(aapl), HOLDER);
        assertEq(afterSplit.rawAmount, 100e18, "raw balance is untouched by a split");
        assertEq(afterSplit.uiAmount, 200e18, "share-equivalents double");
        assertEq(afterSplit.multiplier, 2 * SCALE);
        assertFalse(afterSplit.changePending, "an applied split is not pending");
    }

    /// @dev A consumer that stored `uiAmount` before a split and compares it after
    ///      sees a phantom 100% gain. This is the accounting failure the library
    ///      exists to make visible: store raw, derive UI.
    function test_CachedUiAmountGoesWrongAcrossASplit() public {
        uint256 cachedUi = consumer.readBalance(address(aapl), HOLDER).uiAmount;
        uint256 cachedRaw = consumer.readBalance(address(aapl), HOLDER).rawAmount;

        aapl.applyImmediateAction(2 * SCALE);

        ScaledRead memory now_ = consumer.readBalance(address(aapl), HOLDER);
        assertEq(now_.rawAmount, cachedRaw, "raw is stable -- safe to cache");
        assertEq(now_.uiAmount, 2 * cachedUi, "UI is not stable -- unsafe to cache");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSISTENCY
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The struct must be internally consistent: uiAmount really is rawAmount
    ///      under the multiplier reported alongside it. This is what makes it safe
    ///      to pass a ScaledRead around without re-reading.
    function testFuzz_StructIsSelfConsistent(uint256 balance, uint256 multiplier) public {
        balance = bound(balance, 0, 1e30);
        multiplier = bound(multiplier, 1, 1e24);

        MockScaledUIToken t = new MockScaledUIToken("T", "T");
        t.mint(HOLDER, balance);
        t.setMultiplier(multiplier);

        ScaledRead memory r = consumer.readBalance(address(t), HOLDER);
        assertApproxEqAbs(
            r.uiAmount,
            ScaledUIMath.toUIDown(r.rawAmount, r.multiplier),
            1,
            "uiAmount must be derivable from rawAmount and the reported multiplier"
        );
    }

    function test_MultiplierOfMatchesReadScaled() public {
        aapl.applyImmediateAction(AAPL_MULTIPLIER);
        assertEq(consumer.multiplierOf(address(aapl)), consumer.readScaled(address(aapl)).multiplier);
        assertEq(consumer.multiplierOf(address(usdg)), SCALE);
    }
}
