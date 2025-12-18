// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Simulator } from "../libs/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { ValuationAquaOpcodes } from "../opcodes/ValuationAquaOpcodes.sol";

/**
 * @title ValuationAquaSwapVMRouter
 * @notice SwapVM router with Aqua integration and valuation adjustment support
 * @dev Deploy this router to enable valuation-adjusted AMM strategies
 * 
 * Supported instructions (34 total):
 *   - Controls: jump, jumpIf*, deadline, only*, salt
 *   - XYCSwap: constant product AMM
 *   - XYCConcentrate: concentrated liquidity
 *   - Decay: MEV protection
 *   - Fee: flat, progressive, protocol fees
 *   - ValuationAdjust: static, oracle, bounded, oracle-bounded
 */
contract ValuationAquaSwapVMRouter is Simulator, SwapVM, ValuationAquaOpcodes {
    
    constructor(address aqua, string memory name, string memory version) 
        SwapVM(aqua, name, version) 
        ValuationAquaOpcodes(aqua) 
    {}

    function _instructions() internal pure override returns (
        function(Context memory, bytes calldata) internal[] memory result
    ) {
        return _opcodes();
    }
}
