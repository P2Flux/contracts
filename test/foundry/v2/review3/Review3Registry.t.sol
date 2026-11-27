// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";

/// @notice Review 3: the registry timelock against a property that does not mirror the code:
///         "the effective value only ever changes to the LAST scheduled value, never sooner than
///         48 h after that schedule call, and never after it was cancelled".
contract Review3RegistryTest is Test {
    Reg internal reg;
    address internal admin = makeAddr("r3-admin");
    address internal m = makeAddr("r3-m");

    function setUp() public {
        vm.warp(1_700_000_000);
        reg = new Reg(admin, Reg.Rate(100, 75, 50_000), Reg.Rate(150, 125, 50_000), Reg.Rate(10, 10, 50_000));
    }

    function _eff() internal view returns (bytes32) {
        (uint16 b, uint16 pb, uint64 f) = reg.rates(Reg.Kind.OneTime);
        return keccak256(abi.encode(b, pb, f, reg.isPartner(m)));
    }

    bytes32 schedR;
    uint256 schedRAt;
    bool liveR;
    bool schedP;
    uint256 schedPAt;
    bool liveP;
    bytes32 prevR;
    bool prevP;

    function _rateHash() internal view returns (bytes32) {
        (uint16 b, uint16 pb, uint64 f) = reg.rates(Reg.Kind.OneTime);
        assertLe(b, 200);
        assertLe(pb, b);
        assertLe(f, 200_000);
        return keccak256(abi.encode(b, pb, f));
    }

    function _op(uint256 x) internal {
        uint256 op = x % 5;
        vm.startPrank(admin);
        if (op == 0) {
            uint16 b = uint16((x >> 8) % 201);
            uint16 pb = uint16((x >> 24) % (uint256(b) + 1));
            uint64 f = uint64((x >> 40) % 200_001);
            reg.scheduleRate(Reg.Kind.OneTime, Reg.Rate(b, pb, f));
            schedR = keccak256(abi.encode(b, pb, f));
            schedRAt = block.timestamp;
            liveR = true;
        } else if (op == 1) {
            try reg.cancelRate(Reg.Kind.OneTime) {
                assertTrue(liveR && block.timestamp < schedRAt + 48 hours, "cancel of nothing pending");
                liveR = false;
            } catch {}
        } else if (op == 2) {
            address[] memory l = new address[](1);
            l[0] = m;
            schedP = (x >> 8) & 1 == 1;
            reg.schedulePartners(l, schedP);
            schedPAt = block.timestamp;
            liveP = true;
        } else if (op == 3) {
            try reg.cancelPartner(m) {
                assertTrue(liveP && block.timestamp < schedPAt + 48 hours, "cancel of nothing pending");
                liveP = false;
            } catch {}
        }
        vm.stopPrank();
    }

    function testFuzz_r3_timelockNeverShortened(uint256[32] memory seeds) public {
        prevR = _rateHash();
        prevP = reg.isPartner(m);
        for (uint256 i = 0; i < seeds.length; i++) {
            uint256 x = seeds[i];
            _op(x);
            // an admin call never changes what is effective in the same block
            assertEq(_rateHash(), prevR, "admin call changed the rate at once");
            assertEq(reg.isPartner(m), prevP, "admin call changed the partner flag at once");

            // time passes: sometimes exactly to the edge, sometimes one second short
            uint256 k = (x >> 100) % 4;
            vm.warp(block.timestamp + (k == 0 ? 48 hours : k == 1 ? 48 hours - 1 : (x >> 110) % 100 hours));

            bytes32 nowR = _rateHash();
            if (nowR != prevR) {
                assertTrue(liveR && block.timestamp >= schedRAt + 48 hours && nowR == schedR, "rate changed early");
            }
            if (liveR && block.timestamp >= schedRAt + 48 hours) assertEq(nowR, schedR, "matured rate not effective");
            bool nowP = reg.isPartner(m);
            if (nowP != prevP) {
                assertTrue(liveP && block.timestamp >= schedPAt + 48 hours && nowP == schedP, "partner changed early");
            }
            if (liveP && block.timestamp >= schedPAt + 48 hours) assertEq(nowP, schedP, "matured flag not effective");
            prevR = nowR;
            prevP = nowP;
        }
    }

    function test_r3_capsAndRoles() public {
        vm.startPrank(admin);
        vm.expectRevert(Reg.RateAboveCap.selector);
        reg.scheduleRate(Reg.Kind.OneTime, Reg.Rate(201, 0, 0));
        vm.expectRevert(Reg.RateAboveCap.selector);
        reg.scheduleRate(Reg.Kind.OneTime, Reg.Rate(100, 101, 0));
        vm.expectRevert(Reg.RateAboveCap.selector);
        reg.scheduleRate(Reg.Kind.OneTime, Reg.Rate(100, 100, 200_001));
        vm.stopPrank();
        address[] memory l = new address[](1);
        l[0] = m;
        vm.expectRevert(Reg.NotAdmin.selector);
        reg.scheduleRate(Reg.Kind.OneTime, Reg.Rate(1, 1, 1));
        vm.expectRevert(Reg.NotAdmin.selector);
        reg.cancelRate(Reg.Kind.OneTime);
        vm.expectRevert(Reg.NotAdmin.selector);
        reg.schedulePartners(l, true);
        vm.expectRevert(Reg.NotAdmin.selector);
        reg.cancelPartner(m);
        vm.expectRevert(Reg.RateAboveCap.selector);
        new Reg(admin, Reg.Rate(201, 0, 0), Reg.Rate(0, 0, 0), Reg.Rate(0, 0, 0));
        // invalid kind (3) is rejected by the ABI decoder
        (bool ok,) = address(reg).staticcall(abi.encodeWithSignature("rates(uint8)", uint8(3)));
        assertFalse(ok);
    }
}
