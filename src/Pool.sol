// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

/// @title Pool — базовый AMM-пул для двух токенов
/// @notice Безопасный пул для тестов и портфолио, с фиксированной комиссией
contract Pool is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Observation {
        uint32 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 private reserve0;
    uint256 private reserve1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    Observation[] public observations;

    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant BPS_DENOM = 10_000;

    event Swap(
        address indexed sender,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );

    constructor(address _token0, address _token1) ERC20("LP TOKEN", "LP") {
        require(_token0 != _token1, "IDENTICAL_ADDRESSES");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);

        uint32 ts = uint32(block.timestamp);
        blockTimestampLast = ts;
        observations.push(
            Observation({
                timestamp: ts,
                price0Cumulative: 0,
                price1Cumulative: 0
            })
        );
    }

    /// @notice Возвращает текущие резервы
    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    function observationsLength() external view returns (uint256) {
        return observations.length;
    }

    function _recordObservation(uint32 blockTimestamp) internal {
        uint256 lastIndex = observations.length - 1;

        if (observations[lastIndex].timestamp == blockTimestamp) {
            observations[lastIndex].price0Cumulative = price0CumulativeLast;
            observations[lastIndex].price1Cumulative = price1CumulativeLast;
            return;
        }

        observations.push(
            Observation({
                timestamp: blockTimestamp,
                price0Cumulative: price0CumulativeLast,
                price1Cumulative: price1CumulativeLast
            })
        );
    }

    function _updateTWAP() internal {
        uint32 blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;

        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price0CumulativeLast += ((reserve1 * 1e18) / reserve0) * timeElapsed;
            price1CumulativeLast += ((reserve0 * 1e18) / reserve1) * timeElapsed;
        }

        blockTimestampLast = blockTimestamp;
        _recordObservation(blockTimestamp);
    }

    function _currentCumulatives()
        internal
        view
        returns (
            uint32 currentTimestamp,
            uint256 currentPrice0Cumulative,
            uint256 currentPrice1Cumulative
        )
    {
        currentTimestamp = uint32(block.timestamp);
        currentPrice0Cumulative = price0CumulativeLast;
        currentPrice1Cumulative = price1CumulativeLast;

        if (currentTimestamp > blockTimestampLast && reserve0 > 0 && reserve1 > 0) {
            uint32 timeElapsed = currentTimestamp - blockTimestampLast;
            currentPrice0Cumulative += ((reserve1 * 1e18) / reserve0) * timeElapsed;
            currentPrice1Cumulative += ((reserve0 * 1e18) / reserve1) * timeElapsed;
        }
    }

    /// @notice TWAP-цена для tokenIn -> tokenOut в 1e18 формате
    /// @dev Если недостаточно глубокой истории, используется максимально доступный интервал.
    function consult(address tokenIn, uint32 interval) external view returns (uint256 priceX18) {
        require(interval > 0, "INVALID_INTERVAL");
        require(tokenIn == address(token0) || tokenIn == address(token1), "INVALID_TOKEN_IN");

        (
            uint32 currentTimestamp,
            uint256 currentPrice0Cumulative,
            uint256 currentPrice1Cumulative
        ) = _currentCumulatives();

        Observation memory oldest = observations[0];
        Observation memory targetObs = oldest;

        if (currentTimestamp > interval) {
            uint32 targetTimestamp = currentTimestamp - interval;
            uint256 len = observations.length;

            for (uint256 i = len; i > 0; i--) {
                Observation memory obs = observations[i - 1];
                if (obs.timestamp <= targetTimestamp) {
                    targetObs = obs;
                    break;
                }
            }
        }

        uint32 elapsed = currentTimestamp - targetObs.timestamp;
        require(elapsed > 0, "NO_TIME_ELAPSED");

        uint256 avgPrice0X18 = (currentPrice0Cumulative - targetObs.price0Cumulative) / elapsed;
        uint256 avgPrice1X18 = (currentPrice1Cumulative - targetObs.price1Cumulative) / elapsed;

        priceX18 = tokenIn == address(token0) ? avgPrice0X18 : avgPrice1X18;
    }

    /// @notice Spot цена tokenIn -> tokenOut в 1e18 формате
    function getSpotPrice(address tokenIn) external view returns (uint256 priceX18) {
        require(tokenIn == address(token0) || tokenIn == address(token1), "INVALID_TOKEN_IN");
        require(reserve0 > 0 && reserve1 > 0, "NO_LIQUIDITY");

        priceX18 = tokenIn == address(token0)
            ? (reserve1 * 1e18) / reserve0
            : (reserve0 * 1e18) / reserve1;
    }

    function getTWAP() external view returns (uint256 price0TWAP) {
        price0TWAP = this.consult(address(token0), 1);
    }

    /// @notice Выполняет свап tokenIn -> tokenOut
    /// @param tokenIn токен, который пользователь отдаёт
    /// @param amountIn количество токена для свапа
    /// @param minAmountOut минимальное количество токена, которое пользователь хочет получить
    /// @param to адрес, на который отправить output токен
    /// @param deadline timestamp, после которого swap должен ревертиться
    /// @return amountOut количество полученного токена
    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(block.timestamp <= deadline, "EXPIRED");
        require(tokenIn == address(token0) || tokenIn == address(token1), "INVALID_TOKEN_IN");
        require(amountIn > 0, "ZERO_AMOUNT");

        _updateTWAP();

        bool zeroForOne = tokenIn == address(token0);
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountInWithFee = (amountIn * (BPS_DENOM - FEE_BPS)) / BPS_DENOM;
        amountOut = getAmountOut(amountInWithFee, reserveIn, reserveOut);

        require(amountOut >= minAmountOut, "SLIPPAGE_TOO_HIGH");
        require(amountOut <= reserveOut, "INSUFFICIENT_LIQUIDITY");

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        tokenOut(tokenIn).safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    /// @notice Возвращает токен, который будет выдан
    function tokenOut(address tokenIn) public view returns (IERC20) {
        require(tokenIn == address(token0) || tokenIn == address(token1), "INVALID_TOKEN_IN");
        return tokenIn == address(token0) ? token1 : token0;
    }

    /// @dev Базовая формула AMM x*y=k
    function getAmountOut(uint256 amountInWithFee, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(reserveIn > 0 && reserveOut > 0, "NO_LIQUIDITY");
        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
    }

    function addLiquidity(
        uint256 amount0,
        uint256 amount1
    )
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        _updateTWAP();
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        if (totalSupply() == 0) {
            liquidity = SwapMath.sqrt(amount0 * amount1);
        } else {
            liquidity = SwapMath.min(
                (amount0 * totalSupply()) / reserve0,
                (amount1 * totalSupply()) / reserve1
            );
        }

        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");

        _mint(msg.sender, liquidity);

        reserve0 += amount0;
        reserve1 += amount1;
    }

    function removeLiquidity(uint256 liquidity)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _updateTWAP();
        require(liquidity > 0, "ZERO_LIQUIDITY");

        uint256 supply = totalSupply();

        amount0 = (liquidity * reserve0) / supply;
        amount1 = (liquidity * reserve1) / supply;

        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_OUTPUT");

        _burn(msg.sender, liquidity);

        reserve0 -= amount0;
        reserve1 -= amount1;

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
    }
}
