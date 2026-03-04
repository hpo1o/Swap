// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockChainlinkFeed is AggregatorV3Interface {
    struct Round {
        int256  answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    int256  public currentPrice;
    uint8   public override decimals;
    uint80  public latestRound;

    mapping(uint80 => Round) public rounds;

    constructor(int256 _price, uint8 _decimals) {
        currentPrice = _price;
        decimals     = _decimals;
        latestRound  = 1;
        rounds[1] = Round({
            answer:    _price,
            startedAt: block.timestamp,
            updatedAt: block.timestamp
        });
    }

    function setRoundHistory(uint256 currentTime) external {
        uint256 spanSeconds = 600;
        uint256 count       = 10;
        uint256 step        = spanSeconds / count;

        for (uint256 i = 0; i < count; i++) {
            uint80  rid = uint80(i + 1);
            uint256 ts  = currentTime - spanSeconds + (i * step);
            rounds[rid] = Round({
                answer:    currentPrice,
                startedAt: ts,
                updatedAt: ts + step / 2
            });
        }
        latestRound = uint80(count);
    }

    function setPrice(int256 _price) external {
        currentPrice = _price;
        latestRound++;
        rounds[latestRound] = Round({
            answer:    _price,
            startedAt: block.timestamp,
            updatedAt: block.timestamp
        });
    }

    function description() external pure override returns (string memory) {
        return "Mock Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external view override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[latestRound];
        return (latestRound, r.answer, r.startedAt, r.updatedAt, latestRound);
    }

    function getRoundData(uint80 _roundId)
        external view override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[_roundId];
        return (_roundId, r.answer, r.startedAt, r.updatedAt, _roundId);
    }
}