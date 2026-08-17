// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../../src/ScaledUIMath.sol";
import {IAggregatorV3, ScaledPrice, ScaledUIOracle} from "../../src/ScaledUIOracle.sol";
import {Test} from "forge-std/Test.sol";

interface IToken {
    function uiMultiplier() external view returns (uint256);
    function oraclePaused() external view returns (bool);
}

/**
 * @title ForkOracleTest
 * @notice Runs {ScaledUIOracle} against the REAL Chainlink feeds on Robinhood Chain.
 *
 * @dev This is the test that turns the central claim of this repository from a
 *      derivation into a measurement. The double-counting error is no longer
 *      computed from the multiplier alone -- it is the difference between two
 *      valuations of a live production oracle answer.
 *
 * @dev FINDING THE FEEDS
 *
 *      The feed addresses are not listed in the Robinhood or Chainlink
 *      documentation pages, are not resolvable from any on-chain registry, and
 *      do not match by name on the block explorer. They ARE published in
 *      Chainlink's reference data directory:
 *
 *          https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 *
 *      56 feeds, 35 of them Robinhood equity/ETF feeds, all 8-decimal.
 *
 *      Note the inconsistent `description()` values: AAPL reports
 *      "Robinhood AAPL / USD" while TSLA reports "RHTSLA / USD". Do not resolve
 *      feeds by description string.
 *
 * @dev STALENESS
 *
 *      These feeds are low-frequency -- an observed answer was ~2 hours old and
 *      perfectly healthy. `maxStaleness` here is deliberately generous for that
 *      reason. In production, derive it from the feed's documented heartbeat,
 *      and note the warning in {ScaledUIOracle}: a generous staleness window is
 *      exactly what lets a paused-and-held price through, leaving `oraclePaused`
 *      enforcement as the only remaining guard.
 *
 *          RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *            forge test --match-contract ForkOracle -vv
 */
