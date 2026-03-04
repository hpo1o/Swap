// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

contract Pool is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    struct Observation {
        uint32  timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public  constant FEE_BPS           = 30;
    uint256 public  constant BPS_DENOM         = 10_000;
    uint256 private constant MINIMUM_LIQUIDITY = 1_000;
    address private constant DEAD_ADDRESS      = address(0xdead);
    uint16  public  constant OBS_CARDINALITY   = 720;

    // =========================================================================
    // Immutables
    // =========================================================================

    // solhint-disable var-name-mixedcase
    IERC20  public immutable TOKEN0;
    IERC20  public immutable TOKEN1;
    address public immutable GUARDIAN;
    // solhint-enable var-name-mixedcase

    // =========================================================================
    // State
    // =========================================================================

    bool public paused;

    uint256 private reserve0;
    uint256 private reserve1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32  public blockTimestampLast;

    Observation[720] public observations;
    uint16 public observationIndex;
    uint16 public observationCount;

    // =========================================================================
    // Events
    // =========================================================================

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut,
        uint256 reserve0After,
        uint256 reserve1After
    );

    event AddLiquidity(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity,
        uint256 reserve0After,
        uint256 reserve1After,
        uint256 totalSupplyAfter
    );

    event RemoveLiquidity(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity,
        uint256 reserve0After,
        uint256 reserve1After,
        uint256 totalSupplyAfter
    );

    event PauseToggled(address indexed guardian, bool paused);

    event FeeOnTransferDetected(
        address indexed token,
        uint256 expected,
        uint256 actual
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error Paused();
    error NotGuardian();
    error ZeroAddress();
    error IdenticalAddresses();
    error Expired();
    error InvalidTokenIn();
    error ZeroAmount();
    error InvalidTo();
    error SlippageTooHigh(uint256 amountOut, uint256 minAmountOut);
    error ZeroOutput();
    error InsufficientLiquidity();
    error InitialLiquidityTooLow();
    error InsufficientLiquidityMinted();
    error MinLiquidity(uint256 liquidity, uint256 minLiquidity);
    error InsufficientOutput();
    error MinOutput();
    error NoSupply();
    error IntervalTooShort();
    error NoTimeElapsed();
    error NoLiquidity();
    error FeeOnTransferToken(address token, uint256 expected, uint256 actual);

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
        address _token0,
        address _token1,
        address _guardian
    ) ERC20("LP TOKEN", "LP") {
        if (_token0 == address(0) || _token1 == address(0) || _guardian == address(0))
            revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalAddresses();

        (TOKEN0, TOKEN1) = _token0 < _token1
            ? (IERC20(_token0), IERC20(_token1))
            : (IERC20(_token1), IERC20(_token0));

        GUARDIAN = _guardian;

        uint32 ts = uint32(block.timestamp);
        blockTimestampLast = ts;
        observations[0] = Observation({
            timestamp:        ts,
            price0Cumulative: 0,
            price1Cumulative: 0
        });
        observationCount = 1;
    }

    // =========================================================================
    // Guardian
    // =========================================================================

    function togglePause() external onlyGuardian {
        paused = !paused;
        emit PauseToggled(msg.sender, paused);
    }

    // =========================================================================
    // View
    // =========================================================================

    function getReserves() external view returns (uint256 r0, uint256 r1) {
        return (reserve0, reserve1);
    }

    function getSpotPrice(address tokenIn) external view returns (uint256 priceX18) {
        if (tokenIn != address(TOKEN0) && tokenIn != address(TOKEN1))
            revert InvalidTokenIn();
        if (reserve0 == 0 || reserve1 == 0) revert NoLiquidity();

        priceX18 = tokenIn == address(TOKEN0)
            ? (reserve1 * 1e18) / reserve0
            : (reserve0 * 1e18) / reserve1;
    }

    function consult(address tokenIn, uint32 interval)
        external view returns (uint256 priceX18)
    {
        if (interval < 300) revert IntervalTooShort();
        if (tokenIn != address(TOKEN0) && tokenIn != address(TOKEN1))
            revert InvalidTokenIn();

        (uint32 currentTs, uint256 cum0, uint256 cum1) = _currentCumulatives();
        Observation memory targetObs = _findObservation(currentTs, interval);

        uint32 elapsed = currentTs - targetObs.timestamp;
        if (elapsed == 0) revert NoTimeElapsed();

        priceX18 = tokenIn == address(TOKEN0)
            ? (cum0 - targetObs.price0Cumulative) / elapsed
            : (cum1 - targetObs.price1Cumulative) / elapsed;
    }

    function getTwap() external view returns (uint256) {
        return this.consult(address(TOKEN0), 1_800);
    }

    function tokenOut(address tokenIn) public view returns (IERC20) {
        if (tokenIn != address(TOKEN0) && tokenIn != address(TOKEN1))
            revert InvalidTokenIn();
        return tokenIn == address(TOKEN0) ? TOKEN1 : TOKEN0;
    }

    // =========================================================================
    // Swap
    // =========================================================================

    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        notPaused
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline)                               revert Expired();
        if (tokenIn != address(TOKEN0) && tokenIn != address(TOKEN1)) revert InvalidTokenIn();
        if (amountIn == 0)                                            revert ZeroAmount();
        if (to == address(0))                                         revert ZeroAddress();
        if (to == address(TOKEN0) || to == address(TOKEN1))           revert InvalidTo();

        _updateTwap();

        bool zeroForOne = tokenIn == address(TOKEN0);
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        // FOT защита — проверяем фактически полученную сумму
        uint256 balBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 actualAmountIn = IERC20(tokenIn).balanceOf(address(this)) - balBefore;

        if (actualAmountIn != amountIn) {
            emit FeeOnTransferDetected(tokenIn, amountIn, actualAmountIn);
            revert FeeOnTransferToken(tokenIn, amountIn, actualAmountIn);
        }

        amountOut = SwapMath.getAmountOut(amountIn, reserveIn, reserveOut, FEE_BPS);

        if (amountOut < minAmountOut) revert SlippageTooHigh(amountOut, minAmountOut);
        if (amountOut == 0)           revert ZeroOutput();
        if (amountOut >= reserveOut)  revert InsufficientLiquidity();

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        tokenOut(tokenIn).safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, to, amountIn, amountOut, reserve0, reserve1);
    }

    // =========================================================================
    // Liquidity
    // =========================================================================

    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 minLiquidity,
        uint256 deadline
    )
        external
        nonReentrant
        notPaused
        returns (uint256 liquidity)
    {
        if (block.timestamp > deadline)                     revert Expired();
        if (amount0Desired == 0 || amount1Desired == 0)     revert ZeroAmount();

        _updateTwap();

        (uint256 amount0, uint256 amount1) = _calcOptimalAmounts(
            amount0Desired, amount1Desired, amount0Min, amount1Min
        );

        // FOT защита для TOKEN0
        uint256 bal0Before = TOKEN0.balanceOf(address(this));
        TOKEN0.safeTransferFrom(msg.sender, address(this), amount0);
        uint256 actual0 = TOKEN0.balanceOf(address(this)) - bal0Before;
        if (actual0 != amount0) {
            emit FeeOnTransferDetected(address(TOKEN0), amount0, actual0);
            revert FeeOnTransferToken(address(TOKEN0), amount0, actual0);
        }

        // FOT защита для TOKEN1
        uint256 bal1Before = TOKEN1.balanceOf(address(this));
        TOKEN1.safeTransferFrom(msg.sender, address(this), amount1);
        uint256 actual1 = TOKEN1.balanceOf(address(this)) - bal1Before;
        if (actual1 != amount1) {
            emit FeeOnTransferDetected(address(TOKEN1), amount1, actual1);
            revert FeeOnTransferToken(address(TOKEN1), amount1, actual1);
        }

        uint256 supply = totalSupply();

        if (supply == 0) {
            uint256 initialLiquidity = SwapMath.sqrt(amount0 * amount1);
            if (initialLiquidity <= MINIMUM_LIQUIDITY) revert InitialLiquidityTooLow();
            liquidity = initialLiquidity - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            liquidity = SwapMath.min(
                (amount0 * supply) / reserve0,
                (amount1 * supply) / reserve1
            );
        }

        if (liquidity == 0)           revert InsufficientLiquidityMinted();
        if (liquidity < minLiquidity) revert MinLiquidity(liquidity, minLiquidity);

        _mint(msg.sender, liquidity);

        reserve0 += amount0;
        reserve1 += amount1;

        emit AddLiquidity(
            msg.sender, amount0, amount1, liquidity,
            reserve0, reserve1, totalSupply()
        );
    }

    function removeLiquidity(
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    )
        external
        nonReentrant
        notPaused
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        if (liquidity == 0)             revert ZeroAmount();

        _updateTwap();

        uint256 supply = totalSupply();
        if (supply == 0) revert NoSupply();

        amount0 = (liquidity * reserve0) / supply;
        amount1 = (liquidity * reserve1) / supply;

        if (amount0 == 0 || amount1 == 0)               revert InsufficientOutput();
        if (amount0 < minAmount0 || amount1 < minAmount1) revert MinOutput();

        _burn(msg.sender, liquidity);

        reserve0 -= amount0;
        reserve1 -= amount1;

        TOKEN0.safeTransfer(msg.sender, amount0);
        TOKEN1.safeTransfer(msg.sender, amount1);

        emit RemoveLiquidity(
            msg.sender, amount0, amount1, liquidity,
            reserve0, reserve1, totalSupply()
        );
    }

    // =========================================================================
    // Internal: TWAP
    // =========================================================================

    function _updateTwap() internal {
        uint32 ts      = uint32(block.timestamp);
        uint32 elapsed = ts - blockTimestampLast;

        if (elapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price0CumulativeLast += (reserve1 * 1e18 * uint256(elapsed)) / reserve0;
            price1CumulativeLast += (reserve0 * 1e18 * uint256(elapsed)) / reserve1;
        }

        blockTimestampLast = ts;
        _writeObservation(ts);
    }

    function _writeObservation(uint32 ts) internal {
        if (observations[observationIndex].timestamp == ts) return;

        uint16 next = (observationIndex + 1) % OBS_CARDINALITY;
        observations[next] = Observation({
            timestamp:        ts,
            price0Cumulative: price0CumulativeLast,
            price1Cumulative: price1CumulativeLast
        });
        observationIndex = next;
        if (observationCount < OBS_CARDINALITY) observationCount++;
    }

    function _currentCumulatives()
        internal view
        returns (uint32 ts, uint256 cum0, uint256 cum1)
    {
        ts   = uint32(block.timestamp);
        cum0 = price0CumulativeLast;
        cum1 = price1CumulativeLast;

        if (ts > blockTimestampLast && reserve0 > 0 && reserve1 > 0) {
            uint32 dt = ts - blockTimestampLast;
            cum0 += (reserve1 * 1e18 * uint256(dt)) / reserve0;
            cum1 += (reserve0 * 1e18 * uint256(dt)) / reserve1;
        }
    }

    function _findObservation(uint32 currentTs, uint32 interval)
        internal view
        returns (Observation memory target)
    {
        uint32 targetTs  = currentTs > interval ? currentTs - interval : 0;
        uint16 count     = observationCount;
        uint16 oldestIdx = count < OBS_CARDINALITY
            ? 0
            : (observationIndex + 1) % OBS_CARDINALITY;

        target = observations[oldestIdx];

        uint16 lo = 0;
        uint16 hi = count - 1;

        while (lo <= hi) {
            uint16 mid     = lo + (hi - lo) / 2;
            uint16 realIdx = (oldestIdx + mid) % OBS_CARDINALITY;
            Observation memory obs = observations[realIdx];

            if (obs.timestamp <= targetTs) {
                target = obs;
                if (lo == hi) break;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
    }

    // =========================================================================
    // Internal: liquidity math
    // =========================================================================

    function _calcOptimalAmounts(
        uint256 a0Desired, uint256 a1Desired,
        uint256 a0Min,     uint256 a1Min
    ) internal view returns (uint256 a0, uint256 a1) {
        if (reserve0 == 0 && reserve1 == 0) return (a0Desired, a1Desired);

        uint256 a1Optimal = (a0Desired * reserve1) / reserve0;
        if (a1Optimal <= a1Desired) {
            require(a1Optimal >= a1Min, "INSUFFICIENT_1_AMOUNT");
            return (a0Desired, a1Optimal);
        }

        uint256 a0Optimal = (a1Desired * reserve0) / reserve1;
        require(a0Optimal <= a0Desired, "AMOUNT0_EXCEEDS_DESIRED");
        require(a0Optimal >= a0Min,     "INSUFFICIENT_0_AMOUNT");
        return (a0Optimal, a1Desired);
    }
}