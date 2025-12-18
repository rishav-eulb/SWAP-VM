// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "../utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../../src/SwapVM.sol";
import { Context, VM, SwapQuery, SwapRegisters } from "../../src/libs/VM.sol";
import { Simulator } from "../../src/libs/Simulator.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { ValuationAdjust, ValuationAdjustArgsBuilder, VALUATION_PRECISION } from "../../src/instructions/ValuationAdjust.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { ControlsArgsBuilder } from "../../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";

/// @notice Test router with ValuationAdjust instructions added
contract TestValuationRouter is Simulator, SwapVM, OpcodesDebug, ValuationAdjust {
    constructor(address aqua) 
        SwapVM(aqua, "TestValuationRouter", "1.0.0") 
        OpcodesDebug(aqua) 
    {}
    
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[] memory base = _opcodes();
        
        result = new function(Context memory, bytes calldata) internal[](base.length + 4);
        
        for (uint256 i = 0; i < base.length; i++) {
            result[i] = base[i];
        }
        
        result[base.length + 0] = _valuationAdjustStaticXD;
        result[base.length + 1] = _valuationAdjustOracleXD;
        result[base.length + 2] = _valuationAdjustBoundedXD;
        result[base.length + 3] = _valuationAdjustOracleBoundedXD;
    }
}

contract MockValuationOracle {
    uint256 public valuation;
    uint256 public updatedAt;
    
    function setValuation(uint256 _valuation) external {
        valuation = _valuation;
        updatedAt = block.timestamp;
    }
    
    function getValuation(address, address) external view returns (uint256) {
        return valuation;
    }
    
    function getValuationWithTimestamp(address, address) external view returns (uint256, uint256) {
        return (valuation, updatedAt);
    }
}

/// @notice Helper contract to test library revert behavior via external call
contract ArgsBuilderHelper {
    function buildStatic(uint256 valuation) external pure returns (bytes memory) {
        return ValuationAdjustArgsBuilder.buildStatic(valuation);
    }
}