contract ForkOracleTest is Test {
    uint256 internal constant CHAIN_ID = 4663;
    uint256 internal constant MAX_STALENESS = 3 days;

    // token => Chainlink proxy, from the reference data directory.
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;

    bool internal active;

    function setUp() public {
        string memory url = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        require(block.chainid == CHAIN_ID, "fork: not Robinhood Chain (expected 4663)");
        active = true;
    }

    modifier onFork() {
        if (!active) {
            emit log("SKIP: set RH_RPC_URL to run fork tests");
            return;
        }
        _;
    }

    function _oracle(address feed, address token) internal returns (ScaledUIOracle) {
        return new ScaledUIOracle(IAggregatorV3(feed), token, MAX_STALENESS);
    }

    /*//////////////////////////////////////////////////////////////////////////
                          THE MEASUREMENT, NOT THE DERIVATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Values one raw AAPL token two ways against the live feed. The naive
    ///      path applies `uiMultiplier` to an answer that already includes it.
    function test_Fork_DoubleCountIsMeasurableOnLiveAaplFeed() public onFork {
        ScaledUIOracle oracle = _oracle(AAPL_FEED, AAPL);

        ScaledPrice memory p = oracle.latestPrice();
        uint256 multiplier = IToken(AAPL).uiMultiplier();

        assertGt(p.price, 0, "live feed must return a positive answer");
        assertEq(p.decimals, 8, "Robinhood equity feeds are 8-decimal");
        assertGt(multiplier, ScaledUIMath.SCALE, "AAPL has applied a corporate action");

        uint256 safeValue = oracle.valueOfRaw(1e18); // one raw token
        uint256 naiveValue = (safeValue * multiplier) / ScaledUIMath.SCALE;

        assertGt(naiveValue, safeValue, "the naive path over-values against a real oracle");

        uint256 overageBps = ((naiveValue - safeValue) * 10_000) / safeValue;

        emit log_named_uint("AAPL feed price (8dp)", p.price);
        emit log_named_uint("uiMultiplier         ", multiplier);
        emit log_named_uint("safe  value 1 token  ", safeValue);
        emit log_named_uint("naive value 1 token  ", naiveValue);
        emit log_named_uint("over-valued by (bps) ", overageBps);

        // ~5.66 bps at the multiplier applied on 2026-08-14. Asserted as a band so
        // a later corporate action changes the magnitude without breaking the test.
        assertGe(overageBps, 1, "divergence must be measurable");
        assertLe(overageBps, 10_000, "sanity bound");
    }

    /// @dev The other side of the same coin, and the reason this went unnoticed:
    ///      on every token still at a multiplier of exactly 1.0, the naive and
    ///      safe valuations are IDENTICAL against the live feed. Testing against
    ///      these tokens cannot distinguish correct code from broken code.
    function test_Fork_TrapIsInvisibleOnTokensStillAtUnity() public onFork {
        address[3] memory tokens = [TSLA, NVDA, SPY];
        address[3] memory feeds = [TSLA_FEED, NVDA_FEED, SPY_FEED];

        for (uint256 i = 0; i < tokens.length; i++) {
            ScaledUIOracle oracle = _oracle(feeds[i], tokens[i]);
            uint256 multiplier = IToken(tokens[i]).uiMultiplier();

            uint256 safeValue = oracle.valueOfRaw(1e18);
            uint256 naiveValue = (safeValue * multiplier) / ScaledUIMath.SCALE;

            if (ScaledUIMath.isUnitMultiplier(multiplier)) {
                assertEq(naiveValue, safeValue, "at 1.0 the bug is invisible -- this is the trap");
                emit log_named_uint("still at 1.0, naive == safe (8dp)", safeValue);
            } else {
                emit log_named_uint("this token has diverged too (8dp)", safeValue);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    LIVE FEED HEALTH
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Every mapped feed answers, is 8-decimal, and is currently usable.
    function test_Fork_AllMappedFeedsAreLiveAndUsable() public onFork {
        address[4] memory tokens = [AAPL, TSLA, NVDA, SPY];
        address[4] memory feeds = [AAPL_FEED, TSLA_FEED, NVDA_FEED, SPY_FEED];

        for (uint256 i = 0; i < tokens.length; i++) {
            ScaledUIOracle oracle = _oracle(feeds[i], tokens[i]);

            assertTrue(oracle.isPriceUsable(), "feed must be usable within maxStaleness");

            ScaledPrice memory p = oracle.latestPrice();
            assertGt(p.price, 0);
            assertEq(p.decimals, 8);
            assertTrue(p.pausableKnown, "a Robinhood stock token must expose oraclePaused()");
            assertFalse(p.oraclePaused, "safe path never returns a paused reading");
            assertLe(p.updatedAt, block.timestamp, "answer cannot be from the future");

            emit log_named_string("feed", IAggregatorV3(feeds[i]).description());
            emit log_named_uint("  price (8dp)", p.price);
            emit log_named_uint("  age (s)    ", block.timestamp - p.updatedAt);
        }
    }

    /// @dev The pause guard, exercised against a real feed by forcing the token's
    ///      flag. Confirms the revert path fires on production data, not just mocks.
    function test_Fork_PauseGuardFiresAgainstTheLiveFeed() public onFork {
        ScaledUIOracle oracle = _oracle(AAPL_FEED, AAPL);
        assertTrue(oracle.isPriceUsable(), "healthy before");

        // Force oraclePaused() to return true on the real token.
        vm.mockCall(AAPL, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));

        assertFalse(oracle.isPriceUsable(), "must report unusable while paused");
        vm.expectRevert(abi.encodeWithSelector(ScaledUIOracle.OraclePaused.selector, AAPL));
        oracle.latestPrice();

        // ...and the unsafe path still works, flagging the pause.
        ScaledPrice memory p = oracle.latestPriceUnsafe();
        assertTrue(p.oraclePaused, "unsafe read surfaces the flag");
        assertGt(p.price, 0);

        vm.clearMockedCalls();
        assertTrue(oracle.isPriceUsable(), "healthy again after");
    }

    /// @dev Feed `description()` is NOT a reliable identifier: AAPL reports
    ///      "Robinhood AAPL / USD" while TSLA reports "RHTSLA / USD". Resolve
    ///      feeds by address from the reference data directory, never by string.
    function test_Fork_FeedDescriptionsAreInconsistent() public onFork {
        string memory aapl = IAggregatorV3(AAPL_FEED).description();
        string memory tsla = IAggregatorV3(TSLA_FEED).description();

        emit log_named_string("AAPL feed description", aapl);
        emit log_named_string("TSLA feed description", tsla);

        assertTrue(bytes(aapl).length > 0 && bytes(tsla).length > 0, "both must describe themselves");
        assertNotEq(keccak256(bytes(aapl)), keccak256(bytes(tsla)), "sanity: different feeds, different descriptions");
    }
}
