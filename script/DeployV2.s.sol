// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {P2FluxFeeRegistry} from "../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2} from "../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxRecurringV2} from "../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../contracts/v2/P2FluxSend.sol";

/// Deploy v2 to Base Sepolia only: registry first, then payments (self-pay + sponsored in one
/// contract, one replay table), recurring and send. Four contracts.
/// Addresses come from the environment (ADMIN, RELAYER, FEE_WALLET, GAS_TREASURY, USDC); the key
/// from TEST_PRIVATE_KEY (a test-only wallet via `p2flux-testkey run`). Never prints either key.
///   p2flux-testkey run v2-sepolia-deployer -- forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast
contract DeployV2 is Script {
    uint256 constant MAX_NETWORK_FEE_HARD_CAP = 250_000; // 0.25 USDC, as v1 on Base
    uint256 constant GAS_REIMBURSEMENT_HARD_CAP = 50_000; // 0.05 USDC, as v1 on Base

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        address admin = vm.envAddress("ADMIN");
        address relayer = vm.envAddress("RELAYER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address gasTreasury = vm.envAddress("GAS_TREASURY");
        address usdc = vm.envAddress("USDC");

        vm.startBroadcast(vm.envUint("TEST_PRIVATE_KEY"));
        P2FluxFeeRegistry registry = new P2FluxFeeRegistry(
            admin,
            P2FluxFeeRegistry.Rate(100, 75, 50_000),
            P2FluxFeeRegistry.Rate(150, 125, 50_000),
            P2FluxFeeRegistry.Rate(10, 10, 50_000)
        );
        address reg = address(registry);
        P2FluxPaymentsV2 payments =
            new P2FluxPaymentsV2(usdc, feeWallet, gasTreasury, relayer, reg, MAX_NETWORK_FEE_HARD_CAP);
        P2FluxRecurringV2 recurring =
            new P2FluxRecurringV2(admin, relayer, feeWallet, gasTreasury, usdc, reg, GAS_REIMBURSEMENT_HARD_CAP);
        P2FluxSend send = new P2FluxSend(usdc, feeWallet, gasTreasury, relayer, reg);
        vm.stopBroadcast();

        console.log("REGISTRY", reg);
        console.log("PAYMENTS", address(payments));
        console.log("RECURRING", address(recurring));
        console.log("SEND", address(send));
    }
}
