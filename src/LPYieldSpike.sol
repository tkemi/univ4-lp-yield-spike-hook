// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

contract LPYieldSpike is BaseHook {
    // StateLibrary is new here and we haven't seen that before
    // It's used to add helper functions to the PoolManager to read
    // storage values.
    // In this case, we use it for accessing `currentTick` values
    // from the pool manager
    using StateLibrary for IPoolManager;
    // PoolIdLibrary used to convert PoolKeys to IDs
    using PoolIdLibrary for PoolKey;
    // Used to represent Currency types and helper functions like `.isNative()`
    using CurrencyLibrary for Currency;
    // Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    using LPFeeLibrary for uint24;
    using SafeERC20 for IERC20;

    // Timestamp of the latest prize distribution
    uint256 public lastPrizeDrawTimestamp;

    // Draw prize winner every 86400 seconds (24 hours)
    uint256 public constant PRIZE_DRAW_INTERVAL = 86400;

    uint24 public constant FEE_PRECISION = 10000;

    // Initial fee of the pool
    uint24 public initialPoolFee; // 500 = 5%

    // Base pool fee, reduced to allocate portion for prize mechanism
    uint24 public reducedPoolFee;

    // Percentage of fee to be allocated for prize
    uint24 public feePercentageForPrize;

    // Accumulated prize for pool per token
    mapping(PoolId poolId => mapping(address => uint256)) public accumulatedPrize;

    error MustUseDynamicFee();

    /// @param _poolManager Address of poolManager
    /// @param _initialPoolFee Initial pool fee
    /// @param _feePercentageForPrize Fee percentage to be taken from fee to accumulate prize (e.g. 500 = 5%)
    constructor(IPoolManager _poolManager, uint24 _initialPoolFee, uint24 _feePercentageForPrize)
        BaseHook(_poolManager)
    {
        // Set initial pool fee in bps
        initialPoolFee = _initialPoolFee;
        // Calulate fee percentage in bps to be taken from fee
        feePercentageForPrize = (initialPoolFee * _feePercentageForPrize) / FEE_PRECISION;
    }

    // BaseHook functions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external override returns (bytes4) {
        poolManager.updateDynamicLPFee(key, initialPoolFee);

        return this.afterInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if there was a change in pool fee and update fee to match hook requirements
        uint24 updatedPoolFee = handlePoolFeeUpdate(key);
        // Accumulate prize for draw
        accumulatePrize(key, params);
        // Return the hook selector, zero delta (no modification to swap), and zero additional data
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, updatedPoolFee);
    }

    function handlePoolFeeUpdate(PoolKey calldata key) internal returns (uint24) {
        (,,, uint24 currentLpFee) = poolManager.getSlot0(key.toId());
        if (currentLpFee != reducedPoolFee) {
            return calculateAndSetReducedFee(currentLpFee);
        }
        return currentLpFee;
    }

    function calculateAndSetReducedFee(uint24 feeToBeReduced) internal returns (uint24) {
        // Reduce initial pool fee to later use that difference to accumulate prizes
        reducedPoolFee = feeToBeReduced - feePercentageForPrize;
        // Set reducedFee as the  poolFee
        reducedPoolFee = reducedPoolFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return reducedPoolFee;
    }

    function accumulatePrize(PoolKey calldata key, IPoolManager.SwapParams calldata params) internal {
        // Get the absolute value of the amountSpecified
        uint256 amountSpecified =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // Calculate the portion of the swap amount to be allocated to the prize pool
        uint256 amountToAccumulateToPrize = (amountSpecified * feePercentageForPrize) / FEE_PRECISION;
        // Select the fee currency based on swap direction
        Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        // Transfer the accumulated prize amount from the swapper to the hook contract
        poolManager.take(feeCurrency, address(this), amountToAccumulateToPrize);
    }
}
