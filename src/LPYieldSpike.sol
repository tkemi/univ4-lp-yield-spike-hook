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
    uint256 public constant prizeDrawInterval = 86400;

    // Initial fee of the pool
    uint24 public initialPoolFee; // 500 = 5%
    
    // Base pool fee, reduced to allocate portion for prize mechanism
    uint24 public reducedPoolFee; 

    // Percentage of fee to be allocated for prize
    uint24 public feePercentageForPrize;

    // Accumulated prize for pool per token
    mapping(PoolId poolId => mapping(address => uint256)) public accumulatedPrize;

    error MustUseDynamicFee();

    /// @param _manager Address of poolManager
    /// @param _initialPoolFee Initial pool fee
    /// @param _feePercentageForPrize Fee percentage to be taken from fee to accumulate prize (e.g. 500 = 5%)
    constructor(IPoolManager _manager, uint24 _initialPoolFee, uint24 _feePercentageForPrize) BaseHook(_manager) {
        // Set initial pool fee in bps
        initialPoolFee = _initialPoolFee;
        // Calulate fee percentage in bps to be taken from fee
        feePercentageForPrize = (initialPoolFee * _feePercentageForPrize) / 10000;
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

    function afterInitialize(address, PoolKey calldata , uint160, int24) external override returns (bytes4) {
        calculateAndSetReducedFee(initialPoolFee);

        return this.afterInitialize.selector;
    }

    // function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
    //     external
    //     override
    //     onlyPoolManager
    //     returns (bytes4, BeforeSwapDelta, uint24)
    // {
    //     // Decide if we want to take a part from whole fees(e.g. protocolFee + lpFee) or just lpFee,
    //     // I think that it should be taken from the whole fees because this incentivizes lps and
    //     // protocol also benefit from it by getting more lps with this kind of incentive

    //     // Calculate the amount being taken from swap to add to prize
    //     int256 amountToAccumulateToPrize = (params.amountSpecified * int256(uint256(feePercentageForPrize))) / 10000;
    //     int256 absAmountToAccumulate = amountToAccumulateToPrize > 0 ? amountToAccumulateToPrize : -amountToAccumulateToPrize;

    //     // Determine the specified currency. If amountSpecified < 0, the swap is exact-in
    //     // so the feeCurrency should be the token the swapper is selling.
    //     // If amountSpecified > 0, the swap is exact-out and it's the bought token.
    //     bool exactOut = params.amountSpecified > 0;
    //     address feeCurrency = exactOut != params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

    //     // Update accumulated fees of pool per token
    //     accumulatedPrize[key.toId()][feeCurrency] += uint256(absAmountToAccumulate);
    //     // Depending on direction of swap, we select the proper input token
    //     // and request a transfer of those tokens to the hook contract
    //     IERC20(feeCurrency).safeTransferFrom(msg.sender, address(this), uint256(absAmountToAccumulate));

    //     return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    // }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Check if pool lp has changed and update new values to match hook requirements
        (, , ,uint24 currentLpFee ) = poolManager.getSlot0(key.toId());
        uint24 newPoolFee;
        if (currentLpFee != reducedPoolFee) {
            newPoolFee = calculateAndSetReducedFee(currentLpFee);
        }
         // Calculate the portion of the swap amount to be allocated to the prize pool
        // Using feePercentageForPrize (e.g., 500 = 5%) and dividing by 10000 for precision
        int256 amountToAccumulateToPrize = (params.amountSpecified * int256(uint256(feePercentageForPrize))) / 10000;

        // Get the absolute value of the amount to accumulate to handle both positive and negative swap amounts
        int256 absAmountToAccumulate =
            amountToAccumulateToPrize > 0 ? amountToAccumulateToPrize : -amountToAccumulateToPrize;

        // Determine if the swap is exact-out (user specifies output amount)
        // This affects how we determine which token is used for fees
        bool exactOut = params.amountSpecified > 0;

        // Select the fee currency based on swap direction:
        // - If not exact-out and zeroForOne, use currency1
        // - If exact-out and not zeroForOne, use currency0
        // This ensures we always take fees in the correct token
        address feeCurrency =
            exactOut != params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        // Accumulate the prize amount for this specific pool and currency
        accumulatedPrize[key.toId()][feeCurrency] += uint256(absAmountToAccumulate);

        // Transfer the accumulated prize amount from the swapper to the hook contract
        // This ensures the prize pool receives the allocated fees immediately
        IERC20(feeCurrency).safeTransferFrom(msg.sender, address(this), uint256(absAmountToAccumulate));

        // Return the hook selector, zero delta (no modification to swap), and zero additional data
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, newPoolFee);
    }

    function calculateAndSetReducedFee(uint24 feeToBeReduced) internal returns(uint24) {
        // Reduce initial pool fee to later use that difference to accumulate prizes
        reducedPoolFee = feeToBeReduced - feePercentageForPrize;
        // Set reducedFee as the  poolFee
        reducedPoolFee = reducedPoolFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return reducedPoolFee;
    }

    // Add a setter for bps taken from the fee
    // Add a setter to update pool fee, this can be done in one setter
    // Maybe not because it then needs to be ownable
}
