// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../../src/ScaledUIMath.sol";
import {ScaledRead, ScaledUIReader} from "../../src/ScaledUIReader.sol";
import {ERC8056InterfaceIds} from "../../src/interfaces/IERC8056.sol";
import {Test} from "forge-std/Test.sol";

interface IProbe {
    function uiMultiplier() external view returns (uint256);
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function oraclePaused() external view returns (bool);
    function totalSupply() external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
    function supportsInterface(bytes4) external view returns (bool);
    function symbol() external view returns (string memory);
}

contract ForkConsumer {
    function readScaled(address token) external view returns (ScaledRead memory) {
        return ScaledUIReader.readScaled(token);
    }

    function readTotalSupply(address token) external view returns (ScaledRead memory) {
        return ScaledUIReader.readTotalSupply(token);
    }

    function isMultiplierPending(address token) external view returns (bool) {
        return ScaledUIReader.isMultiplierPending(token);
    }
}

/**
 * @title ForkTokenSurveyTest
 * @notice Runs `ScaledUIReader` against real Robinhood Chain tokens.
 *
 * @dev WHY THIS DOES NOT PIN A BLOCK
 *
 *      The public Robinhood Chain RPC is NOT an archive node. Measured retention
 *      is roughly 6,000 blocks at ~100ms per block -- about TEN MINUTES of state.
 *      Beyond that, `--block <n>` fails with:
 *
 *          error code -32000: metadata is not found
 *
 *      A block-pinned fork test would therefore pass for ten minutes and fail
 *      forever after, which is worse than no test. So these run at `latest` and
 *      assert INVARIANTS that must hold whatever the chain has done since --
 *      plus a small number of monotonic facts (AAPL has diverged upward from 1.0
 *      and cannot un-diverge) that would only break on a genuine reversal.
 *
 *      Skipped unless RH_RPC_URL is set, so CI stays green and offline.
 *
 *          RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *            forge test --match-path 'test/fork/*' -vv
 */
