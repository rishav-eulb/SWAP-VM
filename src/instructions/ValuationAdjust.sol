// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib } from "../libs/VM.sol";
import { IValuationOracle } from "./interfaces/IValuationOracle.sol";

/// @dev Precision constant for valuation calculations (1e18 = 100%)
uint256 constant VALUATION_PRECISION = 1e18;

library ValuationAdjustArgsBuilder {
    using Calldata for bytes;

    error ValuationOutOfRange(uint256 valuation);
    error ValuationAdjustMissingValuationArg();
    error ValuationAdjustMissingOracleArg();
    error ValuationAdjustMissingMaxStalenessArg();
    error ValuationAdjustMissingMaxAdjustBpsArg();

    /// @notice Build args for static valuation adjustment
    /// @param valuation The valuation v scaled by 1e18, must be in range (0, 1e18)
    function buildStatic(uint256 valuation) internal pure returns (bytes memory) {
        require(valuation > 0 && valuation < VALUATION_PRECISION, ValuationOutOfRange(valuation));
        return abi.encodePacked(uint96(valuation));
    }

    /// @notice Build args for oracle-based valuation adjustment
    /// @param oracleAddress Address of the IValuationOracle contract
    /// @param maxStaleness Maximum allowed staleness in seconds (0 = no check)
    function buildOracle(
        address oracleAddress,
        uint16 maxStaleness
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(oracleAddress, maxStaleness);
    }

    /// @notice Build args for bounded valuation adjustment
    /// @param valuation The valuation v scaled by 1e18
    /// @param maxAdjustBps Maximum adjustment per direction in basis points (1e9 = 100%)
    function buildBounded(
        uint256 valuation,
        uint32 maxAdjustBps
    ) internal pure returns (bytes memory) {
        require(valuation > 0 && valuation < VALUATION_PRECISION, ValuationOutOfRange(valuation));
        return abi.encodePacked(uint96(valuation), maxAdjustBps);
    }

    /// @notice Build args for oracle-based bounded adjustment
    /// @param oracleAddress Address of the IValuationOracle contract
    /// @param maxStaleness Maximum allowed staleness in seconds
    /// @param maxAdjustBps Maximum adjustment in basis points
    function buildOracleBounded(
        address oracleAddress,
        uint16 maxStaleness,
        uint32 maxAdjustBps
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(oracleAddress, maxStaleness, maxAdjustBps);
    }

    function parseStatic(bytes calldata args) internal pure returns (uint256 valuation) {
        valuation = uint96(bytes12(args.slice(0, 12, ValuationAdjustMissingValuationArg.selector)));
    }

    function parseOracle(bytes calldata args) internal pure returns (
        address oracleAddress,
        uint16 maxStaleness
    ) {
        oracleAddress = address(bytes20(args.slice(0, 20, ValuationAdjustMissingOracleArg.selector)));
        maxStaleness = uint16(bytes2(args.slice(20, 22, ValuationAdjustMissingMaxStalenessArg.selector)));
    }

    function parseBounded(bytes calldata args) internal pure returns (
        uint256 valuation,
        uint32 maxAdjustBps
    ) {
        valuation = uint96(bytes12(args.slice(0, 12, ValuationAdjustMissingValuationArg.selector)));
        maxAdjustBps = uint32(bytes4(args.slice(12, 16, ValuationAdjustMissingMaxAdjustBpsArg.selector)));
    }

    function parseOracleBounded(bytes calldata args) internal pure returns (
        address oracleAddress,
        uint16 maxStaleness,
        uint32 maxAdjustBps
    ) {
        oracleAddress = address(bytes20(args.slice(0, 20, ValuationAdjustMissingOracleArg.selector)));
        maxStaleness = uint16(bytes2(args.slice(20, 22, ValuationAdjustMissingMaxStalenessArg.selector)));
        maxAdjustBps = uint32(bytes4(args.slice(22, 26, ValuationAdjustMissingMaxAdjustBpsArg.selector)));
    }
}

/**
 * @title ValuationAdjust
 * @notice Adjusts balanceIn/balanceOut to match Y/X = v/(1-v) for external valuation v
 * @dev Implements "pseudo-arbitrage" from Section 6.1 of Engel & Herlihy paper:
 *      "Loss and Slippage in Networks of Automated Market Makers"
 * 
 * Mathematical basis:
 *   - Valuation v ∈ (0,1) means v units of X are worth (1-v) units of Y
 *   - At stable point: Y/X = v/(1-v), which is the exchange rate slope
 *   - Capitalization: cap = v*X + (1-v)*Y (preserved during adjustment)
 *   - New balances: X' = cap/(2v), Y' = cap/(2(1-v))
 * 
 * Benefits:
 *   - Eliminates arbitrage profit leakage when market price changes
 *   - Automatic rebalancing to external market price
 *   - Reduces divergence loss (impermanent loss) for liquidity providers
 * 
 * Usage patterns:
 *   1. Static: Fixed valuation from maker's args (e.g., for pegged assets)
 *   2. Oracle: Dynamic valuation from Chainlink or custom oracle
 *   3. Bounded: Limits maximum adjustment to prevent manipulation
 * 
 * Naming convention:
 *   - XD suffix: Works with both directions (bidirectional AMM)
 */
