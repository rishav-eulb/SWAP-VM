// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ValuationAquaOpcodes } from "../opcodes/ValuationAquaOpcodes.sol";
import { SwapVM, ISwapVM } from "../SwapVM.sol";
import { MakerTraitsLib } from "../libs/MakerTraits.sol";
import { ProgramBuilder, Program } from "../../test/utils/ProgramBuilder.sol";

import { DecayArgsBuilder } from "../instructions/Decay.sol";
import { XYCConcentrateArgsBuilder, ONE } from "../instructions/XYCConcentrate.sol";
import { FeeArgsBuilder, BPS } from "../instructions/Fee.sol";
import { ControlsArgsBuilder } from "../instructions/Controls.sol";
import { ValuationAdjustArgsBuilder, VALUATION_PRECISION } from "../instructions/ValuationAdjust.sol";

/**
 * @title ValuationAquaAMM
 * @notice Strategy builder for Aqua AMM with external valuation adjustment
 * @dev Implements pseudo-arbitrage from Section 6.1 of Engel & Herlihy paper
 * 
 * This strategy automatically rebalances pool composition based on external
 * valuation (from oracle or static), eliminating arbitrage profit leakage
 * and reducing impermanent loss.
 * 
 * Program flow:
 *   1. ValuationAdjust - Rebalance to Y/X = v/(1-v)
 *   2. XYCConcentrate (optional) - Concentrate liquidity in price range
 *   3. Decay (optional) - MEV protection via virtual balances
 *   4. Fee (optional) - Trading fees
 *   5. XYCSwap - Execute constant product swap
 *   6. Deadline - Order expiration
 */
