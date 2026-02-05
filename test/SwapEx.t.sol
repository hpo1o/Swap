// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/SwapExecutor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SwapExecutorTest is Test {
    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;
    Pool pool;
    SwapExecutor executor;

    address user;
    address feeCollector;

    function setUp() public {
        user = address(0x1234);
        feeCollector = address(0xBEEF);

        tokenA = new MockToken("Token A", "A");
        tokenB = new MockToken("Token B", "B");
        tokenC = new MockToken("Token C", "C");

        tokenA.mint(user, 1_000e18);

        pool = new Pool(address(tokenA), address(tokenB));

        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 10_000_000e18);

        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100_000e18, 10_000_000e18);

        executor = new SwapExecutor(feeCollector);
    }

    function testAutoChunkedSwap() public {
        vm.startPrank(user);
        tokenA.approve(address(executor), 500e18);

        uint256 totalOut = executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            500e18,
            490e18,
            user,
            block.timestamp + 1 hours
        );

        assertGt(totalOut, 0, "Output > 0");
        vm.stopPrank();
    }

    function testSmallPoolOneChunk() public {
        Pool smallPool = new Pool(address(tokenA), address(tokenB));

        tokenA.mint(address(this), 10_000e18);
        tokenB.mint(address(this), 10_000e18);

        tokenA.approve(address(smallPool), type(uint256).max);
        tokenB.approve(address(smallPool), type(uint256).max);
        smallPool.addLiquidity(5e18, 5e18);

        SwapExecutor smallExecutor = new SwapExecutor(feeCollector);

        vm.startPrank(user);
        tokenA.approve(address(smallExecutor), 1e18);

        uint256 totalOut = smallExecutor.executeAutoChunkedSwap(
            smallPool,
            address(tokenA),
            1e18,
            0,
            user,
            block.timestamp + 1 hours
        );

        assertGt(totalOut, 0, "Output > 0");
        vm.stopPrank();
    }

    function testRevertWhenBelowMinTotalOut() public {
        vm.startPrank(user);
        tokenA.approve(address(executor), 500e18);

        vm.expectRevert(bytes("TOTAL_SLIPPAGE"));
        executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            500e18,
            1_000_000e18,
            user,
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }

    function testPoolSwapRevertsForInvalidTokenIn() public {
        tokenC.mint(user, 1e18);

        vm.startPrank(user);
        tokenC.approve(address(pool), 1e18);

        vm.expectRevert(bytes("INVALID_TOKEN_IN"));
        pool.swap(address(tokenC), 1e18, 0, user, block.timestamp + 1 hours);

        vm.stopPrank();
    }

    function testExecutorSendsFeeToFeeCollector() public {
        vm.startPrank(user);
        tokenA.approve(address(executor), 500e18);

        uint256 totalOut = executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            500e18,
            1,
            user,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        uint256 expectedFee = (totalOut * executor.EXECUTOR_FEE_BPS()) / 10_000;
        assertEq(tokenB.balanceOf(feeCollector), expectedFee, "fee recipient must receive fee");
    }

    function testExecutorSpendsEntireInputWithRemainder() public {
        uint256 amountIn = 33_333e18;

        tokenA.mint(user, amountIn);

        vm.startPrank(user);
        tokenA.approve(address(executor), amountIn);

        executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            amountIn,
            1,
            user,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        assertEq(
            tokenA.balanceOf(address(executor)),
            0,
            "executor should not keep input token remainder"
        );
    }

    function testExecutorRevertsOnExpiredDeadline() public {
        vm.startPrank(user);
        tokenA.approve(address(executor), 1e18);

        vm.expectRevert(bytes("EXPIRED"));
        executor.executeAutoChunkedSwap(pool, address(tokenA), 1e18, 0, user, block.timestamp - 1);

        vm.stopPrank();
    }
}
