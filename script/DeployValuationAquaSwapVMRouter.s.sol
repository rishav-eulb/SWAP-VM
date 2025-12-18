// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.0;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Script } from "forge-std/Script.sol";

import { Config } from "./utils/Config.sol";

import { ValuationAquaSwapVMRouter } from "../src/routers/ValuationAquaSwapVMRouter.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

/// @title DeployValuationAquaSwapVMRouter
/// @notice Deployment script for ValuationAquaSwapVMRouter
/// @dev Deploys a SwapVM router with Aqua integration and valuation adjustment support
contract DeployValuationAquaSwapVMRouter is Script {
    using Config for *;

    function run() external {
        (
            address aquaAddress,
            string memory name,
            string memory version
        ) = vm.readSwapVMRouterParameters();

        vm.startBroadcast();
        ValuationAquaSwapVMRouter swapVMRouter = new ValuationAquaSwapVMRouter(
            aquaAddress,
            name,
            version
        );
        vm.stopBroadcast();

        console2.log("ValuationAquaSwapVMRouter deployed at: ", address(swapVMRouter));
    }
}
// solhint-enable no-console

