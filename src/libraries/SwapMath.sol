// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SwapMath {
    error InsufficientInputAmount();
    error InsufficientLiquidity();

    /// @notice Constant Product formula with fee
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps // например 30 = 0.3%
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * (10_000 - feeBps);

        uint256 numerator = amountInWithFee * reserveOut;

        uint256 denominator = reserveIn * 10_000 + amountInWithFee;

        amountOut = numerator / denominator;
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }
}
