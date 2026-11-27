// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {P2FluxFeeRegistry} from "../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2} from "../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxRecurringV2} from "../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../contracts/v2/P2FluxSend.sol";

/// Deploy v2 to Base Sepolia, or Base mainnet with the wallets pinned below: registry first, then payments (self-pay + sponsored in one
/// contract, one replay table), recurring and send. Four contracts.
/// Addresses come from the environment (ADMIN, RELAYER, FEE_WALLET, GAS_TREASURY, USDC). The key: on
/// Base Sepolia TEST_PRIVATE_KEY (a test-only wallet via `p2flux-testkey run`), on Base mainnet
/// DEPLOYER_PK (the v2 deployer key file). Never prints either key.
///   p2flux-testkey run v2-sepolia-deployer -- forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast
contract DeployV2 is Script {
    uint256 constant MAX_NETWORK_FEE_HARD_CAP = 250_000; // 0.25 USDC, as v1 on Base
    uint256 constant GAS_REIMBURSEMENT_HARD_CAP = 50_000; // 0.05 USDC, as v1 on Base

    function run() external {
        require(block.chainid == 84532 || block.chainid == 8453, "Base or Base Sepolia only");
        address admin = vm.envAddress("ADMIN");
        address relayer = vm.envAddress("RELAYER");
        address feeWallet = vm.envAddress("FEE_WALLET");
        address gasTreasury = vm.envAddress("GAS_TREASURY");
        address usdc = vm.envAddress("USDC");
        if (block.chainid == 8453) {
            /* Base mainnet (owner OK 26 Nov 2026): the wallets of the live v1 deployment (manifests/base-mainnet.manifest),
             * pinned here so a wrong environment variable cannot put one immutable address wrong. The admin is the v1
             * admin, by owner decision. */
            require(admin == 0xEc8779352AF47C5CbF877e1B22B5CFF6Df042410, "ADMIN is not the v1 admin");
            require(relayer == 0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309, "RELAYER is not the production relayer");
            require(feeWallet == 0x12FDDADa5C8d027537B90342a68F5dd1A79C8feB, "FEE_WALLET is not the production fee wallet");
            require(gasTreasury == 0xdCdE2146cF3ab9aE37933211AF8943c807c31506, "GAS_TREASURY is not the production gas treasury");
            require(usdc == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, "USDC is not native USDC on Base");
        }

        // Sepolia: a test-only wallet (p2flux-testkey). Mainnet: the v2 deployer key file, never printed.
        vm.startBroadcast(block.chainid == 8453 ? vm.envUint("DEPLOYER_PK") : vm.envUint("TEST_PRIVATE_KEY"));
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
