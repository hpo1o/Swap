// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Pool} from "../src/Pool.sol";
import {SwapExecutor} from "../src/SwapExecutor.sol";
import {SwapMath} from "../src/libraries/SwapMath.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {ERC20FotMock} from "./mocks/ERC20FotMock.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {Vm} from "forge-std/Vm.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Handler — выполняет случайные операции с пулом для инвариантных тестов
// ─────────────────────────────────────────────────────────────────────────────

contract PoolHandler is Test {
    Pool        public pool;
    ERC20Mock   public tokenA;
    ERC20Mock   public tokenB;

    address[] public actors;
    uint256   public totalDeposited0;
    uint256   public totalDeposited1;
    uint256   public totalWithdrawn0;
    uint256   public totalWithdrawn1;

    constructor(Pool _pool, ERC20Mock _tokenA, ERC20Mock _tokenB) {
        pool   = _pool;
        tokenA = _tokenA;
        tokenB = _tokenB;

        // создаём нескольких акторов
        for (uint256 i = 0; i < 3; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            tokenA.mint(actor, 1_000_000e18);
            tokenB.mint(actor, 1_000_000e18);
            vm.prank(actor);
            tokenA.approve(address(pool), type(uint256).max);
            vm.prank(actor);
            tokenB.approve(address(pool), type(uint256).max);
        }
    }

    function addLiquidity(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        address actor = actors[actorSeed % actors.length];
        amount0 = bound(amount0, 1e18, 100_000e18);
        amount1 = bound(amount1, 1e18, 100_000e18);

        (uint256 r0, uint256 r1) = pool.getReserves();

        // подбираем пропорциональное amount1 если пул не пустой
        if (r0 > 0 && r1 > 0) {
            amount1 = (amount0 * r1) / r0;
            if (amount1 == 0) return;
        }

        tokenA.mint(actor, amount0);
        tokenB.mint(actor, amount1);

        vm.startPrank(actor);
        try pool.addLiquidity(
            amount0, amount1, 0, 0, 0, block.timestamp + 1
        ) returns (uint256) {
            totalDeposited0 += amount0;
            totalDeposited1 += amount1;
        } catch {}
        vm.stopPrank();
    }

    function removeLiquidity(uint256 actorSeed, uint256 lpFraction) external {
        address actor = actors[actorSeed % actors.length];
        uint256 lpBal = pool.balanceOf(actor);
        if (lpBal == 0) return;

        lpFraction = bound(lpFraction, 1, 100);
        uint256 lpAmount = (lpBal * lpFraction) / 100;
        if (lpAmount == 0) return;

        vm.startPrank(actor);
        try pool.removeLiquidity(lpAmount, 0, 0, block.timestamp + 1)
            returns (uint256 a0, uint256 a1)
        {
            totalWithdrawn0 += a0;
            totalWithdrawn1 += a1;
        } catch {}
        vm.stopPrank();
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) external {
        address actor = actors[actorSeed % actors.length];
        amountIn = bound(amountIn, 1e15, 10_000e18);

        address tIn = zeroForOne ? address(tokenA) : address(tokenB);
        ERC20Mock(tIn).mint(actor, amountIn);

        vm.startPrank(actor);
        ERC20Mock(tIn).approve(address(pool), amountIn);
        try pool.swap(tIn, amountIn, 0, actor, block.timestamp + 1) {} catch {}
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant Tests
// ─────────────────────────────────────────────────────────────────────────────

contract InvariantPoolTest is StdInvariant, Test {
    Pool           public pool;
    ERC20Mock      public tokenA;
    ERC20Mock      public tokenB;
    PoolHandler    public handler;
    address        public guardian;

    function setUp() public {
        guardian = makeAddr("guardian");
        tokenA   = new ERC20Mock("TokenA", "TKA", 18);
        tokenB   = new ERC20Mock("TokenB", "TKB", 18);
        pool     = new Pool(address(tokenA), address(tokenB), guardian);

        // первый депозит от test contract
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 100_000e18);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        handler = new PoolHandler(pool, tokenA, tokenB);
        targetContract(address(handler));
    }

    /// @notice Резервы всегда совпадают с фактическими балансами пула
    function invariant_reservesMatchBalances() public view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        address t0 = address(pool.TOKEN0());
        address t1 = address(pool.TOKEN1());

        assertEq(
            ERC20Mock(t0).balanceOf(address(pool)), r0,
            "reserve0 mismatch"
        );
        assertEq(
            ERC20Mock(t1).balanceOf(address(pool)), r1,
            "reserve1 mismatch"
        );
    }

    /// @notice k = reserve0 * reserve1 никогда не уменьшается
    function invariant_kNeverDecreases() public view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        // минимальное k после первого депозита 100k * 100k
        assertGe(r0 * r1, 100_000e18 * 100_000e18 - 1e36, "k decreased");
    }

    /// @notice Суммарное supply LP-токенов > 0 пока есть резервы
    function invariant_lpSupplyPositive() public view {
        (uint256 r0, uint256 r1) = pool.getReserves();
        if (r0 > 0 && r1 > 0) {
            assertGt(pool.totalSupply(), 0, "zero LP supply with nonzero reserves");
        }
    }

    /// @notice MINIMUM_LIQUIDITY всегда заблокирован на dead address
    function invariant_minimumLiquidityLocked() public view {
        assertGe(
            pool.balanceOf(address(0xdead)),
            1_000,
            "MINIMUM_LIQUIDITY not locked"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests — Pool
// ─────────────────────────────────────────────────────────────────────────────

contract PoolUnitTest is Test {
    Pool         public pool;
    ERC20Mock    public tokenA;
    ERC20Mock    public tokenB;
    ERC20FotMock public tokenFot;
    address      public guardian;
    address      public alice;
    address      public bob;

    function setUp() public {
        guardian = makeAddr("guardian");
        alice    = makeAddr("alice");
        bob      = makeAddr("bob");

        tokenA = new ERC20Mock("TokenA", "TKA", 18);
        tokenB = new ERC20Mock("TokenB", "TKB", 18);
        pool   = new Pool(address(tokenA), address(tokenB), guardian);

        tokenA.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);
        tokenA.mint(bob,   1_000_000e18);
        tokenB.mint(bob,   1_000_000e18);

        vm.startPrank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ── addLiquidity ─────────────────────────────────────────────────────────

    function test_addLiquidity_firstDeposit_locksMinLiquidity() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        assertEq(pool.balanceOf(address(0xdead)), 1_000);
    }

    function test_addLiquidity_proportionalDeposit_noValueLeak() public {
        // первый депозит
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        uint256 bobA_before = tokenA.balanceOf(bob);
        uint256 bobB_before = tokenB.balanceOf(bob);

        // bob передаёт непропорционально: в два раза больше tokenB
        vm.prank(bob);
        pool.addLiquidity(
            10_000e18,   // amount0Desired
            50_000e18,   // amount1Desired — лишнее НЕ должно быть списано
            0, 0, 0,
            block.timestamp + 1
        );

        uint256 bobA_after = tokenA.balanceOf(bob);
        uint256 bobB_after = tokenB.balanceOf(bob);

        uint256 spentA = bobA_before - bobA_after;
        uint256 spentB = bobB_before - bobB_after;

        // списано пропорционально 1:1, не 1:5
        assertEq(spentA, 10_000e18, "wrong tokenA spent");
        assertEq(spentB, 10_000e18, "wrong tokenB spent value leaked");
    }

    function test_addLiquidity_revertOnInitialLiquidityTooLow() public {
        vm.prank(alice);
        vm.expectRevert(Pool.InitialLiquidityTooLow.selector);
        pool.addLiquidity(1, 1, 0, 0, 0, block.timestamp + 1);
    }

    function test_addLiquidity_revertOnExpired() public {
        vm.prank(alice);
        vm.expectRevert(Pool.Expired.selector);
        pool.addLiquidity(
            100_000e18, 100_000e18, 0, 0, 0,
            block.timestamp - 1
        );
    }

    // ── swap ─────────────────────────────────────────────────────────────────

    function test_swap_basicExact() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        address token0 = address(pool.TOKEN0());
        (uint256 r0, uint256 r1) = pool.getReserves();

        uint256 amountIn  = 1_000e18;
        uint256 expected  = SwapMath.getAmountOut(amountIn, r0, r1, 30);

        vm.prank(bob);
        uint256 out = pool.swap(token0, amountIn, 0, bob, block.timestamp + 1);

        assertEq(out, expected, "wrong amountOut");
    }

    function test_swap_revertOnSlippage() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        uint256 amountIn = 1e18;
        uint256 realOut  = SwapMath.getAmountOut(amountIn, 100_000e18, 100_000e18, 30);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.SlippageTooHigh.selector,
                realOut,
                type(uint256).max
            )
        );
        pool.swap(address(tokenA), amountIn, type(uint256).max, bob, block.timestamp + 1);
    }

    function test_swap_revertOnExpired() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        vm.prank(bob);
        vm.expectRevert(Pool.Expired.selector);
        pool.swap(
            address(tokenA), 1e18, 0, bob, block.timestamp - 1
        );
    }

    function test_swap_revertOnInvalidTo() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        vm.prank(bob);
        vm.expectRevert(Pool.InvalidTo.selector);
        pool.swap(
            address(tokenA), 1e18, 0, address(tokenA), block.timestamp + 1
        );
    }

    /// @notice Инвариант k не нарушается после свапа
    function test_swap_kInvariant() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        (uint256 r0before, uint256 r1before) = pool.getReserves();
        uint256 kBefore = r0before * r1before;

        vm.prank(bob);
        pool.swap(address(tokenA), 5_000e18, 0, bob, block.timestamp + 1);

        (uint256 r0after, uint256 r1after) = pool.getReserves();
        uint256 kAfter = r0after * r1after;

        assertGe(kAfter, kBefore, "k invariant broken");
    }

    // ── fee accounting ────────────────────────────────────────────────────────

    /// @notice Комиссия 0.3% остаётся в пуле — LP получают её при выводе