contract ForkTokenSurveyTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant CHAIN_ID = 4663;

    // Canonical Robinhood Stock Tokens. Per docs.robinhood.com/chain/contracts, a
    // matching ticker at a different address is NOT a Robinhood Stock Token.
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    // Plain ERC-20s. The other side of most stock-token pairs.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // Ticker collision: "Loxley AAPL Share". NOT a Robinhood Stock Token.
    address internal constant LOX_AAPL = 0xDa62854B8Ae99beb09ca2A9950317b75FaD28f48;

    ForkConsumer internal consumer;
    bool internal active;

    function setUp() public {
        string memory url = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;

        vm.createSelectFork(url);
        require(block.chainid == CHAIN_ID, "fork: not Robinhood Chain (expected 4663)");

        consumer = new ForkConsumer();
        active = true;
    }

    modifier onFork() {
        if (!active) {
            emit log("SKIP: set RH_RPC_URL to run fork tests");
            return;
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                          THE FINDING, AGAINST THE LIVE CHAIN
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev AAPL has applied a corporate action and its multiplier exceeds 1.0.
    ///      Would only fail on a reverse action taking it back to or below unity.
    function test_Fork_AaplHasDivergedFromUnity() public onFork {
        ScaledRead memory r = consumer.readScaled(AAPL);

        assertTrue(r.isScaled, "AAPL must be detected as ERC-8056");
        assertGt(r.multiplier, SCALE, "AAPL multiplier must exceed 1.0 -- the 2026-08-14 action");
        assertFalse(ScaledUIMath.isUnitMultiplier(r.multiplier), "AAPL is no longer the degenerate case");

        emit log_named_uint("AAPL uiMultiplier", r.multiplier);
        emit log_named_uint("AAPL effectiveAt ", IProbe(AAPL).effectiveAt());
    }

    /// @dev The token's own supply figures diverge, and by exactly the amount the
    ///      library's arithmetic predicts. This is the strongest available check
    ///      that ScaledUIMath matches the issuer's implementation.
    function test_Fork_AaplSupplyDivergenceMatchesOurMath() public onFork {
        uint256 raw = IProbe(AAPL).totalSupply();
        uint256 reported = IProbe(AAPL).totalSupplyUI();
        uint256 multiplier = IProbe(AAPL).uiMultiplier();

        assertGt(reported, raw, "totalSupplyUI must exceed totalSupply after the action");
        assertApproxEqAbs(
            ScaledUIMath.toUIDown(raw, multiplier),
            reported,
            1,
            "our conversion must reproduce the token's own totalSupplyUI"
        );

        emit log_named_uint("AAPL totalSupply  ", raw);
        emit log_named_uint("AAPL totalSupplyUI", reported);
        emit log_named_uint("divergence (wei)  ", reported - raw);
    }

    /// @dev The headline correction, against the real contract rather than a mock:
    ///      AAPL's stale `newUIMultiplier`/`effectiveAt` must not read as pending.
    ///      Conditional, because a genuine future action would legitimately flip it.
    function test_Fork_AaplStalePendingStateIsNotReportedAsPending() public onFork {
        uint256 current = IProbe(AAPL).uiMultiplier();
        uint256 next = IProbe(AAPL).newUIMultiplier();
        uint256 when = IProbe(AAPL).effectiveAt();

        emit log_named_uint("uiMultiplier   ", current);
        emit log_named_uint("newUIMultiplier", next);
        emit log_named_uint("effectiveAt    ", when);
        emit log_named_uint("block.timestamp", block.timestamp);

        bool genuinelyPending = (next != current) && (when > block.timestamp);
        assertEq(
            consumer.isMultiplierPending(AAPL),
            genuinelyPending,
            "reader must agree with the two-condition rule on live state"
        );

        if (!genuinelyPending && when != 0) {
            // The exact live situation: non-zero effectiveAt, nothing pending.
            // The naive check would say otherwise.
            assertFalse(consumer.isMultiplierPending(AAPL), "stale effectiveAt must not read as pending");
            assertTrue(when != 0, "effectiveAt is non-zero -- what breaks the naive check");
        }
    }

    /// @dev The conversion extension is absent on Robinhood tokens, which is why
    ///      ScaledUIMath is load-bearing. Pinned so a future rollout is noticed.
    function test_Fork_ConversionExtensionIsAbsent() public onFork {
        assertTrue(IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.SCALED_UI_AMOUNT), "core");
        assertTrue(IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW), "pending ext");
        assertTrue(IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES), "balances ext");
        assertFalse(
            IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.SCALED_UI_AMOUNT_CONVERSION),
            "conversion ext is NOT implemented -- if this fails, the chain changed"
        );
    }

    /// @dev ERC-165 self-consistency on a real token.
    function test_Fork_Erc165SentinelIsHonoured() public onFork {
        assertTrue(IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.ERC165), "must support ERC-165");
        assertFalse(
            IProbe(AAPL).supportsInterface(ERC8056InterfaceIds.ERC165_INVALID),
            "must return false for the 0xffffffff sentinel"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    DEGRADATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev USDG answers ERC-165 and says no; WETH has no ERC-165 at all. Both must
    ///      degrade identically and without reverting -- they are the counter-asset
    ///      in the pools where stock tokens actually trade.
    function test_Fork_PlainErc20sDegradeCleanly() public onFork {
        address[2] memory plain = [USDG, WETH];
        for (uint256 i = 0; i < plain.length; i++) {
            ScaledRead memory r = consumer.readTotalSupply(plain[i]);
            assertFalse(r.isScaled, "plain ERC-20 must not be detected as scaled");
            assertEq(r.multiplier, SCALE, "must default to 1e18");
            assertEq(r.uiAmount, r.rawAmount, "ui == raw at a unit multiplier");
            assertGt(r.rawAmount, 0, "sanity: token has supply");
            assertFalse(r.changePending);
        }
    }

    /// @dev A ticker collision is not a Robinhood Stock Token. Resolve by address,
    ///      never by symbol -- and note the reader degrades safely regardless.
    function test_Fork_TickerCollisionIsNotAStockToken() public onFork {
        ScaledRead memory impostor = consumer.readScaled(LOX_AAPL);
        assertFalse(impostor.isScaled, "loxAAPL does not implement ERC-8056");
        assertEq(impostor.multiplier, SCALE);

        ScaledRead memory canonical = consumer.readScaled(AAPL);
        assertTrue(canonical.isScaled, "the canonical AAPL does");
    }

    /*//////////////////////////////////////////////////////////////////////////
                               THE REST OF THE MARKET
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Every canonical stock token must be detected, expose a non-zero
    ///      multiplier, and be self-consistent. No exact values asserted: any of
    ///      them may act at any time.
    function test_Fork_AllStockTokensAreWellFormed() public onFork {
        address[4] memory tokens = [AAPL, TSLA, NVDA, SPY];
        for (uint256 i = 0; i < tokens.length; i++) {
            ScaledRead memory r = consumer.readTotalSupply(tokens[i]);

            assertTrue(r.isScaled, "canonical stock token must implement ERC-8056");
            assertGt(r.multiplier, 0, "multiplier must never be zero");
            assertGt(r.rawAmount, 0, "sanity: token has supply");
            assertApproxEqAbs(
                r.uiAmount, ScaledUIMath.toUIDown(r.rawAmount, r.multiplier), 1, "read must be self-consistent"
            );

            emit log_named_string("token", IProbe(tokens[i]).symbol());
            emit log_named_uint("  multiplier", r.multiplier);
        }
    }

    /// @dev Records how many tickers still read exactly 1.0. Any integration
    ///      tested only against those has verified nothing, because at a unit
    ///      multiplier correct code and multiplier-ignoring code agree exactly.
    function test_Fork_ReportHowManyTokensAreStillAtUnity() public onFork {
        address[4] memory tokens = [AAPL, TSLA, NVDA, SPY];
        uint256 atUnity;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (ScaledUIMath.isUnitMultiplier(consumer.readScaled(tokens[i]).multiplier)) atUnity++;
        }
        emit log_named_uint("tokens sampled       ", tokens.length);
        emit log_named_uint("still at exactly 1.0 ", atUnity);
        assertLt(atUnity, tokens.length, "at least one token has diverged -- AAPL");
    }

    /// @dev The oraclePaused flag as it currently reads. Informational: a paused
    ///      token is a legitimate transient state, so this asserts only that the
    ///      call is answerable on a canonical token.
    function test_Fork_OraclePausedIsReadable() public onFork {
        bool paused = IProbe(AAPL).oraclePaused();
        emit log_named_string("AAPL oraclePaused", paused ? "true" : "false");
    }
}
