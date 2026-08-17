// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MockAggregatorV3
 * @notice Minimal Chainlink AggregatorV3 stand-in.
 *
 * @dev Models the Robinhood tokenized-equity feed convention: the published
 *      answer is `underlying equity price * uiMultiplier`, i.e. the price of ONE
 *      RAW TOKEN, with the corporate action ALREADY APPLIED. That is the whole
 *      basis of the double-counting trap -- see `DoubleCountDemo.t.sol`.
 *
 *      {holdStale} reproduces the paused-feed behaviour: when the token's
 *      `oraclePaused()` flag is set, the real feed stops publishing and HOLDS its
 *      last value. Note what that means for a consumer: `latestRoundData()` keeps
 *      returning a plausible, positive, structurally valid answer. Nothing in the
 *      Chainlink response signals the problem. Only the token's flag does.
 */
contract MockAggregatorV3 {
    uint8 public decimals;
    string public description;
    uint256 public constant version = 4;

    uint80 private _roundId = 1;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound = 1;

    /// @notice When true, `updatedAt` stops advancing -- the feed is holding a stale value.
    bool public holdStale;

    constructor(uint8 decimals_, int256 initialAnswer, string memory description_) {
        decimals = decimals_;
        description = description_;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    /// @notice Publish a new answer at the current timestamp.
    function setAnswer(int256 answer) external {
        _roundId += 1;
        _answeredInRound = _roundId;
        _answer = answer;
        _startedAt = block.timestamp;
        if (!holdStale) _updatedAt = block.timestamp;
    }

    /// @notice Freeze `updatedAt`, so the answer ages while remaining well-formed.
    function setHoldStale(bool v) external {
        holdStale = v;
    }

    /// @notice Force `updatedAt` to an arbitrary value, for staleness testing.
    function setUpdatedAt(uint256 t) external {
        _updatedAt = t;
    }

    /// @notice Model an in-progress round: `answeredInRound < roundId`.
    function setIncompleteRound() external {
        _roundId += 1; // answeredInRound deliberately left behind
    }

    /// @notice Model the zero/negative answer a misconfigured feed can return.
    function setRawAnswer(int256 answer) external {
        _answer = answer;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