contract ValuationAdjustTest is Test, OpcodesDebug, ValuationAdjust {
    using ProgramBuilder for Program;

    TestValuationRouter public swapVM;
    MockValuationOracle public oracle;
    ArgsBuilderHelper public argsHelper;
    
    address public tokenA;
    address public tokenB;
    
    address public maker;
    uint256 public makerPrivateKey;
    address public taker;
    
    uint256 constant INITIAL_BALANCE = 1000e18;
    
    constructor() OpcodesDebug(address(new Aqua())) {}
    
    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        taker = makeAddr("taker");
        
        swapVM = new TestValuationRouter(address(0));
        oracle = new MockValuationOracle();
        argsHelper = new ArgsBuilderHelper();
        
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));
        
        // Setup initial balances
        TokenMock(tokenA).mint(maker, 10000e18);
        TokenMock(tokenB).mint(maker, 10000e18);
        TokenMock(tokenA).mint(taker, 10000e18);
        TokenMock(tokenB).mint(taker, 10000e18);
        
        // Approve SwapVM
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }
    
    /// @dev Get extended opcodes including ValuationAdjust
    function _testOpcodes() internal pure returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[] memory base = _opcodes();
        
        result = new function(Context memory, bytes calldata) internal[](base.length + 4);
        
        for (uint256 i = 0; i < base.length; i++) {
            result[i] = base[i];
        }
        
        result[base.length + 0] = _valuationAdjustStaticXD;
        result[base.length + 1] = _valuationAdjustOracleXD;
        result[base.length + 2] = _valuationAdjustBoundedXD;
        result[base.length + 3] = _valuationAdjustOracleBoundedXD;
    }
    
    uint256 private orderNonce = 0;
    
    /// @dev Build taker traits with signature included (as expected by SwapVM)
    function _buildTakerData(bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ORDER CREATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════
    
    function createStaticValuationOrder(
        uint256 valuation,
        uint256 balanceA,
        uint256 balanceB
    ) internal returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_testOpcodes());
        bytes memory programBytes = bytes.concat(
            p.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(dynamic([tokenA, tokenB]), dynamic([balanceA, balanceB]))),
            p.build(_valuationAdjustStaticXD,
                ValuationAdjustArgsBuilder.buildStatic(valuation)),
            p.build(_xycSwapXD),
            p.build(_salt,
                ControlsArgsBuilder.buildSalt(uint64(0x1000 + orderNonce++)))
        );
        
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
            program: programBytes
        }));
        
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }
    
    function createOracleValuationOrder(
        address oracleAddress,
        uint16 maxStaleness,
        uint256 balanceA,
        uint256 balanceB
    ) internal returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory p = ProgramBuilder.init(_testOpcodes());
        bytes memory programBytes = bytes.concat(
            p.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(dynamic([tokenA, tokenB]), dynamic([balanceA, balanceB]))),
            p.build(_valuationAdjustOracleXD,
                ValuationAdjustArgsBuilder.buildOracle(oracleAddress, maxStaleness)),
            p.build(_xycSwapXD),
            p.build(_salt,
                ControlsArgsBuilder.buildSalt(uint64(0x2000 + orderNonce++)))
        );
        
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
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
            program: programBytes
        }));
        
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }
    
    function executeSwap(
        ISwapVM.Order memory order,
        bytes memory signature,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 resultAmountIn, uint256 resultAmountOut) {
        bytes memory takerData = _buildTakerData(signature);
        
        vm.prank(taker);
        (resultAmountIn, resultAmountOut,) = swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amountIn,
            takerData
        );
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // STATIC VALUATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    function test_StaticValuation_EqualWeighting() public {
        uint256 v = 5e17; // 0.5e18 = 50%
        
        (ISwapVM.Order memory order, bytes memory signature) = createStaticValuationOrder(
            v,
            INITIAL_BALANCE,
            INITIAL_BALANCE
        );
        
        uint256 swapAmount = 10e18;
        
        (uint256 amountIn, uint256 amountOut) = executeSwap(
            order,
            signature,
            tokenA,
            tokenB,
            swapAmount
        );
        
        console.log("Swap: amountIn=%d, amountOut=%d", amountIn, amountOut);
        
        assertGt(amountOut, 0, "Should receive some output");
        assertEq(amountIn, swapAmount, "Input should match requested");
    }
    
    function test_StaticValuation_WETHHeavy() public {
        uint256 v = 8e17; // 0.8e18 = 80%
        
        (ISwapVM.Order memory order, bytes memory signature) = createStaticValuationOrder(
            v,
            INITIAL_BALANCE,
            INITIAL_BALANCE
        );
        
        uint256 swapAmount = 10e18;
        
        (uint256 amountIn, uint256 amountOut) = executeSwap(
            order,
            signature,
            tokenA,
            tokenB,
            swapAmount
        );
        
        console.log("Swap with v=0.8: amountIn=%d, amountOut=%d", amountIn, amountOut);
        
        assertGt(amountOut, 0, "Should receive some output");
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ORACLE VALUATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    function test_OracleValuation_FreshData() public {
        oracle.setValuation(6e17); // 0.6e18
        
        (ISwapVM.Order memory order, bytes memory signature) = createOracleValuationOrder(
            address(oracle),
            3600,
            INITIAL_BALANCE,
            INITIAL_BALANCE
        );
        
        uint256 swapAmount = 10e18;
        
        (uint256 amountIn, uint256 amountOut) = executeSwap(
            order,
            signature,
            tokenA,
            tokenB,
            swapAmount
        );
        
        console.log("Oracle swap: amountIn=%d, amountOut=%d", amountIn, amountOut);
        
        assertGt(amountOut, 0, "Should receive some output");
    }
    
    function test_OracleValuation_StaleData_Reverts() public {
        oracle.setValuation(6e17);
        
        vm.warp(block.timestamp + 7200); // 2 hours
        
        (ISwapVM.Order memory order, bytes memory signature) = createOracleValuationOrder(
            address(oracle),
            3600, // 1 hour limit
            INITIAL_BALANCE,
            INITIAL_BALANCE
        );
        
        bytes memory takerData = _buildTakerData(signature);
        
        vm.prank(taker);
        vm.expectRevert();
        swapVM.swap(
            order,
            tokenA,
            tokenB,
            10e18,
            takerData
        );
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ARGS BUILDER TESTS (using external helper for expectRevert to work)
    // ═══════════════════════════════════════════════════════════════════════════
    
    function test_ArgsBuilder_RevertWhen_InvalidValuation_Zero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ValuationAdjustArgsBuilder.ValuationOutOfRange.selector,
                0
            )
        );
        argsHelper.buildStatic(0);
    }
    
    function test_ArgsBuilder_RevertWhen_InvalidValuation_One() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ValuationAdjustArgsBuilder.ValuationOutOfRange.selector,
                1e18
            )
        );
        argsHelper.buildStatic(1e18);
    }
    
    function test_ArgsBuilder_ValidValuation() public pure {
        bytes memory args = ValuationAdjustArgsBuilder.buildStatic(5e17);
        assertGt(args.length, 0, "Should build valid args");
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // QUOTE TESTS
    // ═══════════════════════════════════════════════════════════════════════════
    
    function test_Quote_StaticValuation() public {
        uint256 v = 5e17;
        
        (ISwapVM.Order memory order,) = createStaticValuationOrder(
            v,
            INITIAL_BALANCE,
            INITIAL_BALANCE
        );
        
        bytes memory takerData = _buildTakerData("");
        
        (uint256 amountIn, uint256 amountOut,) = swapVM.asView().quote(
            order,
            tokenA,
            tokenB,
            10e18,
            takerData
        );
        
        console.log("Quote: amountIn=%d, amountOut=%d", amountIn, amountOut);
        
        assertEq(amountIn, 10e18, "Quote amountIn should match");
        assertGt(amountOut, 0, "Quote should return positive amountOut");
    }
}
