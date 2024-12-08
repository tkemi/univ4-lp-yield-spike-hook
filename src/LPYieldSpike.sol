// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract LPYieldSpike is BaseHook, VRFV2PlusWrapperConsumerBase {
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

    struct LPPositionInfo {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        uint256 token0Amount;
    }

    // Draw prize winner every 86400 seconds (24 hours)
    uint256 public constant PRIZE_DRAW_INTERVAL = 86400;
    // Precision used to calculate fee
    uint24 public constant FEE_PRECISION = 10000;
    // Gas limit for VRF callback
    uint32 public constant VRF_CALLBACK_GAS_LIMIT = 500_000;

    uint256 public constant VALUE_PER_ENTRY = 10 ** 16;

    // Minimum number of confirmation for Chainlink VRF request
    uint16 public constant minimumConfirmations = 3;

    // Keep track of link token
    uint256 public linkTokenBalance;

    // Initial fee of the pool
    uint24 public initialPoolFee; // 500 = 5%

    // Base pool fee, reduced to allocate portion for prize mechanism
    uint24 public reducedPoolFee;

    // Percentage of fee to be allocated for prize
    uint24 public feePercentageForPrize;

    // Track liquidity provider positions for pool
    mapping(PoolId => mapping(address => LPPositionInfo[] lpPositionInfo)) public lpPositionsInfo;

    mapping(PoolId => address[] lpProvider) public lpProviders;

    mapping(PoolId => uint256 numberOfPosition) public numberOfPositions;

    // Track token0 amount provided by liquidity provider for pool
    mapping(PoolId => mapping(address => uint256 token0Amount)) public token0Amounts;

    // Track last prize draw timestamp per pool
    mapping(PoolId poolId => uint256 prizeDrawTimestamp) public lastPrizeDrawTimestamp;

    // Tracks Chinlink VRF fullfilment status per pool.
    mapping(uint256 chainlinkVRFRequestID => PoolKey poolkey) internal requests;

    // Accumulated prize for pool per token
    mapping(PoolId poolId => mapping(Currency => uint256)) public accumulatedPrize;


    mapping(uint256 currentEntryIndex => address lpProvider) public entryIndexToProvider;

    /**
     * @dev Emitted when $LINK is deposited to the contract.
     * @param amount is amount of $LINK deposited.
     */
    event Deposit(address indexed authorizedFunder, uint256 amount);

    error MustUseDynamicFee();
    error InsufficientBalance();
    error InvalidChainlinkVRFRequestID();

    /// @param _poolManager Address of poolManager
    /// @param _initialPoolFee Initial pool fee
    /// @param _feePercentageForPrize Fee percentage to be taken from fee to accumulate prize (e.g. 500 = 5%)
    constructor(
        IPoolManager _poolManager,
        address _vrfV2PlusWrapper,
        uint24 _initialPoolFee,
        uint24 _feePercentageForPrize
    ) BaseHook(_poolManager) VRFV2PlusWrapperConsumerBase(_vrfV2PlusWrapper) {
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
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
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

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Calculate the square root prices for the current position
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);
        uint256 token0Amount = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtPriceAX96, sqrtPriceBX96, uint128(uint256(params.liquidityDelta))
        );

        lpPositionsInfo[poolId][sender].push(
            LPPositionInfo({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta,
                token0Amount: token0Amount
            })
        );
        lpProviders[poolId].push(sender);
        numberOfPositions[poolId]++;

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Get current positions for this sender in this pool
        LPPositionInfo[] storage currentPositions = lpPositionsInfo[poolId][sender];

        // Find and update the matching position
        for (uint256 i = 0; i < currentPositions.length; i++) {
            // Check if this position matches the removed liquidity's tick range
            if (currentPositions[i].tickLower == params.tickLower && currentPositions[i].tickUpper == params.tickUpper)
            {
                // Update the liquidity delta
                // params.liquidityDelta will be negative when removing liquidity
                currentPositions[i].liquidityDelta += params.liquidityDelta;

                // If liquidity becomes zero, consider removing the position entirely
                if (currentPositions[i].liquidityDelta == 0) {
                    // Remove this position by replacing it with the last position and then pop
                    currentPositions[i] = currentPositions[currentPositions.length - 1];
                    currentPositions.pop();

                    numberOfPositions[poolId]--;

                    // Check if this sender has no more positions in this pool
                    if (currentPositions.length == 0) {
                        // Remove the LP provider from the lpProviders array for this pool
                        address[] storage providers = lpProviders[poolId];
                        for (uint256 j = 0; j < providers.length; j++) {
                            if (providers[j] == sender) {
                                // Replace with last element and pop
                                providers[j] = providers[providers.length - 1];
                                providers.pop();
                                break;
                            }
                        }
                    }

                    break;
                } else {
                    // Recalculate token0 amount for the updated position
                    uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
                    uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);
                    currentPositions[i].token0Amount = LiquidityAmounts.getAmount0ForLiquidity(
                        sqrtPriceAX96, sqrtPriceBX96, uint128(uint256(currentPositions[i].liquidityDelta))
                    );
                }

                break;
            }
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
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

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        if (block.timestamp > lastPrizeDrawTimestamp[key.toId()] + PRIZE_DRAW_INTERVAL) {
            _requestRandomWord(key);
        }

        return (this.afterSwap.selector, 0);
    }

    function deposit(uint256 amount) external {
        unchecked {
            linkTokenBalance += amount;
        }
        i_linkToken.transferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
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

        accumulatedPrize[key.toId()][feeCurrency] += amountToAccumulateToPrize;
    }

    /**
     * @dev Fulfills the VRF request identified by the given request ID with the randomWords provided.
     */
    // solhint-disable-next-line
    function fulfillRandomWords(uint256 chainlinkVRFRequestID, uint256[] memory randomWords) internal override {
        PoolKey memory key = requests[chainlinkVRFRequestID];
        if (key.tickSpacing == 0) revert InvalidChainlinkVRFRequestID();

        PoolId poolId = key.toId();

        uint256 totalNumberOfPositionsInPool = numberOfPositions[poolId];

        uint256 totalEntriesCount;
        uint256[] memory currentEntryIndexArray = new uint256[](totalNumberOfPositionsInPool);

        address[] memory poolLPs = lpProviders[poolId];

        for (uint256 i = 0; i < poolLPs.length; i++) {
            // Get current positions for this sender in this pool
            LPPositionInfo[] storage currentPositions = lpPositionsInfo[poolId][poolLPs[i]];
            for (uint256 j = 0; j < currentPositions.length; j++) {
                uint256 totalToken0Amount = currentPositions[i].token0Amount;
                uint256 entriesCount = totalToken0Amount / VALUE_PER_ENTRY;
                totalEntriesCount += entriesCount;

                // Calculate current entry index for this LP provider
                currentEntryIndexArray[j] = j == 0 ? entriesCount - 1 : currentEntryIndexArray[j - 1] + entriesCount;

                entryIndexToProvider[currentEntryIndexArray[j]] = poolLPs[i];
            }
        }

        // Determine the winner based on the random number
        uint256 randomWord = randomWords[0];
        uint256 winningEntry = randomWord % totalEntriesCount;

        address winner = entryIndexToProvider[winningEntry];

        if (accumulatedPrize[poolId][key.currency0] > 0) {
            key.currency0.transfer(winner, accumulatedPrize[poolId][key.currency0]);
            accumulatedPrize[poolId][key.currency0] = 0;
        }

        if (accumulatedPrize[poolId][key.currency1] > 0) {
            key.currency1.transfer(winner, accumulatedPrize[poolId][key.currency1]);
            accumulatedPrize[poolId][key.currency1] = 0;
        }
    }

    /**
     * @dev Called when a time comes to draw a new prize winner
     */
    function _requestRandomWord(PoolKey calldata key) internal {
        uint256 requestPrice = i_vrfV2PlusWrapper.calculateRequestPrice(VRF_CALLBACK_GAS_LIMIT, 1);

        // Ensure that hook has enough link token to pay VRF request
        if (requestPrice > linkTokenBalance) revert InsufficientBalance();
        unchecked {
            linkTokenBalance -= requestPrice;
        }

        // Pass the request on the Chainlink VRF coordinator
        (uint256 chainlinkVRFRequestID,) = requestRandomness(
            VRF_CALLBACK_GAS_LIMIT,
            minimumConfirmations,
            1,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
        );

        requests[chainlinkVRFRequestID] = key;
    }
}
