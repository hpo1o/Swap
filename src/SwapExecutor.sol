// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {Pool} from "./Pool.sol";

/// @title  SwapExecutor — исполнитель чанкованных свапов с Oracle/TWAP защитой
/// @dev    Исправления аудита:
///         [H-3] minAmountOut рассчитывается для каждого чанка
///         [H-4] Chainlink TWAP использует startedAt как границу раунда
///         [L-2] Проверка to != address(0)
///         [L-3] _validateToken возвращает только token0
contract SwapExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EXECUTOR_FEE_BPS              = 10;
    uint32  public constant DEFAULT_ORACLE_TWAP_INTERVAL  = 300;
    uint256 public constant DEFAULT_MAX_PRICE_DEV_BPS     = 500;
    uint256 public constant DEFAULT_MAX_TWAP_SLIPPAGE_BPS = 1500;
    uint256 public constant DEFAULT_MAX_ORACLE_DELAY      = 1 hours;
    uint256 private constant BPS_DENOM                    = 10_000;

    address public immutable feeRecipient;
    AggregatorV3Interface public immutable chainlinkFeed;

    constructor(address _feeRecipient, address _chainlinkFeed) {
        require(_feeRecipient != address(0), "ZERO_FEE_RECIPIENT");
        require(_chainlinkFeed != address(0), "ZERO_CHAINLINK_FEED");
        feeRecipient  = _feeRecipient;
        chainlinkFeed = AggregatorV3Interface(_chainlinkFeed);
    }

    function executeAutoChunkedSwap(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 totalOut) {
        totalOut = _executeAutoChunkedSwapWithOracleTwap(
            pool, tokenIn, totalAmountIn, minTotalOut, to, deadline,
            DEFAULT_ORACLE_TWAP_INTERVAL,
            DEFAULT_MAX_PRICE_DEV_BPS,
            DEFAULT_MAX_TWAP_SLIPPAGE_BPS,
            DEFAULT_MAX_ORACLE_DELAY
        );
    }

    function executeAutoChunkedSwapWithOracleParams(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline,
        uint32  oracleTwapInterval,
        uint256 maxPriceDeviationBps,
        uint256 maxTwapSlippageBps,
        uint256 maxOracleDelay
    ) external nonReentrant returns (uint256 totalOut) {
        totalOut = _executeAutoChunkedSwapWithOracleTwap(
            pool, tokenIn, totalAmountIn, minTotalOut, to, deadline,
            oracleTwapInterval, maxPriceDeviationBps,
            maxTwapSlippageBps, maxOracleDelay
        );
    }

    // ── internal core ────────────────────────────────────────────────────────

    function _executeAutoChunkedSwapWithOracleTwap(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline,
        uint32  oracleTwapInterval,
        uint256 maxPriceDeviationBps,
        uint256 maxTwapSlippageBps,
        uint256 maxOracleDelay
    ) internal returns (uint256 totalOut) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(totalAmountIn > 0, "ZERO_AMOUNT");
        require(oracleTwapInterval > 0, "INVALID_INTERVAL");
        require(to != address(0), "ZERO_TO_ADDRESS"); // [FIX L-2]

        address token0 = _validateToken(pool, tokenIn); // [FIX L-3]

        uint256 oracleTwapPriceX18 = _checkOracleDeviation(
            pool, token0, oracleTwapInterval, maxOracleDelay, maxPriceDeviationBps
        );

        totalOut = _executeChunks(
            pool, tokenIn, totalAmountIn, deadline, token0, oracleTwapPriceX18, maxTwapSlippageBps
        );

        require(totalOut >= minTotalOut, "TOTAL_SLIPPAGE");

        _checkTwapSlippage(
            tokenIn, token0, totalAmountIn, totalOut,
            oracleTwapPriceX18, maxTwapSlippageBps
        );

        uint256 fee = (totalOut * EXECUTOR_FEE_BPS) / BPS_DENOM;
        IERC20 tokenOutERC20 = pool.tokenOut(tokenIn);

        if (fee > 0) tokenOutERC20.safeTransfer(feeRecipient, fee);
        tokenOutERC20.safeTransfer(to, totalOut - fee);
    }

    // [FIX L-3] возвращает только token0, token1 не нужен снаружи
    function _validateToken(Pool pool, address tokenIn)
        internal view returns (address token0)
    {
        token0 = address(pool.TOKEN0());
        address token1 = address(pool.TOKEN1());
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN_IN");
    }

    function _checkOracleDeviation(
        Pool    pool,
        address token0,
        uint32  oracleTwapInterval,
        uint256 maxOracleDelay,
        uint256 maxPriceDeviationBps
    ) internal view returns (uint256 oracleTwapPriceX18) {
        oracleTwapPriceX18 = _chainlinkTwapX18(oracleTwapInterval, maxOracleDelay);
        uint256 spotPriceX18 = pool.getSpotPrice(token0);

        uint256 deviationBps =
            _absDiff(spotPriceX18, oracleTwapPriceX18) * BPS_DENOM / oracleTwapPriceX18;
        require(deviationBps <= maxPriceDeviationBps, "PRICE_DEVIATION_TOO_HIGH");
    }

    /// @dev [FIX H-3] Рассчитываем minAmountOut для каждого чанка через TWAP,
    ///      а не только постфактум для всего объёма.
    function _executeChunks(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 deadline,
        address token0,
        uint256 oracleTwapPriceX18,
        uint256 maxTwapSlippageBps
    ) internal returns (uint256 totalOut) {
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        bool    zeroForOne  = tokenIn == token0;
        uint256 reserveIn   = zeroForOne ? reserve0 : reserve1;

        uint256 maxChunkSize = reserveIn / 10;
        if (maxChunkSize == 0) maxChunkSize = totalAmountIn;

        uint256 chunks = totalAmountIn / maxChunkSize;
        if (totalAmountIn % maxChunkSize != 0) chunks += 1;

        uint256 amountPerChunk = totalAmountIn / chunks;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(pool), totalAmountIn);

        uint256 spent;
        for (uint256 i = 0; i < chunks; i++) {
            uint256 chunkAmount = i == chunks - 1
                ? totalAmountIn - spent
                : amountPerChunk;
            spent += chunkAmount;

            // [FIX H-3] minAmountOut на уровне чанка — защита от манипуляций
            // между итерациями (если дизайн расширится на мульти-блок)
            uint256 chunkExpectedOut = zeroForOne
                ? (chunkAmount * oracleTwapPriceX18) / 1e18
                : (chunkAmount * 1e18) / oracleTwapPriceX18;

            uint256 chunkMinOut =
                (chunkExpectedOut * (BPS_DENOM - maxTwapSlippageBps)) / BPS_DENOM;

            uint256 out = pool.swap(tokenIn, chunkAmount, chunkMinOut, address(this), deadline);
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

        uint256 minAcceptable =
            (twapExpectedOut * (BPS_DENOM - maxTwapSlippageBps)) / BPS_DENOM;
        require(totalOut >= minAcceptable, "TWAP_SLIPPAGE_TOO_HIGH");
    }

    /// @dev [FIX H-4] Правильная логика Chainlink TWAP.
    ///      cursor = startedAt текущего раунда (начало), не updatedAt (конец).
    ///      Это даёт корректные непересекающиеся временны́е окна раундов.
    function _chainlinkTwapX18(uint32 interval, uint256 maxOracleDelay)
        internal view returns (uint256 twapX18)
    {
        (
            uint80 latestRoundId,
            int256 latestAnswer,
            uint256 latestStartedAt,
            uint256 latestUpdatedAt,
            uint80 answeredInRound
        ) = chainlinkFeed.latestRoundData();

        require(latestStartedAt != 0,              "ORACLE_NO_DATA");
        require(answeredInRound >= latestRoundId,   "ORACLE_INCOMPLETE_ROUND");
        require(latestAnswer > 0,                   "ORACLE_BAD_PRICE");
        require(latestUpdatedAt != 0,               "ORACLE_NO_DATA");
        require(block.timestamp - latestUpdatedAt <= maxOracleDelay, "ORACLE_STALE");

        uint8   decimals    = chainlinkFeed.decimals();
        uint256 weightedSum;
        uint256 totalWeight;

        uint80  roundId    = latestRoundId;
        uint256 cursor     = block.timestamp; // верхняя граница текущего окна
        uint256 targetStart = block.timestamp - interval;

        for (uint256 i = 0; i < 24; i++) {
            (
                uint80  id,
                int256  answer,
                uint256 startedAt,
                uint256 updatedAt,
            ) = chainlinkFeed.getRoundData(roundId);

            if (updatedAt == 0 || answer <= 0 || startedAt == 0) break;

            uint256 roundEnd   = cursor;
            // [FIX H-4] Начало раунда — startedAt, не updatedAt
            uint256 roundStart = startedAt;

            if (roundEnd <= targetStart) break;
            if (roundStart < targetStart) roundStart = targetStart;

            uint256 weight = roundEnd > roundStart ? roundEnd - roundStart : 0;
            if (weight > 0) {
                weightedSum += _toX18(uint256(answer), decimals) * weight;
                totalWeight += weight;
            }

            if (id == 0) break;
            // [FIX H-4] cursor сдвигается к startedAt текущего раунда —
            // это нижняя граница окна, она же верхняя граница следующего
            cursor  = startedAt;
            roundId = id - 1;
        }

        require(totalWeight > 0, "ORACLE_TWAP_NO_WINDOW");
        twapX18 = weightedSum / totalWeight;
    }

    function _toX18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18)  return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}