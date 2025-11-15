// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { Extruction } from "../src/instructions/Extruction.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { MockExtruction } from "./mocks/MockExtruction.sol";

contract ExtructionTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    MockExtruction public mockExtruction;

    address public tokenA;
    address public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public trader = makeAddr("trader");

    // Test parameters
    uint256 constant INITIAL_LIQUIDITY = 1000e18;
    uint256 constant SWAP_AMOUNT = 100e18;

    function setUp() public {
        // Setup maker with known private key for signing
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        // Deploy SwapVM router
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock extruction contract
        mockExtruction = new MockExtruction();

        // Deploy mock tokens
        tokenA = address(new TokenMock("Token A", "TKA"));
        tokenB = address(new TokenMock("Token B", "TKB"));

        // Setup initial balances
        TokenMock(tokenA).mint(maker, 10000e18);
        TokenMock(tokenB).mint(maker, 10000e18);
        TokenMock(tokenA).mint(trader, 10000e18);
        TokenMock(tokenB).mint(trader, 10000e18);

        // Approve SwapVM
        vm.prank(maker);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
        vm.prank(trader);
        TokenMock(tokenA).approve(address(swapVM), type(uint256).max);
        vm.prank(trader);
        TokenMock(tokenB).approve(address(swapVM), type(uint256).max);
    }

    uint256 private orderNonce = 0;

    /// @notice Helper to build Extruction args with target address
    function buildExtructionArgs(address target, bytes memory additionalArgs)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(bytes20(target), additionalArgs);
    }

    function createOrderWithExtruction(
        MockExtruction.Behavior behavior,
        bytes memory extructionExtraArgs
    ) internal returns (ISwapVM.Order memory order, bytes memory signature) {
        // Configure mock behavior
        mockExtruction.setBehavior(behavior);

        Program memory p = ProgramBuilder.init(_opcodes());

        // Build program with Extruction
        bytes memory programBytes = bytes.concat(
            p.build(Balances._dynamicBalancesXD,
                BalancesArgsBuilder.build(dynamic([tokenA, tokenB]), dynamic([INITIAL_LIQUIDITY, INITIAL_LIQUIDITY]))),
            p.build(Extruction._extruction,
                buildExtructionArgs(address(mockExtruction), extructionExtraArgs)),
            p.build(XYCSwap._xycSwapXD, ""),
            p.build(Controls._salt,
                ControlsArgsBuilder.buildSalt(uint32(0x1000 + orderNonce++)))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            expiration: 0,
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

        return (order, signature);
    }

    function executeSwap(
        ISwapVM.Order memory order,
        bytes memory signature
    ) internal returns (uint256 actualAmountIn, uint256 actualAmountOut) {
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: trader,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
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

        vm.prank(trader);
        (actualAmountIn, actualAmountOut,) = swapVM.swap(
            order,
            tokenA,
            tokenB,
            SWAP_AMOUNT,
            takerData
        );

        return (actualAmountIn, actualAmountOut);
    }

    function executeQuote(
        ISwapVM.Order memory order
    ) internal returns (uint256 quotedAmountIn, uint256 quotedAmountOut) {
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: trader,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: true,
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
            signature: ""
        }));

        vm.expectRevert(Extruction.ExtructionCallFailed.selector);
        (quotedAmountIn, quotedAmountOut,) = swapVM.quote(
            order,
            tokenA,
            tokenB,
            SWAP_AMOUNT,
            takerData
        );

        return (quotedAmountIn, quotedAmountOut);
    }

    /// @notice Test 1: swap() allows storage changes
    function test_SwapAllowsStorageChanges() public {
        // Create order with TryStateChange behavior
        (ISwapVM.Order memory order, bytes memory signature) = createOrderWithExtruction(
            MockExtruction.Behavior.TryStateChange,
            ""
        );

        // Initial state should be 0
        assertEq(mockExtruction.stateVar(), 0, "Initial state should be 0");

        // Execute swap - should succeed and change state
        executeSwap(order, signature);

        // State should have changed
        assertEq(mockExtruction.stateVar(), 1, "State should have changed to 1 after swap()");
    }

    /// @notice Test 2: quote() blocks storage changes through staticcall and reverts with ExtructionCallFailed
    function test_QuoteBlocksStorageChanges() public {
        // Create order with TryStateChange behavior
        (ISwapVM.Order memory order,) = createOrderWithExtruction(
            MockExtruction.Behavior.TryStateChange,
            ""
        );

        // Initial state should be 0
        assertEq(mockExtruction.stateVar(), 0, "Initial state should be 0");

        // Execute quote - should revert with ExtructionCallFailed because staticcall blocks state changes
        // When staticcall is used and the target tries to modify state, it returns success=false
        // This triggers the ExtructionCallFailed error in Extruction.sol
        executeQuote(order);

        // State should remain unchanged (we can verify this after the test passes)
        assertEq(mockExtruction.stateVar(), 0, "State should remain 0 after failed quote()");
    }
}