contract ValuationAquaAMM is ValuationAquaOpcodes {
    using SafeCast for uint256;
    using ProgramBuilder for Program;

    error ProtocolFeesExceedMakerFees(uint256 protocolFeeBps, uint256 makerFeeBps);
    error InvalidValuation(uint256 valuation);

    constructor(address aqua) ValuationAquaOpcodes(aqua) {}

    /// @notice Configuration for valuation-adjusted AMM
    struct ValuationAMMConfig {
        address maker;
        uint40 expiration;
        address token0;
        address token1;
        // Valuation settings (choose one approach)
        bool useOracleValuation;
        uint256 staticValuation;      // Used if !useOracleValuation (scaled by 1e18)
        address valuationOracle;      // Used if useOracleValuation
        uint16 maxStaleness;          // Oracle staleness limit (seconds)
        uint32 maxAdjustBps;          // Maximum adjustment (0 = unlimited)
        // Concentration (optional, set both to 0 to disable)
        uint256 delta0;
        uint256 delta1;
        // MEV protection (optional, set to 0 to disable)
        uint16 decayPeriod;
        // Fees
        uint16 feeBpsIn;
        uint16 protocolFeeBpsIn;
        address feeReceiver;
        // Order uniqueness
        uint64 salt;
    }

    /// @notice Build a valuation-adjusted AMM order
    /// @param config Complete configuration for the strategy
    /// @return order The constructed ISwapVM.Order ready for Aqua shipping
    function buildValuationProgram(ValuationAMMConfig memory config) 
        public 
        pure 
        returns (ISwapVM.Order memory order) 
    {
        // Validate inputs
        require(
            config.protocolFeeBpsIn <= config.feeBpsIn, 
            ProtocolFeesExceedMakerFees(config.protocolFeeBpsIn, config.feeBpsIn)
        );
        
        if (!config.useOracleValuation) {
            require(
                config.staticValuation > 0 && config.staticValuation < VALUATION_PRECISION,
                InvalidValuation(config.staticValuation)
            );
        }

        Program memory program = ProgramBuilder.init(_opcodes());
        
        // Build bytecode with valuation adjustment as first step
        bytes memory bytecode = _buildBytecode(program, config);

        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: config.maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: bytecode
        }));
    }

    /// @notice Simplified builder for static valuation AMM
    /// @param maker The maker address
    /// @param expiration Order expiration timestamp
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param valuation Valuation v * 1e18 (e.g., 0.5e18 for equal weighting)
    /// @param feeBpsIn Fee in basis points (1e9 = 100%)
    /// @param decayPeriod MEV protection decay period in seconds (0 to disable)
    /// @param salt Order uniqueness salt
    function buildStaticValuationProgram(
        address maker,
        uint40 expiration,
        address token0,
        address token1,
        uint256 valuation,
        uint16 feeBpsIn,
        uint16 decayPeriod,
        uint64 salt
    ) external pure returns (ISwapVM.Order memory) {
        return buildValuationProgram(ValuationAMMConfig({
            maker: maker,
            expiration: expiration,
            token0: token0,
            token1: token1,
            useOracleValuation: false,
            staticValuation: valuation,
            valuationOracle: address(0),
            maxStaleness: 0,
            maxAdjustBps: 0,
            delta0: 0,
            delta1: 0,
            decayPeriod: decayPeriod,
            feeBpsIn: feeBpsIn,
            protocolFeeBpsIn: 0,
            feeReceiver: address(0),
            salt: salt
        }));
    }

    /// @notice Simplified builder for oracle-based valuation AMM
    /// @param maker The maker address
    /// @param expiration Order expiration timestamp
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param valuationOracle Address of valuation oracle
    /// @param maxStaleness Maximum oracle staleness in seconds
    /// @param maxAdjustBps Maximum adjustment per trade (e.g., 0.05e9 for 5% max)
    /// @param feeBpsIn Fee in basis points
    /// @param decayPeriod MEV protection decay period
    /// @param salt Order uniqueness salt
    function buildOracleValuationProgram(
        address maker,
        uint40 expiration,
        address token0,
        address token1,
        address valuationOracle,
        uint16 maxStaleness,
        uint32 maxAdjustBps,
        uint16 feeBpsIn,
        uint16 decayPeriod,
        uint64 salt
    ) external pure returns (ISwapVM.Order memory) {
        return buildValuationProgram(ValuationAMMConfig({
            maker: maker,
            expiration: expiration,
            token0: token0,
            token1: token1,
            useOracleValuation: true,
            staticValuation: 0,
            valuationOracle: valuationOracle,
            maxStaleness: maxStaleness,
            maxAdjustBps: maxAdjustBps,
            delta0: 0,
            delta1: 0,
            decayPeriod: decayPeriod,
            feeBpsIn: feeBpsIn,
            protocolFeeBpsIn: 0,
            feeReceiver: address(0),
            salt: salt
        }));
    }

    /// @notice Builder for concentrated liquidity with static valuation
    /// @param maker The maker address
    /// @param expiration Order expiration timestamp
    /// @param token0 First token address
    /// @param token1 Second token address
    /// @param valuation Valuation v * 1e18
    /// @param delta0 Concentration delta for token0
    /// @param delta1 Concentration delta for token1
    /// @param feeBpsIn Fee in basis points
    /// @param decayPeriod MEV protection decay period
    /// @param salt Order uniqueness salt
    function buildConcentratedValuationProgram(
        address maker,
        uint40 expiration,
        address token0,
        address token1,
        uint256 valuation,
        uint256 delta0,
        uint256 delta1,
        uint16 feeBpsIn,
        uint16 decayPeriod,
        uint64 salt
    ) external pure returns (ISwapVM.Order memory) {
        return buildValuationProgram(ValuationAMMConfig({
            maker: maker,
            expiration: expiration,
            token0: token0,
            token1: token1,
            useOracleValuation: false,
            staticValuation: valuation,
            valuationOracle: address(0),
            maxStaleness: 0,
            maxAdjustBps: 0,
            delta0: delta0,
            delta1: delta1,
            decayPeriod: decayPeriod,
            feeBpsIn: feeBpsIn,
            protocolFeeBpsIn: 0,
            feeReceiver: address(0),
            salt: salt
        }));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildBytecode(
        Program memory program, 
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        return bytes.concat(
            // 1. Valuation adjustment (FIRST - rebalances before any swap logic)
            _buildValuationInstruction(program, config),
            
            // 2. Concentration (optional)
            _buildConcentrationInstruction(program, config),
            
            // 3. Decay for MEV protection (optional)
            _buildDecayInstruction(program, config),
            
            // 4. Trading fee (optional)
            _buildFeeInstruction(program, config),
            
            // 5. Protocol fee (optional)
            _buildProtocolFeeInstruction(program, config),
            
            // 6. XYC Swap (core AMM logic)
            program.build(_xycSwapXD),
            
            // 7. Deadline
            program.build(_deadline, ControlsArgsBuilder.buildDeadline(config.expiration)),
            
            // 8. Salt for uniqueness (optional)
            _buildSaltInstruction(program, config)
        );
    }

    function _buildValuationInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.useOracleValuation) {
            if (config.maxAdjustBps > 0) {
                // Oracle with bounds
                return program.build(
                    _valuationAdjustOracleBoundedXD,
                    ValuationAdjustArgsBuilder.buildOracleBounded(
                        config.valuationOracle,
                        config.maxStaleness,
                        config.maxAdjustBps
                    )
                );
            } else {
                // Oracle without bounds
                return program.build(
                    _valuationAdjustOracleXD,
                    ValuationAdjustArgsBuilder.buildOracle(
                        config.valuationOracle,
                        config.maxStaleness
                    )
                );
            }
        } else {
            if (config.maxAdjustBps > 0) {
                // Static with bounds
                return program.build(
                    _valuationAdjustBoundedXD,
                    ValuationAdjustArgsBuilder.buildBounded(
                        config.staticValuation,
                        config.maxAdjustBps
                    )
                );
            } else {
                // Static without bounds
                return program.build(
                    _valuationAdjustStaticXD,
                    ValuationAdjustArgsBuilder.buildStatic(config.staticValuation)
                );
            }
        }
    }

    function _buildConcentrationInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.delta0 != 0 || config.delta1 != 0) {
            return program.build(
                _xycConcentrateGrowLiquidity2D, 
                XYCConcentrateArgsBuilder.build2D(
                    config.token0, config.token1, config.delta0, config.delta1
                )
            );
        }
        return bytes("");
    }

    function _buildDecayInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.decayPeriod > 0) {
            return program.build(_decayXD, DecayArgsBuilder.build(config.decayPeriod));
        }
        return bytes("");
    }

    function _buildFeeInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.feeBpsIn > 0) {
            return program.build(_flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(config.feeBpsIn));
        }
        return bytes("");
    }

    function _buildProtocolFeeInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.protocolFeeBpsIn > 0) {
            return program.build(
                _aquaProtocolFeeAmountOutXD, 
                FeeArgsBuilder.buildProtocolFee(config.protocolFeeBpsIn, config.feeReceiver)
            );
        }
        return bytes("");
    }

    function _buildSaltInstruction(
        Program memory program,
        ValuationAMMConfig memory config
    ) private pure returns (bytes memory) {
        if (config.salt > 0) {
            return program.build(_salt, ControlsArgsBuilder.buildSalt(config.salt));
        }
        return bytes("");
    }
}
