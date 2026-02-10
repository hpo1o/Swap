// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    AggregatorV3Interface
} from "./interfaces/AggregatorV3Interface.sol";
import {Pool} from "./Pool.sol";

contract SwapExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EXECUTOR_FEE_BPS = 10; // 0.1% комиссия
    uint32 public constant DEFAULT_ORACLE_TWAP_INTERVAL = 300; // 5 минут
    uint256 public constant DEFAULT_MAX_PRICE_DEVIATION_BPS = 500; // 5%
    uint256 public constant DEFAULT_MAX_TWAP_SLIPPAGE_BPS = 1500; // 15%
    uint256 public constant DEFAULT_MAX_ORACLE_DELAY = 1 hours;
    uint256 private constant BPS_DENOM = 10_000;

    address public immutable feeRecipient;
    AggregatorV3Interface public immutable chainlinkFeed;

    constructor(address _feeRecipient, address _chainlinkFeed) {
        require(_feeRecipient != address(0), "ZERO_FEE_RECIPIENT");
        require(_chainlinkFeed != address(0), "ZERO_CHAINLINK_FEED");

        feeRecipient = _feeRecipient;
        chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
    }

    function executeAutoChunkedSwap(
        Pool pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 totalOut) {
        totalOut = _executeAutoChunkedSwapWithOracleTwap(
            pool,
            tokenIn,
            totalAmountIn,
            minTotalOut,
            to,
            deadline,
            DEFAULT_ORACLE_TWAP_INTERVAL,
            DEFAULT_MAX_PRICE_DEVIATION_BPS,
            DEFAULT_MAX_TWAP_SLIPPAGE_BPS,
            DEFAULT_MAX_ORACLE_DELAY
        );
    }

    function executeAutoChunkedSwapWithOracleParams(
        Pool pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline,
        uint32 oracleTwapInterval,
        uint256 maxPriceDeviationBps,
        uint256 maxTwapSlippageBps,
        uint256 maxOracleDelay
    ) external nonReentrant returns (uint256 totalOut) {
        totalOut = _executeAutoChunkedSwapWithOracleTwap(
            pool,
            tokenIn,
            totalAmountIn,
            minTotalOut,
            to,
            deadline,
            oracleTwapInterval,
            maxPriceDeviationBps,
            maxTwapSlippageBps,
            maxOracleDelay
        );
    }

    function _executeAutoChunkedSwapWithOracleTwap(
        Pool pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline,
        uint32 oracleTwapInterval,
        uint256 maxPriceDeviationBps,
        uint256 maxTwapSlippageBps,
        uint256 maxOracleDelay
    ) internal returns (uint256 totalOut) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(totalAmountIn > 0, "ZERO_AMOUNT");
        require(oracleTwapInterval > 0, "INVALID_INTERVAL");

        (address token0, address token1) = _validateToken(pool, tokenIn);
        uint256 oracleTwapPriceX18 = _checkOracleDeviation(
            pool,
            token0,
            oracleTwapInterval,
            maxOracleDelay,
            maxPriceDeviationBps
        );

        totalOut = _executeChunks(pool, tokenIn, totalAmountIn, deadline, token0);

        require(totalOut >= minTotalOut, "TOTAL_SLIPPAGE");

        _checkTwapSlippage(
            tokenIn,
            token0,
            totalAmountIn,
            totalOut,
            oracleTwapPriceX18,
            maxTwapSlippageBps
        );

        uint256 fee = (totalOut * EXECUTOR_FEE_BPS) / BPS_DENOM;
        IERC20 tokenOutERC20 = pool.tokenOut(tokenIn);

        if (fee > 0) {
            tokenOutERC20.safeTransfer(feeRecipient, fee);
        }
        tokenOutERC20.safeTransfer(to, totalOut - fee);

        return totalOut;
    }

    function _validateToken(
        Pool pool,
        address tokenIn
    ) internal view returns (address token0, address token1) {
        token0 = address(pool.token0());
        token1 = address(pool.token1());
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN_IN");
    }

    function _checkOracleDeviation(
        Pool pool,
        address token0,
        uint32 oracleTwapInterval,
        uint256 maxOracleDelay,
        uint256 maxPriceDeviationBps
    ) internal view returns (uint256 oracleTwapPriceX18) {
        oracleTwapPriceX18 = _chainlinkTwapX18(oracleTwapInterval, maxOracleDelay);
        uint256 spotPriceX18 = pool.getSpotPrice(token0);

        uint256 deviationBps =
            _absDiff(spotPriceX18, oracleTwapPriceX18) * BPS_DENOM / oracleTwapPriceX18;
        require(deviationBps <= maxPriceDeviationBps, "PRICE_DEVIATION_TOO_HIGH");
    }

    function _executeChunks(
        Pool pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 deadline,
        address token0
    ) internal returns (uint256 totalOut) {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        uint256 reserveIn = tokenIn == token0 ? reserve0 : reserve1;

        uint256 maxChunkSize = reserveIn / 10;
        if (maxChunkSize == 0) maxChunkSize = totalAmountIn;

        uint256 chunks = totalAmountIn / maxChunkSize;
        if (totalAmountIn % maxChunkSize != 0) chunks += 1;

        uint256 amountPerChunk = totalAmountIn / chunks;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(pool), totalAmountIn);

        uint256 spent;
        for (uint256 i = 0; i < chunks; i++) {
            uint256 amountThisChunk = i == chunks - 1 ? totalAmountIn - spent : amountPerChunk;
            spent += amountThisChunk;

            uint256 out = pool.swap(tokenIn, amountThisChunk, 0, address(this), deadline);
            totalOut += out;
        }
    }

    function _checkTwapSlippage(
        address tokenIn,
        address token0,
        uint256 totalAmountIn,
        uint256 totalOut,
        uint256 oracleTwapPriceX18,
        uint256 maxTwapSlippageBps
    ) internal pure {
        uint256 twapExpectedOut = tokenIn == token0
            ? (totalAmountIn * oracleTwapPriceX18) / 1e18
            : (totalAmountIn * 1e18) / oracleTwapPriceX18;

        uint256 minAcceptableOutByTwap =
            (twapExpectedOut * (BPS_DENOM - maxTwapSlippageBps)) / BPS_DENOM;
        require(totalOut >= minAcceptableOutByTwap, "TWAP_SLIPPAGE_TOO_HIGH");
    }

    function _chainlinkTwapX18(uint32 interval, uint256 maxOracleDelay)
        internal
        view
        returns (uint256 twapX18)
    {
        (
            uint80 latestRoundId,
            int256 latestAnswer,
            uint256 startedAt,
            uint256 latestUpdatedAt,
            uint80 answeredInRound
        ) = chainlinkFeed.latestRoundData();

        require(startedAt != 0, "ORACLE_NO_DATA");
        require(answeredInRound >= latestRoundId, "ORACLE_INCOMPLETE_ROUND");

        require(latestAnswer > 0, "ORACLE_BAD_PRICE");
        require(latestUpdatedAt != 0, "ORACLE_NO_DATA");
        require(block.timestamp - latestUpdatedAt <= maxOracleDelay, "ORACLE_STALE");

        uint8 decimals = chainlinkFeed.decimals();

        uint256 weightedSum;
        uint256 totalWeight;

        uint80 roundId = latestRoundId;
        uint256 cursor = block.timestamp;
        uint256 targetStart = block.timestamp - interval;

        for (uint256 i = 0; i < 24; i++) {
            (uint80 id, int256 answer, , uint256 updatedAt, ) = chainlinkFeed.getRoundData(roundId);
            if (updatedAt == 0 || answer <= 0) break;

            uint256 roundEnd = cursor;
            uint256 roundStart = updatedAt;

            if (roundEnd <= targetStart) break;
            if (roundStart < targetStart) roundStart = targetStart;

            uint256 weight = roundEnd - roundStart;
            if (weight > 0) {
                uint256 priceX18 = _toX18(uint256(answer), decimals);
                weightedSum += priceX18 * weight;
                totalWeight += weight;
            }

            if (id == 0) break;
            cursor = updatedAt;
            roundId = id - 1;
        }

        require(totalWeight > 0, "ORACLE_TWAP_NO_WINDOW");
        twapX18 = weightedSum / totalWeight;
    }

    function _toX18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function _chainlinkTwapX18(uint32 interval, uint256 maxOracleDelay)
        internal
        view
        returns (uint256 twapX18)
    {
        (
            uint80 latestRoundId,
            int256 latestAnswer,
            uint256 startedAt,
            uint256 latestUpdatedAt,
            uint80 answeredInRound
        ) = chainlinkFeed.latestRoundData();

        require(startedAt != 0, "ORACLE_NO_DATA");
        require(answeredInRound >= latestRoundId, "ORACLE_INCOMPLETE_ROUND");

        require(latestAnswer > 0, "ORACLE_BAD_PRICE");
        require(latestUpdatedAt != 0, "ORACLE_NO_DATA");
        require(block.timestamp - latestUpdatedAt <= maxOracleDelay, "ORACLE_STALE");

        uint8 decimals = chainlinkFeed.decimals();

        uint256 weightedSum;
        uint256 totalWeight;

        uint80 roundId = latestRoundId;
        uint256 cursor = block.timestamp;
        uint256 targetStart = block.timestamp - interval;

        for (uint256 i = 0; i < 24; i++) {
            (uint80 id, int256 answer, , uint256 updatedAt, ) = chainlinkFeed.getRoundData(roundId);
            if (updatedAt == 0 || answer <= 0) break;

            uint256 roundEnd = cursor;
            uint256 roundStart = updatedAt;

            if (roundEnd <= targetStart) break;
            if (roundStart < targetStart) roundStart = targetStart;

            uint256 weight = roundEnd - roundStart;
            if (weight > 0) {
                uint256 priceX18 = _toX18(uint256(answer), decimals);
                weightedSum += priceX18 * weight;
                totalWeight += weight;
            }

            if (id == 0) break;
            cursor = updatedAt;
            roundId = id - 1;
        }

        require(totalWeight > 0, "ORACLE_TWAP_NO_WINDOW");
        twapX18 = weightedSum / totalWeight;
    }

    function _toX18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
