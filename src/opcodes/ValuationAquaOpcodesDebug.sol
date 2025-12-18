// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Context } from "../libs/VM.sol";

import { ValuationAquaOpcodes } from "./ValuationAquaOpcodes.sol";
import { Debug } from "../instructions/Debug.sol";

/**
 * @title ValuationAquaOpcodesDebug
 * @notice Debug variant of ValuationAquaOpcodes with logging utilities
 * @dev Injects debug instructions at indices 0-4 for development/testing
 */
contract ValuationAquaOpcodesDebug is ValuationAquaOpcodes, Debug {
    constructor(address aqua) ValuationAquaOpcodes(aqua) {}

    function _opcodes() internal pure override returns (
        function(Context memory, bytes calldata) internal[] memory
    ) {
        return _injectDebugOpcodes(ValuationAquaOpcodes._opcodes());
    }
}