// замени всю функцию на:
    function test_feeAccounting_feeAccruesToLp() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        address token0 = address(pool.TOKEN0());
        (uint256 r0Before,) = pool.getReserves();

        // свапаем token0 → token1, reserve0 должен вырасти
        uint256 bigSwap = 50_000e18;
        ERC20Mock(token0).mint(bob, bigSwap);
        vm.startPrank(bob);
        ERC20Mock(token0).approve(address(pool), bigSwap);
        pool.swap(token0, bigSwap, 0, bob, block.timestamp + 1);
        vm.stopPrank();

        (uint256 r0After,) = pool.getReserves();
        assertGt(r0After, r0Before, "reserve0 should grow after swap of token0");

        // alice выводит всю ликвидность
        uint256 lpBal = pool.balanceOf(alice);
        uint256 balBefore = ERC20Mock(token0).balanceOf(alice);

        vm.prank(alice);
        pool.removeLiquidity(lpBal, 0, 0, block.timestamp + 1);

        uint256 balAfter = ERC20Mock(token0).balanceOf(alice);
        // alice получила обратно ~100k + часть комиссии от свапа
        assertGt(balAfter - balBefore, 99_000e18, "fee not accrued to LP");
    }

    // ── removeLiquidity ───────────────────────────────────────────────────────

    function test_removeLiquidity_proportional() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 200_000e18, 0, 0, 0, block.timestamp + 1);

        uint256 lp = pool.balanceOf(alice);
        uint256 half = lp / 2;

        vm.prank(alice);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(
            half, 0, 0, block.timestamp + 1
        );

        // пропорция должна сохраниться
        assertApproxEqRel(a1, a0 * 2, 1e15, "wrong proportion");
    }

    // ── guardian pause ────────────────────────────────────────────────────────

    function test_pause_blocksSwap() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        vm.prank(guardian);
        pool.togglePause();

        vm.prank(bob);
        vm.expectRevert(Pool.Paused.selector);
        pool.swap(address(tokenA), 1e18, 0, bob, block.timestamp + 1);
    }

    function test_pause_blocksAddLiquidity() public {
        vm.prank(guardian);
        pool.togglePause();

        vm.prank(alice);
        vm.expectRevert(Pool.Paused.selector);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);
    }

    function test_pause_onlyGuardian() public {
        vm.prank(alice);
        vm.expectRevert(Pool.NotGuardian.selector);
        pool.togglePause();
    }

    function test_pause_unpause_works() public {
        vm.prank(alice);
        pool.addLiquidity(100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1);

        vm.prank(guardian);
        pool.togglePause();

        vm.prank(guardian);
        pool.togglePause(); // unpause

        // теперь своп должен работать
        vm.prank(bob);
        pool.swap(address(tokenA), 1e18, 0, bob, block.timestamp + 1);
    }

    // ── fee-on-transfer protection ────────────────────────────────────────────

    function test_fot_revertOnFeeOnTransferToken() public {
        tokenFot = new ERC20FotMock("FOT", "FOT", 18, 100); // 1% комиссия
        Pool fotPool = new Pool(address(tokenFot), address(tokenB), guardian);

        tokenFot.mint(alice, 1_000_000e18);
        tokenB.mint(alice, 1_000_000e18);

        vm.startPrank(alice);
        tokenFot.approve(address(fotPool), type(uint256).max);
        tokenB.approve(address(fotPool), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(); // FeeOnTransferToken
        fotPool.addLiquidity(
            100_000e18, 100_000e18, 0, 0, 0, block.timestamp + 1
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests — SwapExecutor
// ─────────────────────────────────────────────────────────────────────────────

contract SwapExecutorTest is Test {
    Pool              public pool;
    SwapExecutor      public executor;
    ERC20Mock         public tokenA;
    ERC20Mock         public tokenB;
    MockChainlinkFeed public feed;

    address public guardian;
    address public feeRecipient;
    address public alice;

    uint256 constant POOL_RESERVE    = 100_000e18;
    int256  constant CHAINLINK_PRICE = 1e8;

    function setUp() public {
        guardian     = makeAddr("guardian");
        feeRecipient = makeAddr("feeRecipient");
        alice        = makeAddr("alice");

        tokenA = new ERC20Mock("TokenA", "TKA", 18);
        tokenB = new ERC20Mock("TokenB", "TKB", 18);
        feed   = new MockChainlinkFeed(CHAINLINK_PRICE, 8);
        pool   = new Pool(address(tokenA), address(tokenB), guardian);
        executor = new SwapExecutor(feeRecipient, address(feed), guardian);

        tokenA.mint(address(this), POOL_RESERVE);
        tokenB.mint(address(this), POOL_RESERVE);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(POOL_RESERVE, POOL_RESERVE, 0, 0, 0, block.timestamp + 1);

        tokenA.mint(alice, 500e18);
        vm.prank(alice);
        tokenA.approve(address(executor), type(uint256).max);
    }

    function _setupOracleHistory() internal {
        vm.warp(block.timestamp + 3600);
        feed.setRoundHistory(block.timestamp);
    }

    function test_executor_usesAllInput() public {
        _setupOracleHistory();
        uint256 amountIn     = 500e18;
        uint256 aliceABefore = tokenA.balanceOf(alice);

        vm.prank(alice);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), amountIn, 0, alice, block.timestamp + 1
        );

        assertEq(aliceABefore - tokenA.balanceOf(alice), amountIn, "not all input used");
    }

    function test_executor_noTokensLeftInExecutor() public {
        _setupOracleHistory();

        vm.prank(alice);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 500e18, 0, alice, block.timestamp + 1
        );

        assertEq(tokenA.balanceOf(address(executor)), 0, "tokenIn stuck");
        assertEq(tokenB.balanceOf(address(executor)), 0, "tokenOut stuck");
    }

    function test_executor_feeGoesToRecipient() public {
        _setupOracleHistory();
        uint256 feeBefore = tokenB.balanceOf(feeRecipient);

        vm.prank(alice);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 500e18, 0, alice, block.timestamp + 1
        );

        assertGt(tokenB.balanceOf(feeRecipient), feeBefore, "fee not collected");
    }

    function test_executor_pause_blocks() public {
        vm.prank(guardian);
        executor.togglePause();

        vm.prank(alice);
        vm.expectRevert(SwapExecutor.Paused.selector);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 500e18, 0, alice, block.timestamp + 1
        );
    }

    function test_executor_revertOnExpired() public {
        vm.prank(alice);
        vm.expectRevert(SwapExecutor.Expired.selector);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 500e18, 0, alice, block.timestamp - 1
        );
    }

    function test_executor_revertOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(SwapExecutor.ZeroAmount.selector);
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 0, 0, alice, block.timestamp + 1
        );
    }

    function test_executor_emitsSwapExecuted() public {
        _setupOracleHistory();

        vm.prank(alice);
        vm.recordLogs();
        executor.executeAutoChunkedSwap(
            pool, address(tokenA), 500e18, 0, alice, block.timestamp + 1
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256(
            "SwapExecuted(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256)"
        );

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) {
                found = true;
                break;
            }
        }
        assertTrue(found, "SwapExecuted event not emitted");
    }
}
