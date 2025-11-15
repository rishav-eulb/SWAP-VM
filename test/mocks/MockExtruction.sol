// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { SwapQuery, SwapRegisters } from "../../src/libs/VM.sol";
import { IExtruction } from "../../src/instructions/Extruction.sol";

/// @notice Mock contract for testing Extruction instruction
contract MockExtruction is IExtruction {
    // Storage variable to test state changes
    uint256 public stateVar;

    // Events to track calls
    event ExtructionCalled(
        bool isStaticContext,
        uint256 nextPC,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    // Different behaviors for testing
    enum Behavior {
        Normal,           // Normal execution
        TryStateChange,   // Attempts to change state
        RevertAlways,     // Always reverts
        CustomNextPC,     // Returns custom nextPC
        ChopData          // Chops taker data
    }

    Behavior public behavior = Behavior.Normal;
    uint256 public customNextPC = 0;
    uint256 public chopLength = 0;

    function setBehavior(Behavior _behavior) external {
        behavior = _behavior;
    }

    function setCustomNextPC(uint256 _nextPC) external {
        customNextPC = _nextPC;
    }

    function setChopLength(uint256 _length) external {
        chopLength = _length;
    }

    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata /* args */,
        bytes calldata /* takerData */
    ) external override returns (
        uint256 updatedNextPC,
        uint256 choppedLength,
        SwapRegisters memory updatedSwap
    ) {
        emit ExtructionCalled(
            isStaticContext,
            nextPC,
            query.tokenIn,
            query.tokenOut,
            swap.amountIn,
            swap.amountOut
        );

        if (behavior == Behavior.RevertAlways) {
            revert("MockExtruction: forced revert");
        }

        if (behavior == Behavior.TryStateChange) {
            // This will fail if called via staticcall
            stateVar++;
        }

        // Return modified values based on behavior
        updatedNextPC = (behavior == Behavior.CustomNextPC) ? customNextPC : nextPC;
        choppedLength = (behavior == Behavior.ChopData) ? chopLength : 0;

        // Modify swap values for testing
        updatedSwap = swap;
        if (behavior == Behavior.Normal || behavior == Behavior.CustomNextPC || behavior == Behavior.ChopData) {
            // Only modify amountOut for testing (not amountIn to avoid TakerTraitsTakerAmountInMismatch)
            updatedSwap.amountOut = swap.amountOut * 110 / 100;
        }

        return (updatedNextPC, choppedLength, updatedSwap);
    }

    // Helper function to read state without changing it
    function readState() external view returns (uint256) {
        return stateVar;
    }
}
