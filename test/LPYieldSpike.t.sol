// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {console} from "forge-std/console.sol";
import {LPYieldSpike} from "../src/LPYieldSpike.sol";

contract TestLPYieldHook is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    uint24 initialPoolFee = 500;
    uint24 feePercentageForPrize = 500;

    LPYieldSpike hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        deployMintAndApprove2Currencies();

        // Deploy our hook
        address hookAddress =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));

        vm.txGasPrice(10 gwei);

        deployCodeTo("LPYieldSpike.sol", abi.encode(manager, initialPoolFee, feePercentageForPrize), hookAddress);
        hook = LPYieldSpike(hookAddress);

        // Initialize new pool
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Add liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_initialFee() public view {
        (,,, uint24 fee) = manager.getSlot0(key.toId());
        assertEq(fee, initialPoolFee);
    }

    // Swap with an updated fee and verify the output
    function test_updatedFeeBeforeSwap() public {
        // uint24 newPoolFee = 300;
        // // update the LP fee, and verify the fee is updated
        // hook.forceUpdateLPFee(key, newPoolFee);
        // (,,, uint24 fee) = manager.getSlot0(key.toId());
        // assertEq(fee, newPoolFee);

        // uint256 currency1Before = currency1.balanceOfSelf();

        // // Perform a test swap //
        // bool zeroForOne = true;
        // int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        // BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // // ------------------- //

        // uint256 currency1After = currency1.balanceOfSelf();

        // // the fee is 0.20% so we should receive approximately 0.9980 of currency1
        // assertApproxEqAbs(currency1After - currency1Before, 0.998e18, 0.0001 ether);
    }

    function test_a() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        // uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);
    }
}
