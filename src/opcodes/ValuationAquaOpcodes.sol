// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

import { Controls } from "../instructions/Controls.sol";
import { XYCSwap } from "../instructions/XYCSwap.sol";
import { XYCConcentrate } from "../instructions/XYCConcentrate.sol";
import { Decay } from "../instructions/Decay.sol";
import { Fee } from "../instructions/Fee.sol";
import { ValuationAdjust } from "../instructions/ValuationAdjust.sol";

/**
 * @title ValuationAquaOpcodes
 * @notice Extends AquaOpcodes with valuation-based balance adjustment instructions
 * @dev Adds pseudo-arbitrage functionality from Engel & Herlihy paper
 * 
 * Opcode layout (34 total, indices 0-33):
 *   0:     Reserved (not instruction)
 *   1-10:  Debug reserved
 *   11-17: Controls
 *   18:    XYCSwap
 *   19-22: XYCConcentrate
 *   23:    Decay
 *   24:    Controls._salt
 *   25-30: Fee
 *   31-34: ValuationAdjust (NEW)
 */
contract ValuationAquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee,
    ValuationAdjust
{
    constructor(address aqua) Fee(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[35] memory instructions = [
            _notInstruction,
            // Debug - reserved for debugging utilities (indices 1-10)
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // Controls - control flow (indices 11-17)
            Controls._jump,
            Controls._jumpIfTokenIn,
            Controls._jumpIfTokenOut,
            Controls._deadline,
            Controls._onlyTakerTokenBalanceNonZero,
            Controls._onlyTakerTokenBalanceGte,
            Controls._onlyTakerTokenSupplyShareGte,
            // XYCSwap - basic swap (index 18)
            XYCSwap._xycSwapXD,
            // XYCConcentrate - liquidity concentration (indices 19-22)
            XYCConcentrate._xycConcentrateGrowLiquidityXD,
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            XYCConcentrate._xycConcentrateGrowPriceRangeXD,
            XYCConcentrate._xycConcentrateGrowPriceRange2D,
            // Decay - Decay AMM (index 23)
            Decay._decayXD,
            // Controls._salt (index 24)
            Controls._salt,
            // Fee instructions (indices 25-30)
            Fee._flatFeeAmountInXD,
            Fee._flatFeeAmountOutXD,
            Fee._progressiveFeeInXD,
            Fee._progressiveFeeOutXD,
            Fee._protocolFeeAmountOutXD,
            Fee._aquaProtocolFeeAmountOutXD,
            // ValuationAdjust - external valuation rebalancing (indices 31-34)
            ValuationAdjust._valuationAdjustStaticXD,
            ValuationAdjust._valuationAdjustOracleXD,
            ValuationAdjust._valuationAdjustBoundedXD,
            ValuationAdjust._valuationAdjustOracleBoundedXD
        ];

        // Efficiently turning static memory array into dynamic memory array
        // by rewriting _notInstruction with array length, so it's excluded from the result
        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
    }
}
