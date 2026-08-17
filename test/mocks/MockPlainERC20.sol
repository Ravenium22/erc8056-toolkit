// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MockPlainERC20
 * @notice A vanilla ERC-20 with no ERC-8056 surface and no ERC-165 at all.
 *
 * @dev This is the degradation case. A consumer must read this token without
 *      reverting and must treat its multiplier as exactly 1e18. USDG and WETH on
 *      Robinhood Chain behave this way, and they sit on the other side of most
 *      stock-token pairs -- so any reader that only works on ERC-8056 tokens is
 *      useless in the pools where stock tokens actually trade.
 *
 *      Deliberately has NO `supportsInterface`: the call hits the fallback and
 *      reverts, which is the common real-world case and the one a `try/catch`
 *      must absorb.
 */
contract MockPlainERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev No ERC-165, no ERC-8056. Unknown selectors revert.
    fallback() external {
        revert("plain: unsupported call");
    }
}
