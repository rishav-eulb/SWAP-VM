// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Calldata } from "../libs/Calldata.sol";
import { Context, ContextLib, SwapQuery, SwapRegisters } from "../libs/VM.sol";

interface IExtruction {
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata takerData
    ) external returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    );
}

contract Extruction {
    using Calldata for bytes;
    using ContextLib for Context;

    error ExtructionMissingTargetArg();
    error ExtructionChoppedExceededLength(bytes chopped, uint256 requested);
    error ExtructionCallFailed();

    /// @dev Calls an external contract to perform custom logic, potentially modifying the swap state
    /// @param args.target         | 20 bytes
    /// @param args.extructionArgs | N bytes
    function _extruction(Context memory ctx, bytes calldata args) internal {
        address target = address(bytes20(args.slice(0, 20, ExtructionMissingTargetArg.selector)));

        // Encode the function call
        bytes memory callData = abi.encodeWithSelector(
            IExtruction.extruction.selector,
            ctx.vm.isStaticContext,
            ctx.vm.nextPC,
            ctx.query,
            ctx.swap,
            args.slice(20),
            ctx.takerArgs()
        );

        uint256 choppedLength;
        bool success;
        bytes memory returnData;

        if (ctx.vm.isStaticContext) {
            // Use staticcall for static context (no state changes allowed)
            (success, returnData) = target.staticcall(callData);
        } else {
            // Use regular call for mutable context
            (success, returnData) = target.call(callData);
        }

        // Check if the call was successful
        require(success, ExtructionCallFailed());

        // Decode the return data
        (ctx.vm.nextPC, choppedLength, ctx.swap) = abi.decode(
            returnData,
            (uint256, uint256, SwapRegisters)
        );

        // Verify chopped length
        bytes calldata chopped = ctx.tryChopTakerArgs(choppedLength);
        require(chopped.length == choppedLength, ExtructionChoppedExceededLength(chopped, choppedLength));
    }
}
