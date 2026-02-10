// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "../src/SwapExecutor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    AggregatorV3Interface
} from "../src/interfaces/AggregatorV3Interface.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockChainlinkFeed is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestRound;

    function setRound(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round({answer: answer, updatedAt: updatedAt});
        if (roundId > latestRound) latestRound = roundId;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[latestRound];
        return (latestRound, r.answer, r.updatedAt, r.updatedAt, latestRound);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[_roundId];
        require(r.updatedAt != 0, "No data present");
        return (_roundId, r.answer, r.updatedAt, r.updatedAt, _roundId);
    }
}

contract SwapExecutorTest is Test {
    MockToken tokenA;
    MockToken tokenB;
    MockToken tokenC;
    MockChainlinkFeed feed;

    Pool pool;
    SwapExecutor executor;

    address user;
    address feeCollector;
    address attacker;

    function setUp() public {
        user = address(0x1234);
        feeCollector = address(0xBEEF);
        attacker = address(0xCAFE);

        tokenA = new MockToken("Token A", "A");
        tokenB = new MockToken("Token B", "B");
        tokenC = new MockToken("Token C", "C");
        feed = new MockChainlinkFeed();

        tokenA.mint(user, 1_000e18);

        pool = new Pool(address(tokenA), address(tokenB));

        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 10_000_000e18);

        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100_000e18, 10_000_000e18);

        uint256 t0 = block.timestamp + 300;
        vm.warp(t0);
        feed.setRound(1, 100e8, t0 - 300);
        feed.setRound(2, 100e8, t0 - 200);
        feed.setRound(3, 100e8, t0 - 100);
        feed.setRound(4, 100e8, t0);

        executor = new SwapExecutor(feeCollector, address(feed));

        vm.warp(block.timestamp + 1 hours);

        uint256 t1 = block.timestamp;
        feed.setRound(5, 100e8, t1 - 300);
        feed.setRound(6, 100e8, t1 - 200);
        feed.setRound(7, 100e8, t1 - 100);
        feed.setRound(8, 100e8, t1);
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

        SwapExecutor smallExecutor = new SwapExecutor(feeCollector, address(feed));

        vm.startPrank(user);
        tokenA.approve(address(smallExecutor), 1e18);

        uint256 totalOut = smallExecutor.executeAutoChunkedSwapWithOracleParams(
            smallPool,
            address(tokenA),
            1e18,
            0,
            user,
            block.timestamp + 1 hours,
            300,
            10_000,
            10_000,
            1 hours
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
        uint256 totalOut;

        vm.startPrank(user);
        tokenA.approve(address(executor), 500e18);

        totalOut = executor.executeAutoChunkedSwap(
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

        executor.executeAutoChunkedSwapWithOracleParams(
            pool,
            address(tokenA),
            amountIn,
            1,
            user,
            block.timestamp + 1 hours,
            300,
            10_000,
            10_000,
            1 hours
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

    function testExecutorBlocksSwapOnSpotDeviationAgainstChainlinkTwap() public {
        tokenA.mint(attacker, 50_000e18);

        vm.startPrank(attacker);
        tokenA.approve(address(pool), 50_000e18);
        pool.swap(address(tokenA), 50_000e18, 0, attacker, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.startPrank(user);
        tokenA.approve(address(executor), 100e18);

        vm.expectRevert(bytes("PRICE_DEVIATION_TOO_HIGH"));
        executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            100e18,
            1,
            user,
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }

    function testExecutorBlocksSwapOnOracleTwapSlippage() public {
        uint256 largeAmount = 20_000e18;
        tokenA.mint(user, largeAmount);

        vm.startPrank(user);
        tokenA.approve(address(executor), largeAmount);

        vm.expectRevert(bytes("TWAP_SLIPPAGE_TOO_HIGH"));
        executor.executeAutoChunkedSwapWithOracleParams(
            pool,
            address(tokenA),
            largeAmount,
            1,
            user,
            block.timestamp + 1 hours,
            300,
            10_000,
            50,
            1 hours
        );

        vm.stopPrank();
    }

    function testExecutorRevertsOnStaleChainlinkData() public {
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(user);
        tokenA.approve(address(executor), 100e18);

        vm.expectRevert(bytes("ORACLE_STALE"));
        executor.executeAutoChunkedSwap(
            pool,
            address(tokenA),
            100e18,
            1,
            user,
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }
}