contract ValuationAdjust {
    using Math for uint256;
    using SafeCast for uint256;
    using ContextLib for Context;

    error ValuationAdjustShouldBeCalledBeforeSwapAmountsComputed(uint256 amountIn, uint256 amountOut);
    error ValuationAdjustRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);
    error ValuationAdjustOracleStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness);
    error ValuationAdjustInvalidValuation(uint256 valuation);
    error ValuationAdjustBalanceTooLarge(uint256 balance);

    /// @notice Maximum balance to prevent overflow (safe for v * balance calculations)
    uint256 private constant MAX_BALANCE = type(uint256).max / VALUATION_PRECISION;

    /// @notice Adjust balances to match Y/X = v/(1-v) using static valuation
    /// @dev Pure function - no external calls, uses valuation from args
    /// @param args.valuation | 12 bytes (uint96, scaled by 1e18)
    function _valuationAdjustStaticXD(Context memory ctx, bytes calldata args) internal pure {
        _validatePreConditions(ctx);
        
        uint256 v = ValuationAdjustArgsBuilder.parseStatic(args);
        _applyValuationAdjustment(ctx, v);
    }

    /// @notice Adjust balances using oracle-provided valuation
    /// @dev Calls external oracle - not compatible with static context for quote()
    /// @param args.oracleAddress | 20 bytes
    /// @param args.maxStaleness  | 2 bytes (uint16, seconds)
    function _valuationAdjustOracleXD(Context memory ctx, bytes calldata args) internal view {
        _validatePreConditions(ctx);
        
        (address oracleAddress, uint16 maxStaleness) = ValuationAdjustArgsBuilder.parseOracle(args);
        
        uint256 v = _getOracleValuation(oracleAddress, ctx.query.tokenIn, ctx.query.tokenOut, maxStaleness);
        _applyValuationAdjustment(ctx, v);
    }

    /// @notice Adjust balances with bounded maximum adjustment
    /// @dev Prevents excessive rebalancing that could be exploited
    /// @param args.valuation    | 12 bytes (uint96)
    /// @param args.maxAdjustBps | 4 bytes (uint32, basis points where 1e9 = 100%)
    function _valuationAdjustBoundedXD(Context memory ctx, bytes calldata args) internal pure {
        _validatePreConditions(ctx);
        
        (uint256 v, uint32 maxAdjustBps) = ValuationAdjustArgsBuilder.parseBounded(args);
        _applyBoundedValuationAdjustment(ctx, v, maxAdjustBps);
    }

    /// @notice Adjust balances using oracle with bounded adjustment
    /// @param args.oracleAddress | 20 bytes
    /// @param args.maxStaleness  | 2 bytes (uint16)
    /// @param args.maxAdjustBps  | 4 bytes (uint32)
    function _valuationAdjustOracleBoundedXD(Context memory ctx, bytes calldata args) internal view {
        _validatePreConditions(ctx);
        
        (address oracleAddress, uint16 maxStaleness, uint32 maxAdjustBps) = 
            ValuationAdjustArgsBuilder.parseOracleBounded(args);
        
        uint256 v = _getOracleValuation(oracleAddress, ctx.query.tokenIn, ctx.query.tokenOut, maxStaleness);
        _applyBoundedValuationAdjustment(ctx, v, maxAdjustBps);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _validatePreConditions(Context memory ctx) private pure {
        require(
            ctx.swap.amountIn == 0 || ctx.swap.amountOut == 0, 
            ValuationAdjustShouldBeCalledBeforeSwapAmountsComputed(ctx.swap.amountIn, ctx.swap.amountOut)
        );
        require(
            ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0,
            ValuationAdjustRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut)
        );
        // Overflow protection for subsequent calculations
        require(ctx.swap.balanceIn <= MAX_BALANCE, ValuationAdjustBalanceTooLarge(ctx.swap.balanceIn));
        require(ctx.swap.balanceOut <= MAX_BALANCE, ValuationAdjustBalanceTooLarge(ctx.swap.balanceOut));
    }

    function _getOracleValuation(
        address oracleAddress,
        address tokenIn,
        address tokenOut,
        uint16 maxStaleness
    ) private view returns (uint256 v) {
        IValuationOracle oracle = IValuationOracle(oracleAddress);
        
        if (maxStaleness > 0) {
            uint256 updatedAt;
            (v, updatedAt) = oracle.getValuationWithTimestamp(tokenIn, tokenOut);
            require(
                block.timestamp <= updatedAt + maxStaleness,
                ValuationAdjustOracleStale(block.timestamp, updatedAt, maxStaleness)
            );
        } else {
            v = oracle.getValuation(tokenIn, tokenOut);
        }
        
        require(v > 0 && v < VALUATION_PRECISION, ValuationAdjustInvalidValuation(v));
    }

    /**
     * @dev Core valuation adjustment logic with improved precision
     * 
     * Mathematical derivation:
     *   Given: X = balanceIn, Y = balanceOut, v = valuation
     *   
     *   Step 1: Calculate capitalization (preserved invariant)
     *     cap = v * X + (1-v) * Y
     *   
     *   Step 2: Calculate target balances satisfying Y'/X' = v/(1-v)
     *     From cap = v*X' + (1-v)*Y' and Y' = X' * v/(1-v):
     *     cap = v*X' + (1-v) * X' * v/(1-v) = v*X' + v*X' = 2v*X'
     *     
     *     Therefore:
     *     X' = cap / (2v)
     *     Y' = cap / (2(1-v))
     *   
     *   Step 3: Verify capitalization preservation
     *     v*X' + (1-v)*Y' = v*cap/(2v) + (1-v)*cap/(2(1-v))
     *                     = cap/2 + cap/2 = cap ✓
     * 
     * Precision optimization:
     *   Instead of dividing cap by PRECISION then multiplying back,
     *   we keep cap scaled and divide only at the end:
     *   capScaled = v * X + (1-v) * Y  (still has PRECISION factor)
     *   X' = capScaled / (2 * v)
     *   Y' = capScaled / (2 * (1-v))
     */
    function _applyValuationAdjustment(Context memory ctx, uint256 v) private pure {
        uint256 oneMinusV = VALUATION_PRECISION - v;
        
        // Calculate capitalization without intermediate division for better precision
        // capScaled = v * X + (1-v) * Y
        // Note: v and oneMinusV are scaled by 1e18, so capScaled has extra 1e18 factor
        uint256 capScaled = v * ctx.swap.balanceIn + oneMinusV * ctx.swap.balanceOut;
        
        // Calculate new balances
        // X' = capScaled / (2 * v)
        // Y' = capScaled / (2 * oneMinusV)
        // The PRECISION factor in capScaled cancels with v/oneMinusV scaling
        ctx.swap.balanceIn = capScaled / (2 * v);
        ctx.swap.balanceOut = capScaled / (2 * oneMinusV);
    }

    /**
     * @dev Bounded valuation adjustment - limits maximum change per balance
     * 
     * This prevents oracle manipulation or extreme market moves from
     * causing excessive rebalancing in a single transaction.
     */
    function _applyBoundedValuationAdjustment(
        Context memory ctx, 
        uint256 v, 
        uint32 maxAdjustBps
    ) private pure {
        uint256 oneMinusV = VALUATION_PRECISION - v;
        
        // Calculate target balances using improved precision formula
        uint256 capScaled = v * ctx.swap.balanceIn + oneMinusV * ctx.swap.balanceOut;
        uint256 targetBalanceIn = capScaled / (2 * v);
        uint256 targetBalanceOut = capScaled / (2 * oneMinusV);
        
        // Calculate maximum allowed changes (1e9 = 100%)
        uint256 maxDeltaIn = (ctx.swap.balanceIn * maxAdjustBps) / 1e9;
        uint256 maxDeltaOut = (ctx.swap.balanceOut * maxAdjustBps) / 1e9;
        
        // Apply bounded adjustment for balanceIn
        if (targetBalanceIn > ctx.swap.balanceIn) {
            uint256 delta = targetBalanceIn - ctx.swap.balanceIn;
            ctx.swap.balanceIn += Math.min(delta, maxDeltaIn);
        } else if (targetBalanceIn < ctx.swap.balanceIn) {
            uint256 delta = ctx.swap.balanceIn - targetBalanceIn;
            ctx.swap.balanceIn -= Math.min(delta, maxDeltaIn);
        }
        
        // Apply bounded adjustment for balanceOut
        if (targetBalanceOut > ctx.swap.balanceOut) {
            uint256 delta = targetBalanceOut - ctx.swap.balanceOut;
            ctx.swap.balanceOut += Math.min(delta, maxDeltaOut);
        } else if (targetBalanceOut < ctx.swap.balanceOut) {
            uint256 delta = ctx.swap.balanceOut - targetBalanceOut;
            ctx.swap.balanceOut -= Math.min(delta, maxDeltaOut);
        }
    }
}
