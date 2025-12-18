// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";
import { Simulator } from "../libs/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { ValuationAquaOpcodesDebug } from "../opcodes/ValuationAquaOpcodesDebug.sol";

/**
 * @title ValuationAquaSwapVMRouterDebug
 * @notice Debug variant of ValuationAquaSwapVMRouter with logging utilities
 * @dev Use only for development and testing - includes console.log support
 * 
 * Additional debug instructions:
 *   - _printSwapRegisters (index 0)
 *   - _printSwapQuery (index 1)
 *   - _printContext (index 2)
 *   - _printFreeMemoryPointer (index 3)
 *   - _printGasLeft (index 4)
 */
contract ValuationAquaSwapVMRouterDebug is Simulator, SwapVM, ValuationAquaOpcodesDebug {
    
    constructor(address aqua, string memory name, string memory version) 
        SwapVM(aqua, name, version) 
        ValuationAquaOpcodesDebug(aqua) 
    {}

    function _instructions() internal pure override returns (
        function(Context memory, bytes calldata) internal[] memory
    ) {
        return _opcodes();
    }
}
