// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pool} from "./Pool.sol";

contract SwapExecutor {
    using SafeERC20 for IERC20;

    uint256 public constant EXECUTOR_FEE_BPS = 10; // 0.1% комиссия

    /// @notice Выполняет свап, автоматически разбивая на безопасные чанки
    function executeAutoChunkedSwap(Pool pool, address tokenIn, uint256 totalAmountIn, uint256 minTotalOut, address to)
        external
        returns (uint256 totalOut)
    {
        // 1️⃣ Получаем резервы пула
        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        uint256 reserveIn = tokenIn == address(pool.token0()) ? reserve0 : reserve1;

        // 2️⃣ Определяем максимальный безопасный размер одного свапа
        uint256 maxChunkSize = reserveIn / 10; // максимум 10% резерва
        if (maxChunkSize == 0) maxChunkSize = totalAmountIn; // для маленьких пулов

        // 3️⃣ Вычисляем количество чанков
        uint256 chunks = totalAmountIn / maxChunkSize;
        if (totalAmountIn % maxChunkSize != 0) chunks += 1;

        // 4️⃣ Размер одного чанка
        uint256 amountPerChunk = totalAmountIn / chunks;

        // 5️⃣ Переводим токены пользователя на контракт
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmountIn);

        // 6️⃣ Разрешаем пулу забирать токены
        SafeERC20.safeIncreaseAllowance(IERC20(tokenIn), address(pool), totalAmountIn);

        // 7️⃣ Основной цикл свапов
        for (uint256 i = 0; i < chunks; i++) {
            uint256 out = pool.swap(tokenIn, amountPerChunk, 0, address(this));
            totalOut += out;
        }

        // 8️⃣ Проверка minTotalOut (защита пользователя)
        require(totalOut >= minTotalOut, "TOTAL_SLIPPAGE");

        // 9️⃣ Снимаем комиссию
        uint256 fee = (totalOut * EXECUTOR_FEE_BPS) / 10_000;

        // 🔹 Правильное приведение типов
        IERC20 tokenOutERC20 = pool.tokenOut(tokenIn); // pool.tokenOut возвращает IERC20

        tokenOutERC20.safeTransfer(msg.sender, fee); // комиссия
        tokenOutERC20.safeTransfer(to, totalOut - fee); // остаток пользователю

        return totalOut;
    }
}
