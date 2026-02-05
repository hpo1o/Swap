// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pool} from "./Pool.sol";

contract SwapExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EXECUTOR_FEE_BPS = 10; // 0.1% комиссия
    address public immutable feeRecipient;

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "ZERO_FEE_RECIPIENT");
        feeRecipient = _feeRecipient;
    }

    /// @notice Выполняет свап, автоматически разбивая на безопасные чанки
    function executeAutoChunkedSwap(
        Pool pool,
        address tokenIn,
        uint256 totalAmountIn,
        uint256 minTotalOut,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256 totalOut) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(totalAmountIn > 0, "ZERO_AMOUNT");

        address token0 = address(pool.token0());
        address token1 = address(pool.token1());
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN_IN");

        (uint256 reserve0, uint256 reserve1) = pool.getReserves();
        uint256 reserveIn = tokenIn == token0 ? reserve0 : reserve1;

        uint256 maxChunkSize = reserveIn / 10; // максимум 10% резерва
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

        require(totalOut >= minTotalOut, "TOTAL_SLIPPAGE");

        uint256 fee = (totalOut * EXECUTOR_FEE_BPS) / 10_000;
        IERC20 tokenOutERC20 = pool.tokenOut(tokenIn);

        if (fee > 0) {
            tokenOutERC20.safeTransfer(feeRecipient, fee);
        }
        tokenOutERC20.safeTransfer(to, totalOut - fee);

        return totalOut;
    }
}
