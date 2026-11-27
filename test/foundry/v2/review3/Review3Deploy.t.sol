// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFiatToken} from "../../../../contracts/test/MockTokens.sol";
import {DeployV2} from "../../../../script/DeployV2.s.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxRecurringV2} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice Review 3: runs the REAL deploy script on chain id 8453 (mock USDC etched at the native
///         USDC address unless this is a Base fork) and reads every immutable back, so a swapped
///         constructor argument cannot pass. The key is a throwaway made up here.
contract Review3DeployTest is Test {
    address constant ADMIN = 0xEc8779352AF47C5CbF877e1B22B5CFF6Df042410;
    address constant RELAYER = 0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309;
    address constant FEE_WALLET = 0x12FDDADa5C8d027537B90342a68F5dd1A79C8feB;
    address constant GAS_TREASURY = 0xdCdE2146cF3ab9aE37933211AF8943c807c31506;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant PK = uint256(keccak256("p2flux-review3-throwaway"));

    function setUp() public {
        if (block.chainid != 8453) {
            vm.chainId(8453);
            vm.etch(USDC, address(new MockFiatToken()).code);
        }
        vm.setEnv("ADMIN", vm.toString(ADMIN));
        vm.setEnv("RELAYER", vm.toString(RELAYER));
        vm.setEnv("FEE_WALLET", vm.toString(FEE_WALLET));
        vm.setEnv("GAS_TREASURY", vm.toString(GAS_TREASURY));
        vm.setEnv("USDC", vm.toString(USDC));
        vm.setEnv("DEPLOYER_PK", vm.toString(PK));
    }

    function test_r3_deployScriptWiresEveryImmutable() public {
        address d = vm.addr(PK);
        uint64 n = vm.getNonce(d);
        new DeployV2().run();
        Reg reg = Reg(vm.computeCreateAddress(d, n));
        P2FluxPaymentsV2 pay = P2FluxPaymentsV2(vm.computeCreateAddress(d, n + 1));
        P2FluxRecurringV2 rec = P2FluxRecurringV2(vm.computeCreateAddress(d, n + 2));
        P2FluxSend send = P2FluxSend(vm.computeCreateAddress(d, n + 3));

        assertEq(reg.admin(), ADMIN);
        (uint16 b, uint16 pb, uint64 f) = reg.rates(Reg.Kind.OneTime);
        assertEq(abi.encode(b, pb, f), abi.encode(uint16(100), uint16(75), uint64(50_000)));
        (b, pb, f) = reg.rates(Reg.Kind.Recurring);
        assertEq(abi.encode(b, pb, f), abi.encode(uint16(150), uint16(125), uint64(50_000)));
        (b, pb, f) = reg.rates(Reg.Kind.Send);
        assertEq(abi.encode(b, pb, f), abi.encode(uint16(10), uint16(10), uint64(50_000)));

        assertEq(pay.supportedToken(), USDC);
        assertEq(pay.feeWallet(), FEE_WALLET);
        assertEq(pay.gasTreasury(), GAS_TREASURY);
        assertEq(pay.relayer(), RELAYER);
        assertEq(address(pay.registry()), address(reg));
        assertEq(pay.MAX_NETWORK_FEE_HARD_CAP(), 250_000);

        assertEq(rec.admin(), ADMIN);
        assertEq(rec.relayer(), RELAYER);
        assertEq(rec.feeWallet(), FEE_WALLET);
        assertEq(rec.gasTreasury(), GAS_TREASURY);
        assertEq(rec.supportedToken(), USDC);
        assertEq(address(rec.registry()), address(reg));
        assertEq(rec.GAS_REIMBURSEMENT_HARD_CAP(), 50_000);

        assertEq(send.supportedToken(), USDC);
        assertEq(send.feeWallet(), FEE_WALLET);
        assertEq(send.gasTreasury(), GAS_TREASURY);
        assertEq(send.relayer(), RELAYER);
        assertEq(address(send.registry()), address(reg));

        // the deployer keeps no role anywhere
        assertTrue(d != reg.admin() && d != rec.admin() && d != pay.relayer());
        _rejectsEachWrongWallet();
    }

    /// @dev Same test on purpose: vm.setEnv is process-wide, so a parallel test would race on it.
    function _rejectsEachWrongWallet() internal {
        string[5] memory keys = ["ADMIN", "RELAYER", "FEE_WALLET", "GAS_TREASURY", "USDC"];
        address[5] memory good = [ADMIN, RELAYER, FEE_WALLET, GAS_TREASURY, USDC];
        DeployV2 s = new DeployV2();
        for (uint256 i = 0; i < 5; i++) {
            // swap in a neighbour's (valid, pinned elsewhere) address: the classic mix-up
            vm.setEnv(keys[i], vm.toString(good[(i + 1) % 5]));
            vm.expectRevert();
            s.run();
            vm.setEnv(keys[i], vm.toString(good[i]));
        }
    }
}
