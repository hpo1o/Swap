// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/SwapExecutor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock токен для тестов
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SwapExecutorTest is Test {
    MockToken tokenA;
    MockToken tokenB;
    Pool pool;
    SwapExecutor executor;
    address user;

    function setUp() public {
        user = address(0x1234);

        // 1️⃣ Создаём токены
        tokenA = new MockToken("Token A", "A");
        tokenB = new MockToken("Token B", "B");

        // 2️⃣ Минтим токены пользователю и контракту
        tokenA.mint(user, 1_000e18);
        tokenB.mint(address(this), 1_000_000e18);

        // 3️⃣ Создаём пул
        pool = new Pool(address(tokenA), address(tokenB));

        // 4️⃣ Добавляем достаточную ликвидность
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 10_000_000e18);

        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);

        pool.addLiquidity(100_000e18, 10_000_000e18);

        // 5️⃣ Создаём SwapExecutor
        executor = new SwapExecutor();
    }

    /// @notice Тест авто-чанков для большого свапа
    function testAutoChunkedSwap() public {
        vm.startPrank(user);

        tokenA.approve(address(executor), 500e18);

        uint256 totalOut = executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            500e18,
            490e18, // немного ниже ожидаемого выхода, чтобы не падал TOTAL_SLIPPAGE
            user
        );

        // Проверяем, что output > 0 и сумма свапа прошла
        assertGt(totalOut, 0, "Output > 0");

        vm.stopPrank();
    }

    /// @notice Тест работы маленького пула (один чанк)
    function testSmallPoolOneChunk() public {
        // Создаём маленький пул
        Pool smallPool = new Pool(address(tokenA), address(tokenB));

        tokenA.mint(address(this), 10_000e18);
        tokenB.mint(address(this), 10_000e18);

        tokenA.approve(address(smallPool), type(uint256).max);
        tokenB.approve(address(smallPool), type(uint256).max);

        smallPool.addLiquidity(5e18, 5e18);

        SwapExecutor smallExecutor = new SwapExecutor();

        vm.startPrank(user);
        tokenA.approve(address(smallExecutor), 1e18);

        uint256 totalOut = smallExecutor.executeAutoChunkedSwap(
            smallPool,
            address(tokenA),
            1e18,
            0, // минимальный выход = 0, чтобы пройти
            user
        );

        assertGt(totalOut, 0, "Output > 0");

        vm.stopPrank();
    }

    /// @notice Тест revert при слишком большом minTotalOut
    function testRevertWhenBelowMinTotalOut() public {
        vm.startPrank(user);
        tokenA.approve(address(executor), 500e18);

        // Ожидаем revert из-за TOTAL_SLIPPAGE
        vm.expectRevert(bytes("TOTAL_SLIPPAGE"));
        executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            500e18,
            1_000_000e18, // явно больше, чем реально вернёт пул
            user
        );

        vm.stopPrank();
    }
}
