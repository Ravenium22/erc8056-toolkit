// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../src/ScaledUIMath.sol";
import {IAggregatorV3, ScaledUIOracle} from "../src/ScaledUIOracle.sol";
import {ScaledRead, ScaledUIReader} from "../src/ScaledUIReader.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockScaledUIToken} from "./mocks/MockScaledUIToken.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ExampleLendingMarket
 * @notice A minimal collateral market, written the way this library intends.
 *
 * @dev Deliberately built only from the public surface -- `ScaledUIReader`,
 *      `ScaledUIOracle`, `ScaledUIMath` -- with no reach into internals. If this
 *      compiles and behaves, the library is usable from outside.
 *
 *      It demonstrates the four decisions INTEGRATION.md argues for:
 *
 *        1. Collateral is stored in RAW units, so a corporate action cannot
 *           silently reprice an existing position.
 *        2. Pricing goes through {ScaledUIOracle}, so the multiplier is never
 *           applied twice and a paused oracle cannot be borrowed against.
 *        3. Opening a position is refused while a corporate action is pending, so
 *           no position straddles `effectiveAt`.
 *        4. Withdrawals round in the protocol's favour.
 */
contract ExampleLendingMarket {
    ScaledUIOracle public immutable oracle;
    address public immutable collateralToken;

    /// @dev RAW units. Never share-equivalents -- that is the whole point.
    mapping(address => uint256) public collateralRaw;

    error CorporateActionPending(uint256 effectiveAt);
    error InsufficientCollateral();

    constructor(ScaledUIOracle oracle_) {
        oracle = oracle_;
        collateralToken = oracle_.token();
    }

    /// @dev Refuses to open across a scheduled multiplier change. Uses the
    ///      library's detection, not `newUIMultiplier() != 0`, which would reject
    ///      every deposit forever once a token has ever acted.
    function deposit(uint256 rawAmount) external {
        ScaledRead memory r = ScaledUIReader.readScaled(collateralToken);
        if (r.changePending) revert CorporateActionPending(r.effectiveAt);

        collateralRaw[msg.sender] += rawAmount;
    }

    /// @dev Reverts if the issuer has paused the oracle -- borrowing power must
    ///      not be derived from a mark the issuer has disowned.
    function collateralValue(address user) external view returns (uint256) {
        return oracle.valueOfRaw(collateralRaw[user]);
    }

    /// @dev Share-equivalents for display only, derived on demand and never stored.
    function collateralShares(address user) external view returns (uint256) {
        ScaledRead memory r = ScaledUIReader.readScaled(collateralToken);
        return ScaledUIMath.toUIDown(collateralRaw[user], r.multiplier);
    }

    function withdraw(uint256 rawAmount) external {
        if (collateralRaw[msg.sender] < rawAmount) revert InsufficientCollateral();
        collateralRaw[msg.sender] -= rawAmount;
    }
}

/// @notice End-to-end proof that the library is usable from outside.
contract ExampleIntegrationTest is Test {
    uint256 internal constant AAPL_MULTIPLIER = 1_000_566_080_061_092_436;
    address internal constant USER = address(0xB0B);

    MockScaledUIToken internal token;
    MockAggregatorV3 internal feed;
    ScaledUIOracle internal oracle;
    ExampleLendingMarket internal market;

    function setUp() public {
        vm.warp(1_786_928_145);

        token = new MockScaledUIToken("Apple - Robinhood Token", "AAPL");
        token.mint(USER, 1000e18);

        feed = new MockAggregatorV3(8, 220e8, "AAPL / USD");
        oracle = new ScaledUIOracle(IAggregatorV3(address(feed)), address(token), 1 hours);
        market = new ExampleLendingMarket(oracle);

        vm.prank(USER);
        market.deposit(1000e18);
    }

    function test_HappyPath() public view {
        assertEq(market.collateralRaw(USER), 1000e18);
        assertEq(market.collateralValue(USER), 220_000e8, "1000 tokens x $220");
        assertEq(market.collateralShares(USER), 1000e18, "no action applied yet");
    }

    /// @dev The property that makes raw-unit storage correct: a corporate action
    ///      changes what the position IS worth in shares, but not what it is worth
    ///      in dollars, because the feed already reflects the action.
    function test_CorporateActionDoesNotRepriceAnOpenPosition() public {
        uint256 valueBefore = market.collateralValue(USER);

        token.applyImmediateAction(AAPL_MULTIPLIER);

        assertEq(market.collateralRaw(USER), 1000e18, "stored collateral is untouched");
        assertEq(market.collateralValue(USER), valueBefore, "dollar value is unchanged -- correct");
        assertGt(market.collateralShares(USER), 1000e18, "share-equivalents grew -- also correct");
    }

    /// @dev A 2:1 split. Had the market stored shares, this position would now be
    ///      worth double on paper. It is not.
    function test_SplitDoesNotInflateCollateral() public {
        uint256 valueBefore = market.collateralValue(USER);

        token.applyImmediateAction(2e18);

        assertEq(market.collateralValue(USER), valueBefore, "a split must not create borrowing power");
        assertEq(market.collateralShares(USER), 2000e18, "shares double, for display only");
    }

    function test_DepositRefusedWhileChangePending() public {
        uint256 when = block.timestamp + 2 days;
        token.scheduleAction(2e18, when);

        vm.expectRevert(abi.encodeWithSelector(ExampleLendingMarket.CorporateActionPending.selector, when));
        vm.prank(USER);
        market.deposit(1e18);
    }

    /// @dev The counterpart: once the change has been applied, deposits must
    ///      resume. The naive detection would keep rejecting forever.
    function test_DepositResumesAfterChangeApplied() public {
        token.applyImmediateAction(AAPL_MULTIPLIER);

        vm.prank(USER);
        market.deposit(1e18); // must not revert

        assertEq(market.collateralRaw(USER), 1001e18);
    }

    function test_ValuationRefusedWhileOraclePaused() public {
        token.setOraclePaused(true);

        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.OraclePaused.selector, address(token)));
        market.collateralValue(USER);
    }

    /// @dev Withdrawals stay available while the oracle is paused: they reduce
    ///      risk and need no fresh mark. See INTEGRATION.md §3.
    function test_WithdrawalStillWorksWhileOraclePaused() public {
        token.setOraclePaused(true);

        vm.prank(USER);
        market.withdraw(500e18);

        assertEq(market.collateralRaw(USER), 500e18);
    }

    /// @dev The invariant across arbitrary corporate actions: stored collateral
    ///      and dollar value are both invariant; only the share view moves.
    function testFuzz_ValueIsInvariantAcrossAnyCorporateAction(uint256 multiplier) public {
        multiplier = bound(multiplier, 1e15, 1e21);
        uint256 valueBefore = market.collateralValue(USER);

        token.applyImmediateAction(multiplier);

        assertEq(market.collateralRaw(USER), 1000e18);
        assertEq(market.collateralValue(USER), valueBefore);
        assertEq(market.collateralShares(USER), ScaledUIMath.toUIDown(1000e18, multiplier));
    }
}
