// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../../src/ScaledUIMath.sol";

/**
 * @title ScaledUIMathHarness
 * @notice External wrapper around the internal {ScaledUIMath} functions.
 * @dev `internal` library functions are inlined into the caller, so a revert
 *      inside one happens at the SAME call depth as the test. `vm.expectRevert`
 *      requires the revert to occur at a lower depth, and fails with
 *      "call didn't revert at a lower depth than cheatcode call depth".
 *
 *      Routing through this harness gives the revert somewhere to happen. It adds
 *      no logic, so a revert observed here is a revert in the library.
 */
contract ScaledUIMathHarness {
    function toUIDown(uint256 rawAmount, uint256 multiplier) external pure returns (uint256) {
        return ScaledUIMath.toUIDown(rawAmount, multiplier);
    }

    function toUIUp(uint256 rawAmount, uint256 multiplier) external pure returns (uint256) {
        return ScaledUIMath.toUIUp(rawAmount, multiplier);
    }

    function toRawDown(uint256 uiAmount, uint256 multiplier) external pure returns (uint256) {
        return ScaledUIMath.toRawDown(uiAmount, multiplier);
    }

    function toRawUp(uint256 uiAmount, uint256 multiplier) external pure returns (uint256) {
        return ScaledUIMath.toRawUp(uiAmount, multiplier);
    }
}
