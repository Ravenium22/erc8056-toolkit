// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ERC8056InterfaceIds,
    IScaledUIAmount,
    IScaledUIAmountBalances,
    IScaledUIAmountConversion,
    IScaledUIAmountNewUIMultiplier
} from "../src/interfaces/IERC8056.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ERC165IdsTest
 * @notice Guards the constants in {ERC8056InterfaceIds} against transcription error.
 *
 * @dev The interface IDs are the one thing integrators copy verbatim, and a wrong
 *      one fails OPEN: `supportsInterface(<typo>)` returns false, the reader
 *      concludes "plain ERC-20", and the multiplier is silently treated as 1.0 on
 *      a token that has actually split. Nothing reverts. The position is just
 *      wrong -- which is the entire class of bug this library exists to prevent.
 *
 *      So each constant is checked twice over:
 *        1. against `type(I).interfaceId`, computed by the compiler from the
 *           interface declared in this repo; and
 *        2. against the literal published in ERC-8056.
 *
 *      Agreement means our declaration matches the spec. A drifting declaration
 *      breaks (1); a mistyped constant breaks (2).
 *
 *      All four literals were additionally confirmed live against the canonical
 *      Robinhood AAPL token at block 38,417,371 -- see ForkTokenSurvey.t.sol.
 */
contract ERC165IdsTest is Test {
    function test_CoreIdMatchesCompilerAndSpec() public pure {
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT,
            type(IScaledUIAmount).interfaceId,
            "IScaledUIAmount: constant disagrees with declared interface"
        );
        assertEq(ERC8056InterfaceIds.SCALED_UI_AMOUNT, bytes4(0xa60bf13d), "IScaledUIAmount: spec literal");
    }

    function test_NewUIMultiplierIdMatchesCompilerAndSpec() public pure {
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW,
            type(IScaledUIAmountNewUIMultiplier).interfaceId,
            "IScaledUIAmountNewUIMultiplier: constant disagrees with declared interface"
        );
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW, bytes4(0x4bd27648), "IScaledUIAmountNewUIMultiplier: spec literal"
        );
    }

    function test_ConversionIdMatchesCompilerAndSpec() public pure {
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_CONVERSION,
            type(IScaledUIAmountConversion).interfaceId,
            "IScaledUIAmountConversion: constant disagrees with declared interface"
        );
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_CONVERSION,
            bytes4(0x57854fc3),
            "IScaledUIAmountConversion: spec literal"
        );
    }

    function test_BalancesIdMatchesCompilerAndSpec() public pure {
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES,
            type(IScaledUIAmountBalances).interfaceId,
            "IScaledUIAmountBalances: constant disagrees with declared interface"
        );
        assertEq(
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES, bytes4(0xd890fd71), "IScaledUIAmountBalances: spec literal"
        );
    }

    /// @dev Events do not contribute to an ERC-165 ID. This pins that fact, so
    ///      that adding the `TransferWithScaledUI` declaration to
    ///      {IScaledUIAmount} -- which we do, to document the live divergence --
    ///      provably cannot shift the core ID.
    function test_ExtraEventDeclarationDoesNotChangeCoreId() public pure {
        assertEq(
            type(IScaledUIAmount).interfaceId,
            bytes4(keccak256("uiMultiplier()")),
            "core ID must equal the lone function selector, events excluded"
        );
    }

    /// @dev The IDs must be mutually distinct, otherwise a probe for one silently
    ///      answers for another.
    function test_IdsAreDistinct() public pure {
        bytes4[4] memory ids = [
            ERC8056InterfaceIds.SCALED_UI_AMOUNT,
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW,
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_CONVERSION,
            ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES
        ];
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = i + 1; j < ids.length; j++) {
                assertTrue(ids[i] != ids[j], "ERC-8056 interface IDs must be distinct");
            }
        }
    }

    function test_Erc165SentinelsAreCorrect() public pure {
        assertEq(ERC8056InterfaceIds.ERC165, bytes4(keccak256("supportsInterface(bytes4)")), "ERC-165 ID");
        assertEq(ERC8056InterfaceIds.ERC165_INVALID, bytes4(0xffffffff), "ERC-165 invalid sentinel");
    }
}
