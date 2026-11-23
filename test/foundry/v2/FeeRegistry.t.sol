// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "./V2Helpers.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";

contract FeeRegistryTest is V2Test {
    P2FluxFeeRegistry.Kind internal constant ONE = P2FluxFeeRegistry.Kind.OneTime;
    P2FluxFeeRegistry.Kind internal constant REC = P2FluxFeeRegistry.Kind.Recurring;

    function setUp() public {
        _v2SetUp();
    }

    function _rate(uint256 bps, uint256 pbps, uint256 fixedFee) internal pure returns (P2FluxFeeRegistry.Rate memory) {
        return P2FluxFeeRegistry.Rate(uint16(bps), uint16(pbps), uint64(fixedFee));
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    // --- initial state ---

    function test_initialRates() public view {
        (uint256 bps, uint256 fixedFee) = registry.feeFor(ONE, makeAddrView("merchant"));
        assertEq(bps, 100);
        assertEq(fixedFee, 50_000);
        (bps,) = registry.feeFor(ONE, partner);
        assertEq(bps, 75);
        (bps,) = registry.feeFor(REC, makeAddrView("merchant"));
        assertEq(bps, 150);
        (bps,) = registry.feeFor(REC, partner);
        assertEq(bps, 125);
        (bps, fixedFee) = registry.feeFor(P2FluxFeeRegistry.Kind.Send, address(0));
        assertEq(bps, 10);
        assertEq(fixedFee, 50_000);
        assertEq(registry.DELAY(), 48 hours);
    }

    function makeAddrView(string memory name) internal pure returns (address) {
        return vm.addr(uint256(keccak256(abi.encodePacked(name))));
    }

    function test_constructor_guards() public {
        P2FluxFeeRegistry.Rate memory ok = _rate(100, 75, 50_000);
        vm.expectRevert(P2FluxFeeRegistry.ZeroAddress.selector);
        new P2FluxFeeRegistry(address(0), ok, ok, ok);
        vm.expectRevert(P2FluxFeeRegistry.RateAboveCap.selector);
        new P2FluxFeeRegistry(admin, _rate(201, 0, 0), ok, ok);
        vm.expectRevert(P2FluxFeeRegistry.RateAboveCap.selector);
        new P2FluxFeeRegistry(admin, ok, _rate(100, 101, 0), ok);
        vm.expectRevert(P2FluxFeeRegistry.RateAboveCap.selector);
        new P2FluxFeeRegistry(admin, ok, ok, _rate(0, 0, 200_001));
    }

    // --- rate timelock ---

    function test_rate_schedule_execute() public {
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(120, 90, 60_000));
        assertEq(registry.pendingRateEta(ONE), block.timestamp + 48 hours);
        (uint16 b, uint16 pb, uint64 f) = registry.pendingRates(ONE);
        assertEq(b, 120);
        assertEq(pb, 90);
        assertEq(f, 60_000);
        // still the old rate while pending
        (uint256 bps,) = registry.feeFor(ONE, address(1));
        assertEq(bps, 100);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(makeAddr("anyone"));
        registry.executeRate(ONE);
        (bps,) = registry.feeFor(ONE, address(1));
        assertEq(bps, 120);
        (bps,) = registry.feeFor(ONE, partner);
        assertEq(bps, 90);
        assertEq(registry.pendingRateEta(ONE), 0);
    }

    function test_rate_tooEarly() public {
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(120, 90, 60_000));
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(P2FluxFeeRegistry.TooEarly.selector);
        registry.executeRate(ONE);
    }

    function test_rate_lapsed() public {
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(120, 90, 60_000));
        vm.warp(block.timestamp + 48 hours + 7 days + 1);
        vm.expectRevert(P2FluxFeeRegistry.Lapsed.selector);
        registry.executeRate(ONE);
    }

    function test_rate_cancel() public {
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(120, 90, 60_000));
        vm.prank(admin);
        registry.cancelRate(ONE);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executeRate(ONE);
        (uint256 bps,) = registry.feeFor(ONE, address(1));
        assertEq(bps, 100);
    }

    function test_rate_cancelNothingPending() public {
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.cancelRate(ONE);
    }

    function test_rate_executeNothingPending() public {
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executeRate(REC);
    }

    function test_rate_rescheduleRestartsClock() public {
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(120, 90, 60_000));
        vm.warp(block.timestamp + 47 hours);
        vm.prank(admin);
        registry.scheduleRate(ONE, _rate(130, 90, 60_000));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(P2FluxFeeRegistry.TooEarly.selector);
        registry.executeRate(ONE);
    }

    function test_rate_kindsAreIndependent() public {
        _setRate(REC, 200, 200, 0);
        (uint256 bps, uint256 fixedFee) = registry.feeFor(ONE, address(1));
        assertEq(bps, 100);
        assertEq(fixedFee, 50_000);
    }

    function testFuzz_rate_onlyAdmin(address caller) public {
        vm.assume(caller != admin);
        vm.startPrank(caller);
        vm.expectRevert(P2FluxFeeRegistry.NotAdmin.selector);
        registry.scheduleRate(ONE, _rate(0, 0, 0));
        vm.expectRevert(P2FluxFeeRegistry.NotAdmin.selector);
        registry.cancelRate(ONE);
        vm.expectRevert(P2FluxFeeRegistry.NotAdmin.selector);
        registry.schedulePartners(_one(address(1)), true);
        vm.expectRevert(P2FluxFeeRegistry.NotAdmin.selector);
        registry.cancelPartner(address(1));
        vm.stopPrank();
    }

    /// Whatever the admin asks, nothing above the hard caps is ever accepted.
    function testFuzz_rate_capsHold(uint16 bps, uint16 pbps, uint64 fixedFee) public {
        bool ok = bps <= 200 && pbps <= bps && fixedFee <= 200_000;
        vm.prank(admin);
        if (!ok) vm.expectRevert(P2FluxFeeRegistry.RateAboveCap.selector);
        registry.scheduleRate(ONE, P2FluxFeeRegistry.Rate(bps, pbps, fixedFee));
        if (!ok) return;
        vm.warp(block.timestamp + 48 hours);
        registry.executeRate(ONE);
        (uint256 b, uint256 f) = registry.feeFor(ONE, address(1));
        assertLe(b, registry.MAX_BPS());
        assertLe(f, registry.MAX_FIXED_FEE());
    }

    // --- partner timelock ---

    function test_partner_scheduleExecute() public {
        address m = makeAddr("m");
        vm.prank(admin);
        registry.schedulePartners(_one(m), true);
        assertFalse(registry.isPartner(m));
        assertTrue(registry.pendingPartner(m));
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(P2FluxFeeRegistry.TooEarly.selector);
        registry.executePartners(_one(m));
        vm.warp(block.timestamp + 1);
        registry.executePartners(_one(m));
        assertTrue(registry.isPartner(m));
    }

    function test_partner_unlistIsTimelockedToo() public {
        vm.prank(admin);
        registry.schedulePartners(_one(partner), false);
        assertTrue(registry.isPartner(partner), "still a partner while pending");
        vm.warp(block.timestamp + 48 hours);
        registry.executePartners(_one(partner));
        assertFalse(registry.isPartner(partner));
    }

    function test_partner_cancel() public {
        address m = makeAddr("m");
        vm.prank(admin);
        registry.schedulePartners(_one(m), true);
        vm.prank(admin);
        registry.cancelPartner(m);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executePartners(_one(m));
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.cancelPartner(m);
    }

    function test_partner_lapsed() public {
        address m = makeAddr("m");
        vm.prank(admin);
        registry.schedulePartners(_one(m), true);
        vm.warp(block.timestamp + 48 hours + 7 days + 1);
        vm.expectRevert(P2FluxFeeRegistry.Lapsed.selector);
        registry.executePartners(_one(m));
    }

    function test_partner_zeroAddressRefused() public {
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.ZeroAddress.selector);
        registry.schedulePartners(_one(address(0)), true);
    }

    function test_partner_batch() public {
        address[] memory list = new address[](3);
        list[0] = makeAddr("a");
        list[1] = makeAddr("b");
        list[2] = makeAddr("c");
        vm.prank(admin);
        registry.schedulePartners(list, true);
        vm.warp(block.timestamp + 48 hours);
        registry.executePartners(list);
        for (uint256 i; i < 3; i++) {
            assertTrue(registry.isPartner(list[i]));
        }
    }
}
