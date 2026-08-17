// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScaledUIMath} from "../../src/ScaledUIMath.sol";
import {ERC8056InterfaceIds} from "../../src/interfaces/IERC8056.sol";

/**
 * @title MockScaledUIToken
 * @notice A configurable ERC-8056 token for testing consumers.
 *
 * @dev Built to reproduce the states that actually occur on Robinhood Chain,
 *      including the ones that break naive integrations:
 *
 *      - Per-interface ERC-165 toggles, so a consumer can be tested against a
 *        token that supports the core interface but not `Balances`, or that
 *        answers ERC-165 not at all.
 *      - {applyImmediateAction} reproduces AAPL's post-action state, where
 *        `newUIMultiplier == uiMultiplier` and `effectiveAt` is in the PAST.
 *        This is the state that makes `newUIMultiplier() != 0` a false positive.
 *      - {scheduleAction} produces a genuinely pending change.
 *      - {setOraclePaused} exposes the advisory Robinhood flag.
 *      - {setRevertOnSupportsInterface} / {setEvilSupportsInterface} model tokens
 *        that are hostile or broken rather than merely non-compliant, because a
 *        reader that "never reverts" must be tested against something that does.
 */
contract MockScaledUIToken {
    /*//////////////////////////////////////////////////////////////////////////
                                   ERC-20 STATE
    //////////////////////////////////////////////////////////////////////////*/

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /*//////////////////////////////////////////////////////////////////////////
                                  ERC-8056 STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Backing storage is private so the accessors below can be made to
    ///      revert on demand; a public variable's auto-generated getter cannot.
    uint256 private _uiMultiplier = ScaledUIMath.SCALE;
    uint256 private _newUIMultiplier = ScaledUIMath.SCALE;
    uint256 private _effectiveAt;
    bool private _oraclePaused;

    function uiMultiplier() public view returns (uint256) {
        if (revertOnMultiplier) revert("mock: uiMultiplier reverted");
        return _uiMultiplier;
    }

    function newUIMultiplier() public view returns (uint256) {
        if (revertOnMultiplier) revert("mock: newUIMultiplier reverted");
        return _newUIMultiplier;
    }

    function effectiveAt() public view returns (uint256) {
        return _effectiveAt;
    }

    /// @notice The advisory Robinhood flag. Not part of ERC-8056.
    /// @dev Reverts when {oraclePausedAbsent} is set, exactly as a token that does
    ///      not implement the flag would. A consumer must handle that as "not
    ///      pausable", never as "paused" and never by bubbling the revert.
    function oraclePaused() public view returns (bool) {
        if (oraclePausedAbsent) revert("mock: no oraclePaused()");
        return _oraclePaused;
    }

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithScaledUI(address indexed from, address indexed to, uint256 value, uint256 uiValue);

    /*//////////////////////////////////////////////////////////////////////////
                                 BEHAVIOUR TOGGLES
    //////////////////////////////////////////////////////////////////////////*/

    mapping(bytes4 => bool) public interfaceSupported;

    /// @notice When true, `supportsInterface` reverts instead of answering.
    bool public revertOnSupportsInterface;

    /// @notice When true, `supportsInterface` returns true for EVERY id, including
    ///         the 0xffffffff sentinel that ERC-165 requires be false. Models a
    ///         token whose answers carry no information.
    bool public evilSupportsInterface;

    /// @notice When true, `uiMultiplier()` reverts. Models a broken token.
    bool public revertOnMultiplier;

    /// @notice When true, `oraclePaused()` is absent -- the call reverts, as it
    ///         would on any token that is not a Robinhood Stock Token.
    bool public oraclePausedAbsent;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;

        // Default: the surface a canonical Robinhood Stock Token actually exposes.
        // Note CONVERSION is deliberately absent -- AAPL returns false for it.
        interfaceSupported[ERC8056InterfaceIds.ERC165] = true;
        interfaceSupported[ERC8056InterfaceIds.SCALED_UI_AMOUNT] = true;
        interfaceSupported[ERC8056InterfaceIds.SCALED_UI_AMOUNT_NEW] = true;
        interfaceSupported[ERC8056InterfaceIds.SCALED_UI_AMOUNT_BALANCES] = true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                              CORPORATE ACTION CONTROLS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Apply a corporate action immediately, leaving the exact state that
     *         live AAPL is in right now.
     * @dev After this call:
     *        uiMultiplier    == newMultiplier
     *        newUIMultiplier == newMultiplier   (identical -- stale, already applied)
     *        effectiveAt     == a PAST timestamp (not cleared)
     *
     *      Reproduces AAPL at block 38,417,371:
     *        uiMultiplier()    = 1000566080061092436
     *        newUIMultiplier() = 1000566080061092436
     *        effectiveAt()     = 1786720366  (2026-08-14, in the past)
     */
    function applyImmediateAction(uint256 newMultiplier) external {
        uint256 old = _uiMultiplier;
        _uiMultiplier = newMultiplier;
        _newUIMultiplier = newMultiplier;
        _effectiveAt = block.timestamp;
        emit UIMultiplierUpdated(old, newMultiplier, block.timestamp);
    }

    /// @notice Schedule a genuinely pending change taking effect in the future.
    function scheduleAction(uint256 newMultiplier, uint256 effectiveAtTimestamp) external {
        require(effectiveAtTimestamp > block.timestamp, "mock: effectiveAt must be in the future");
        _newUIMultiplier = newMultiplier;
        _effectiveAt = effectiveAtTimestamp;
        emit UIMultiplierUpdated(_uiMultiplier, newMultiplier, effectiveAtTimestamp);
    }

    /// @notice Promote a previously scheduled change once its timestamp has passed.
    function settleScheduledAction() external {
        require(_effectiveAt != 0 && block.timestamp >= _effectiveAt, "mock: not yet effective");
        _uiMultiplier = _newUIMultiplier;
    }

    /// @notice Set the multiplier directly, bypassing the event and pending fields.
    function setMultiplier(uint256 newMultiplier) external {
        _uiMultiplier = newMultiplier;
        _newUIMultiplier = newMultiplier;
    }

    function setOraclePaused(bool paused) external {
        _oraclePaused = paused;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 HOSTILITY CONTROLS
    //////////////////////////////////////////////////////////////////////////*/

    function setInterfaceSupported(bytes4 id, bool supported) external {
        interfaceSupported[id] = supported;
    }

    function setRevertOnSupportsInterface(bool v) external {
        revertOnSupportsInterface = v;
    }

    function setEvilSupportsInterface(bool v) external {
        evilSupportsInterface = v;
    }

    function setRevertOnMultiplier(bool v) external {
        revertOnMultiplier = v;
    }

    function setOraclePausedAbsent(bool v) external {
        oraclePausedAbsent = v;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  ERC-165 / ERC-8056
    //////////////////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 id) external view returns (bool) {
        if (revertOnSupportsInterface) revert("mock: no ERC-165");
        if (evilSupportsInterface) return true;
        return interfaceSupported[id];
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return ScaledUIMath.toUIDown(balanceOf[account], _uiMultiplier);
    }

    function totalSupplyUI() external view returns (uint256) {
        return ScaledUIMath.toUIDown(totalSupply, _uiMultiplier);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     ERC-20
    //////////////////////////////////////////////////////////////////////////*/

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        emit TransferWithScaledUI(msg.sender, to, amount, ScaledUIMath.toUIDown(amount, _uiMultiplier));
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Any selector this mock does not implement reverts, as a real contract
    ///      would. A consumer must survive that without bubbling.
    fallback() external {
        revert("mock: unsupported call");
    }
}
