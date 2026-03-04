// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {Pool} from "./Pool.sol";

contract SwapExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant EXECUTOR_FEE_BPS              = 10;
    uint32  public constant DEFAULT_ORACLE_TWAP_INTERVAL  = 300;
    uint256 public constant DEFAULT_MAX_PRICE_DEV_BPS     = 500;
    uint256 public constant DEFAULT_MAX_TWAP_SLIPPAGE_BPS = 1_500;
    uint256 public constant DEFAULT_MAX_ORACLE_DELAY      = 1 hours;
    uint256 public constant MAX_CHUNKS                    = 20;
    uint256 public constant MIN_POOL_LIQUIDITY_THRESHOLD  = 1_000e18;
    uint256 private constant BPS_DENOM                   = 10_000;

    // =========================================================================
    // Immutables
    // =========================================================================

    // solhint-disable var-name-mixedcase
    address public immutable FEE_RECIPIENT;
    AggregatorV3Interface public immutable CHAINLINK_FEED;
    address public immutable GUARDIAN;
    // solhint-enable var-name-mixedcase

    // =========================================================================
    // State
    // =========================================================================

    bool public paused;

    // =========================================================================
    // Events
    // =========================================================================

    event SwapExecuted(
        address indexed sender,
        address indexed pool,
        address tokenIn,
        address tokenOut,
        address indexed to,
        uint256 totalAmountIn,
        uint256 totalAmountOut,
        uint256 feeAmount,
        uint256 chunksUsed,
        uint256 oraclePriceX18
    );

    event ChunkExecuted(
        address indexed pool,
        uint256 chunkIndex,
        uint256 amountIn,
        uint256 amountOut,
        uint256 minAmountOut
    );

    event OracleChecked(
        uint256 oraclePriceX18,
        uint256 spotPriceX18,
        uint256 deviationBps,
        uint256 maxDeviationBps
    );

    event PauseToggled(address indexed guardian, bool paused);

    // =========================================================================
    // Errors
    // =========================================================================

    error Paused();
    error NotGuardian();
    error ZeroAddress();
    error Expired();
    error ZeroAmount();
    error InvalidInterval();
    error TotalSlippage(uint256 totalOut, uint256 minTotalOut);
    error TwapSlippageTooHigh(uint256 totalOut, uint256 minAcceptable);
    error PriceDeviationTooHigh(uint256 deviationBps, uint256 maxBps);
    error TooManyChunks(uint256 chunks, uint256 maxChunks);
    error PoolLiquidityTooLow(uint256 reserveIn, uint256 threshold);
    error OracleNoData();
    error OracleIncompleteRound();
    error OracleBadPrice();
    error OracleStale(uint256 age, uint256 maxDelay);
    error OracleTwapNoWindow();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _feeRecipient,
        address _chainlinkFeed,
        address _guardian
    ) {
        if (_feeRecipient  == address(0)) revert ZeroAddress();
        if (_chainlinkFeed == address(0)) revert ZeroAddress();
        if (_guardian      == address(0)) revert ZeroAddress();

        FEE_RECIPIENT  = _feeRecipient;
        CHAINLINK_FEED = AggregatorV3Interface(_chainlinkFeed);
        GUARDIAN       = _guardian;
    }

    // =========================================================================
    // Guardian
    // =========================================================================

    function togglePause() external onlyGuardian {
        paused = !paused;
        emit PauseToggled(msg.sender, paused);
    }

    // =========================================================================
    // External
    // =========================================================================

    function executeAutoChunkedSwap(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline
    ) external nonReentrant notPaused returns (uint256 totalOut) {
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
    ) external nonReentrant notPaused returns (uint256 totalOut) {
        totalOut = _executeAutoChunkedSwapWithOracleTwap(
            pool, tokenIn, totalAmountIn, minTotalOut, to, deadline,
            oracleTwapInterval, maxPriceDeviationBps,
            maxTwapSlippageBps, maxOracleDelay
        );
    }

    // =========================================================================
    // Internal core
    // =========================================================================

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
        if (block.timestamp > deadline) revert Expired();
        if (totalAmountIn == 0)         revert ZeroAmount();
        if (oracleTwapInterval == 0)    revert InvalidInterval();
        if (to == address(0))           revert ZeroAddress();

        address token0 = _validateToken(pool, tokenIn);

        uint256 oracleTwapPriceX18 = _checkOracleDeviation(
            pool, token0, oracleTwapInterval, maxOracleDelay, maxPriceDeviationBps
        );

        (uint256 chunks, uint256 amountPerChunk) = _calcChunks(
            pool, tokenIn, totalAmountIn, token0
        );

        totalOut = _runChunkLoop(
            pool, tokenIn, totalAmountIn, deadline,
            token0, oracleTwapPriceX18, maxTwapSlippageBps,
            chunks, amountPerChunk
        );

        if (totalOut < minTotalOut)
            revert TotalSlippage(totalOut, minTotalOut);

        _checkTwapSlippage(
            tokenIn, token0, totalAmountIn, totalOut,
            oracleTwapPriceX18, maxTwapSlippageBps
        );

        IERC20 tokenOutErc20 = pool.tokenOut(tokenIn);
        uint256 fee = (totalOut * EXECUTOR_FEE_BPS) / BPS_DENOM;

        if (fee > 0) tokenOutErc20.safeTransfer(FEE_RECIPIENT, fee);
        tokenOutErc20.safeTransfer(to, totalOut - fee);

        emit SwapExecuted(
            msg.sender,
            address(pool),
            tokenIn,
            address(tokenOutErc20),
            to,
            totalAmountIn,
            totalOut - fee,
            fee,
            chunks,
            oracleTwapPriceX18
        );
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

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
    ) internal returns (uint256 oracleTwapPriceX18) {
        oracleTwapPriceX18 = _chainlinkTwapX18(oracleTwapInterval, maxOracleDelay);
        uint256 spotPriceX18 = pool.getSpotPrice(token0);

        uint256 deviationBps =
            _absDiff(spotPriceX18, oracleTwapPriceX18) * BPS_DENOM / oracleTwapPriceX18;

        emit OracleChecked(
            oracleTwapPriceX18,
            spotPriceX18,
            deviationBps,
            maxPriceDeviationBps
        );

        if (deviationBps > maxPriceDeviationBps)
            revert PriceDeviationTooHigh(deviationBps, maxPriceDeviationBps);
    }

    function _calcChunks(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        address token0
    ) internal view returns (uint256 chunks, uint256 amountPerChunk) {
        (uint256 r0, uint256 r1) = pool.getReserves();
        uint256 reserveIn = tokenIn == token0 ? r0 : r1;

        if (reserveIn < MIN_POOL_LIQUIDITY_THRESHOLD)
            revert PoolLiquidityTooLow(reserveIn, MIN_POOL_LIQUIDITY_THRESHOLD);

        uint256 maxChunkSize = reserveIn / 10;
        if (maxChunkSize == 0) maxChunkSize = totalAmountIn;

        if (totalAmountIn <= maxChunkSize) {
            chunks = 1;
        } else {
            chunks = totalAmountIn / maxChunkSize;
            if (totalAmountIn % maxChunkSize != 0) chunks += 1;
        }

        if (chunks > MAX_CHUNKS) revert TooManyChunks(chunks, MAX_CHUNKS);

        amountPerChunk = totalAmountIn / chunks;
    }

    function _runChunkLoop(
        Pool    pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 deadline,
        address token0,
        uint256 oracleTwapPriceX18,
        uint256 maxTwapSlippageBps,
        uint256 chunks,
        uint256 amountPerChunk
    ) internal returns (uint256 totalOut) {
        bool zeroForOne = tokenIn == token0;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(pool), totalAmountIn);

        uint256 spent;

        for (uint256 i = 0; i < chunks; i++) {
            uint256 chunkAmount = i == chunks - 1
                ? totalAmountIn - spent
                : amountPerChunk;
            spent += chunkAmount;

            uint256 chunkExpectedOut = zeroForOne
                ? (chunkAmount * oracleTwapPriceX18) / 1e18
                : (chunkAmount * 1e18) / oracleTwapPriceX18;

            uint256 chunkMinOut =
                (chunkExpectedOut * (BPS_DENOM - maxTwapSlippageBps)) / BPS_DENOM;

            uint256 out = pool.swap(
                tokenIn, chunkAmount, chunkMinOut, address(this), deadline
            );
            totalOut += out;

            emit ChunkExecuted(address(pool), i, chunkAmount, out, chunkMinOut);
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

        if (totalOut < minAcceptable)
            revert TwapSlippageTooHigh(totalOut, minAcceptable);
    }

    function _chainlinkTwapX18(uint32 interval, uint256 maxOracleDelay)
        internal view returns (uint256 twapX18)
    {
        (
            uint80  latestRoundId,
            int256  latestAnswer,
            uint256 latestStartedAt,
            uint256 latestUpdatedAt,
            uint80  answeredInRound
        ) = CHAINLINK_FEED.latestRoundData();

        if (latestStartedAt == 0 || latestUpdatedAt == 0) revert OracleNoData();
        if (answeredInRound < latestRoundId)               revert OracleIncompleteRound();
        if (latestAnswer <= 0)                             revert OracleBadPrice();

        uint256 age = block.timestamp - latestUpdatedAt;
        if (age > maxOracleDelay) revert OracleStale(age, maxOracleDelay);

        uint8   decimals    = CHAINLINK_FEED.decimals();
        uint256 weightedSum;
        uint256 totalWeight;

        uint80  roundId     = latestRoundId;
        uint256 cursor      = block.timestamp;
        uint256 targetStart = block.timestamp - interval;

        for (uint256 i = 0; i < 24; i++) {
            (
                uint80  id,
                int256  answer,
                uint256 startedAt,
                uint256 updatedAt,
            ) = CHAINLINK_FEED.getRoundData(roundId);

            if (updatedAt == 0 || answer <= 0 || startedAt == 0) break;

            uint256 roundEnd   = cursor;
            uint256 roundStart = startedAt;

            if (roundEnd <= targetStart) break;
            if (roundStart < targetStart) roundStart = targetStart;

            uint256 weight = roundEnd > roundStart ? roundEnd - roundStart : 0;
            if (weight > 0) {
                weightedSum += _toX18(uint256(answer), decimals) * weight;
                totalWeight += weight;
            }

            if (id == 0) break;
            cursor  = startedAt;
            roundId = id - 1;
        }

        if (totalWeight == 0) revert OracleTwapNoWindow();
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