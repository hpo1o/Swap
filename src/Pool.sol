// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapMath} from "./libraries/SwapMath.sol";


contract Pool is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Observation {
        uint32  timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    uint256 public  constant FEE_BPS            = 30;
    uint256 public  constant BPS_DENOM          = 10_000;
    uint256 private constant MINIMUM_LIQUIDITY  = 1_000;
    address private constant DEAD_ADDRESS       = address(0xdead);
    uint16  public  constant OBS_CARDINALITY    = 720;

    // solhint-disable var-name-mixedcase
    IERC20 public immutable TOKEN0;
    IERC20 public immutable TOKEN1;

    uint256 private reserve0;
    uint256 private reserve1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32  public blockTimestampLast;

    Observation[720] public observations;
    uint16 public observationIndex;
    uint16 public observationCount;


    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );

    event AddLiquidity(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    event RemoveLiquidity(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    constructor(address _token0, address _token1) ERC20("LP TOKEN", "LP") {
        require(_token0 != address(0) && _token1 != address(0), "ZERO_ADDRESS");
        require(_token0 != _token1, "IDENTICAL_ADDRESSES");

        (TOKEN0, TOKEN1) = _token0 < _token1
            ? (IERC20(_token0), IERC20(_token1))
            : (IERC20(_token1), IERC20(_token0));

        uint32 ts = uint32(block.timestamp);
        blockTimestampLast = ts;
        observations[0] = Observation({
            timestamp:        ts,
            price0Cumulative: 0,
            price1Cumulative: 0
        });
        observationCount = 1;
    }

    function getReserves() external view returns (uint256 r0, uint256 r1) {
        return (reserve0, reserve1);
    }

    function getSpotPrice(address tokenIn) external view returns (uint256 priceX18) {
        require(
            tokenIn == address(TOKEN0) || tokenIn == address(TOKEN1),
            "INVALID_TOKEN_IN"
        );
        require(reserve0 > 0 && reserve1 > 0, "NO_LIQUIDITY");

        priceX18 = tokenIn == address(TOKEN0)
            ? (reserve1 * 1e18) / reserve0
            : (reserve0 * 1e18) / reserve1;
    }

    function consult(address tokenIn, uint32 interval)
        external
        view
        returns (uint256 priceX18)
    {
        require(interval >= 300, "INTERVAL_TOO_SHORT");
        require(
            tokenIn == address(TOKEN0) || tokenIn == address(TOKEN1),
            "INVALID_TOKEN_IN"
        );

        (uint32 currentTs, uint256 cum0, uint256 cum1) = _currentCumulatives();

        Observation memory targetObs = _findObservation(currentTs, interval);

        uint32 elapsed = currentTs - targetObs.timestamp;
        require(elapsed > 0, "NO_TIME_ELAPSED");

        priceX18 = tokenIn == address(TOKEN0)
            ? (cum0 - targetObs.price0Cumulative) / elapsed
            : (cum1 - targetObs.price1Cumulative) / elapsed;
    }

    function getTwap() external view returns (uint256) {
        return this.consult(address(TOKEN0), 1_800);
    }

    function tokenOut(address tokenIn) public view returns (IERC20) {
        require(
            tokenIn == address(TOKEN0) || tokenIn == address(TOKEN1),
            "INVALID_TOKEN_IN"
        );
        return tokenIn == address(TOKEN0) ? TOKEN1 : TOKEN0;
    }

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
        require(block.timestamp <= deadline,                              "EXPIRED");
        require(tokenIn == address(TOKEN0) || tokenIn == address(TOKEN1),"INVALID_TOKEN_IN");
        require(amountIn > 0,                                             "ZERO_AMOUNT");
        require(to != address(0),                                         "ZERO_TO_ADDRESS");
        require(to != address(TOKEN0) && to != address(TOKEN1),           "INVALID_TO");

        _updateTwap();

        bool zeroForOne = tokenIn == address(TOKEN0);
        (uint256 reserveIn, uint256 reserveOut) =
            zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = SwapMath.getAmountOut(amountIn, reserveIn, reserveOut, FEE_BPS);

        require(amountOut >= minAmountOut, "SLIPPAGE_TOO_HIGH");
        require(amountOut > 0,            "ZERO_OUTPUT");
        require(amountOut < reserveOut,   "INSUFFICIENT_LIQUIDITY");

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
        returns (uint256 liquidity)
    {
        require(block.timestamp <= deadline,                "EXPIRED");
        require(amount0Desired > 0 && amount1Desired > 0,  "ZERO_AMOUNT");

        _updateTwap();

        (uint256 amount0, uint256 amount1) = _calcOptimalAmounts(
            amount0Desired, amount1Desired, amount0Min, amount1Min
        );

        TOKEN0.safeTransferFrom(msg.sender, address(this), amount0);
        TOKEN1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 supply = totalSupply();

        if (supply == 0) {
            uint256 initialLiquidity = SwapMath.sqrt(amount0 * amount1);
            require(initialLiquidity > MINIMUM_LIQUIDITY, "INITIAL_LIQUIDITY_TOO_LOW");
            liquidity = initialLiquidity - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            liquidity = SwapMath.min(
                (amount0 * supply) / reserve0,
                (amount1 * supply) / reserve1
            );
        }

        require(liquidity > 0,            "INSUFFICIENT_LIQUIDITY_MINTED");
        require(liquidity >= minLiquidity, "MIN_LIQUIDITY");

        _mint(msg.sender, liquidity);

        reserve0 += amount0;
        reserve1 += amount1;

        emit AddLiquidity(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Удаляет ликвидность из пула
    function removeLiquidity(
        uint256 liquidity,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(block.timestamp <= deadline, "EXPIRED");
        require(liquidity > 0,              "ZERO_LIQUIDITY");

        _updateTwap();

        uint256 supply = totalSupply();
        require(supply > 0, "NO_SUPPLY");

        amount0 = (liquidity * reserve0) / supply;
        amount1 = (liquidity * reserve1) / supply;

        require(amount0 > 0 && amount1 > 0,                       "INSUFFICIENT_OUTPUT");
        require(amount0 >= minAmount0 && amount1 >= minAmount1,    "MIN_OUTPUT");

        _burn(msg.sender, liquidity);

        reserve0 -= amount0;
        reserve1 -= amount1;

        TOKEN0.safeTransfer(msg.sender, amount0);
        TOKEN1.safeTransfer(msg.sender, amount1);

        emit RemoveLiquidity(msg.sender, amount0, amount1, liquidity);
    }

    /// @dev Обновляет кумулятивные цены.
    ///      Вызывается ДО изменения резервов — фиксирует цену начала блока.
    ///      (fix: getTWAP → _updateTwap, mixedCase)
    function _updateTwap() internal {
        uint32 ts      = uint32(block.timestamp);
        uint32 elapsed = ts - blockTimestampLast;

        if (elapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price0CumulativeLast += (reserve1 * 1e18 * elapsed) / reserve0;
            price1CumulativeLast += (reserve0 * 1e18 * elapsed) / reserve1;
        }

        blockTimestampLast = ts;
        _writeObservation(ts);
    }

    /// @dev Записывает наблюдение в кольцевой буфер.
    ///      Если в этом блоке уже есть запись — не перезаписываем.
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

    /// @dev Текущие кумулятивы с учётом времени с последнего обновления.
    ///      fix: divide-before-multiply — умножаем ВСЁ до деления
    function _currentCumulatives()
        internal
        view
        returns (uint32 ts, uint256 cum0, uint256 cum1)
    {
        ts   = uint32(block.timestamp);
        cum0 = price0CumulativeLast;
        cum1 = price1CumulativeLast;

        if (ts > blockTimestampLast && reserve0 > 0 && reserve1 > 0) {
            uint32 dt = ts - blockTimestampLast;
            // fix: divide-before-multiply
            cum0 += (reserve1 * 1e18 * uint256(dt)) / reserve0;
            cum1 += (reserve0 * 1e18 * uint256(dt)) / reserve1;
        }
    }

    function _findObservation(uint32 currentTs, uint32 interval)
        internal
        view
        returns (Observation memory target)
    {
        uint32 targetTs  = currentTs > interval ? currentTs - interval : 0;
        uint16 count     = observationCount;
        uint16 oldestIdx = count < OBS_CARDINALITY
            ? 0
            : (observationIndex + 1) % OBS_CARDINALITY;

        target = observations[oldestIdx]; // fallback — самое раннее

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

    /// @dev Пропорциональный расчёт суммы депозита.
    ///      Принимаем максимально возможное пропорциональное количество,
    ///      не превышающее Desired и не ниже Min.
    function _calcOptimalAmounts(
        uint256 a0Desired,
        uint256 a1Desired,
        uint256 a0Min,
        uint256 a1Min
    )
        internal
        view
        returns (uint256 a0, uint256 a1)
    {
        if (reserve0 == 0 && reserve1 == 0) {
            return (a0Desired, a1Desired);
        }

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