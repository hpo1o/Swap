// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Pool — базовый AMM-пул для двух токенов
/// @notice Безопасный пул для тестов и портфолио, с фиксированной комиссией
contract Pool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 private reserve0;
    uint256 private reserve1;

    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant BPS_DENOM = 10_000;

    event Swap(address indexed sender, address tokenIn, uint256 amountIn, uint256 amountOut, address indexed to);

    constructor(address _token0, address _token1) {
        require(_token0 != _token1, "IDENTICAL_ADDRESSES");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /// @notice Возвращает текущие резервы
    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Выполняет свап tokenIn -> tokenOut
    /// @param tokenIn токен, который пользователь отдаёт
    /// @param amountIn количество токена для свапа
    /// @param minAmountOut минимальное количество токена, которое пользователь хочет получить
    /// @param to адрес, на который отправить output токен
    /// @return amountOut количество полученного токена
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to)
        external
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn == address(token0);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        require(amountIn > 0, "ZERO_AMOUNT");

        // Забираем токен у пользователя
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Рассчитываем output с комиссией
        uint256 amountInWithFee = (amountIn * (BPS_DENOM - FEE_BPS)) / BPS_DENOM;
        amountOut = getAmountOut(amountInWithFee, reserveIn, reserveOut);

        require(amountOut >= minAmountOut, "SLIPPAGE_TOO_HIGH");
        require(amountOut <= reserveOut, "INSUFFICIENT_LIQUIDITY");

        // Обновляем резервы
        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Отправляем output пользователю
        IERC20(tokenOut(tokenIn)).safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, to);
    }

    /// @notice Возвращает токен, который будет выдан
    function tokenOut(address tokenIn) public view returns (IERC20) {
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

    /// @notice Функция для добавления ликвидности (для тестов)
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        require(amount0 > 0 && amount1 > 0, "ZERO_AMOUNT");
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
    }
}
