// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./ReviewBase.sol";
import {MockUSDC, ReentrantToken, IRecurringLike} from "../../../../contracts/test/MockTokens.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSplitterV2} from "../../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice A 6-decimal token that re-enters the splitter with the SAME payment terms mid-transfer.
contract ReenterPayToken is MockUSDC {
    P2FluxSplitterV2 public target;
    address public recipient;
    bool public armed;

    function arm(P2FluxSplitterV2 t, address r) external {
        target = t;
        recipient = r;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (armed) {
            armed = false;
            target.pay(address(this), recipient, 100e6, bytes32("same"));
        }
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance");
        allowance[from][msg.sender] = allowed - value;
        return _move(from, to, value);
    }
}

/// @notice "Checked, no issue" - attacks that were tried and failed, each kept as a regression test.
contract ReviewChecksTest is ReviewBase {
    function setUp() public {
        _reviewSetUp();
    }

    // --- fee math against an independent model -------------------------------------------------

    /// minimumAmount is the exact boundary at ANY rate the caps allow (brute-force check of a, a-1).
    function testFuzz_C01_minimumAmountExactAtAnyRate(uint16 bps, uint16 pbps, uint64 fixedFee, bool asPartner) public {
        bps = uint16(bound(bps, 0, 200));
        pbps = uint16(bound(pbps, 0, bps));
        fixedFee = uint64(bound(fixedFee, 0, 0.2e6));
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, pbps, fixedFee);
        address r = asPartner ? partner : merchant;
        uint256 b = asPartner ? pbps : bps;
        uint256 m = sponsored.minimumAmount(r);
        assertGt(m - (m * b) / 10_000, fixedFee, "minimum leaves merchant > 0");
        assertLe((m - 1) - ((m - 1) * b) / 10_000, fixedFee, "minimum - 1 would not");
    }

    /// Whatever legal rate is live, a merchant never gets less than amount - 2% - 0.20 on any
    /// payment path, and P2Flux's percentage cut is floor(amount * bps / 1e4) exactly.
    function testFuzz_C02_capsBoundMerchantOnEveryPath(uint256 amount, uint16 bps, uint64 fixedFee, uint256 nf) public {
        bps = uint16(bound(bps, 0, 200));
        fixedFee = uint64(bound(fixedFee, 0, 0.2e6));
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, bps, fixedFee);
        amount = bound(amount, 0.3e6, 1e15);
        nf = bound(nf, 0, NETWORK_CAP);
        uint256 worst = amount - (amount * 200) / 10_000 - 0.2e6;

        Sponsored.SponsoredPayment memory p = _sp(merchant, amount, bytes32("c02"), nf);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        token.mint(payer, amount + nf);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
        assertGe(token.balanceOf(merchant), worst);
        assertEq(token.balanceOf(payer), 0, "buyer debit is amount + signed networkFee, nothing else");
        assertLe(token.balanceOf(feeWallet) * 10_000, amount * bps);
        assertGt((token.balanceOf(feeWallet) + 1) * 10_000, amount * bps);
    }

    // --- partner tier ---------------------------------------------------------------------------

    function testFuzz_C03_partnerAboveStandardRefused(uint16 bps, uint16 pbps) public {
        bps = uint16(bound(bps, 0, 200));
        pbps = uint16(bound(pbps, uint256(bps) + 1, type(uint16).max));
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.RateAboveCap.selector);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.OneTime, P2FluxFeeRegistry.Rate(bps, pbps, 0));
    }

    function test_C04_merchantCannotListItself() public {
        vm.prank(merchant);
        vm.expectRevert(P2FluxFeeRegistry.NotAdmin.selector);
        registry.schedulePartners(_one(merchant), true);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executePartners(_one(merchant));
        assertFalse(registry.isPartner(merchant));
    }

    /// Send has no partner tier even if both ends are listed and the Send partner rate is lower.
    function test_C05_sendNeverPartnerRate() public {
        _setRate(P2FluxFeeRegistry.Kind.Send, 10, 0, 50_000);
        _listPartner(payer, true);
        _listPartner(merchant, true);
        (uint256 fee,) = sender.quote(100e6);
        assertEq(fee, 0.1e6);
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.ZeroAddress.selector);
        registry.schedulePartners(_one(address(0)), true);
    }

    // --- timelock -------------------------------------------------------------------------------

    function testFuzz_C06_timelockWindowExact(uint256 t) public {
        t = bound(t, 0, 20 days);
        uint256 t0 = block.timestamp;
        vm.prank(admin);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.OneTime, P2FluxFeeRegistry.Rate(200, 200, 0.2e6));
        vm.warp(t0 + t);
        bool ok = t >= 48 hours && t <= 48 hours + 7 days;
        if (!ok) vm.expectRevert();
        registry.executeRate(P2FluxFeeRegistry.Kind.OneTime);
        (uint16 b,,) = registry.rates(P2FluxFeeRegistry.Kind.OneTime);
        assertEq(b, ok ? 200 : 100);
    }

    function test_C06b_cancelAndRescheduleRestartClock() public {
        uint256 t0 = block.timestamp;
        vm.startPrank(admin);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.OneTime, P2FluxFeeRegistry.Rate(200, 200, 0));
        vm.warp(t0 + 47 hours);
        registry.cancelRate(P2FluxFeeRegistry.Kind.OneTime);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.OneTime, P2FluxFeeRegistry.Rate(150, 150, 0));
        vm.stopPrank();
        vm.warp(t0 + 49 hours); // due for the FIRST schedule, not for the second
        vm.expectRevert(P2FluxFeeRegistry.TooEarly.selector);
        registry.executeRate(P2FluxFeeRegistry.Kind.OneTime);
        // Lapsed changes stay dead: no execute after the grace, even by admin.
        vm.warp(t0 + 47 hours + 48 hours + 7 days + 1);
        vm.prank(admin);
        vm.expectRevert(P2FluxFeeRegistry.Lapsed.selector);
        registry.executeRate(P2FluxFeeRegistry.Kind.OneTime);
    }

    function test_C06c_partnerUnlistTimelockedAndRaceFree() public {
        // Admin schedules unlist, then cancels; a stranger cannot execute the cancelled change later.
        vm.prank(admin);
        registry.schedulePartners(_one(partner), false);
        vm.prank(admin);
        registry.cancelPartner(partner);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executePartners(_one(partner));
        assertTrue(registry.isPartner(partner));
    }

    // --- signature replay -----------------------------------------------------------------------

    /// A buyer's sponsored authorization cannot be spent by another contract or another deployment.
    function test_C07_sponsoredAuthNotReplayableElsewhere() public {
        Sponsored.SponsoredPayment memory p = _sp(merchant, 10e6, bytes32("r"), 0);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        token.mint(payer, 20e6);

        Sponsored other = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        vm.prank(relayer);
        vm.expectRevert();
        other.payWithAuthorization(p, v, r, s);

        // Same struct shape on Send: different domain tag, different `to`.
        P2FluxSend.RelayedSend memory rs = P2FluxSend.RelayedSend(payer, merchant, 10e6, p.ref, 0, p.validBefore);
        vm.prank(relayer);
        vm.expectRevert();
        sender.sendWithAuthorization(rs, v, r, s);

        // Another chain id: nonce changes, token signature fails.
        uint256 id = block.chainid;
        vm.chainId(id + 1);
        assertTrue(sponsored.authorizationNonce(p) != keccak256("x"));
        vm.prank(relayer);
        vm.expectRevert();
        sponsored.payWithAuthorization(p, v, r, s);
        vm.chainId(id);

        // A stranger cannot use it directly on the token either (receive requires to == caller).
        bytes32 n = sponsored.authorizationNonce(p);
        vm.prank(attacker);
        vm.expectRevert(bytes("caller must be the payee"));
        token.receiveWithAuthorization(payer, address(sponsored), 10e6, 0, p.validBefore, n, v, r, s);

        // The original still works exactly once.
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
        vm.prank(relayer);
        vm.expectRevert();
        sponsored.payWithAuthorization(p, v, r, s);
    }

    function test_C08_recurringSignatureBoundToChain() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        bytes memory sig = _sigRec(a);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);
    }

    // --- recurring period math ------------------------------------------------------------------

    function test_C09_recurringNoEarlyNoDoubleNoBackfill() public {
        token.mint(payer, 1000e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        a.start = uint48(block.timestamp + 1 days);
        a.end = uint48(a.start + 90 days);
        bytes memory sig = _sigRec(a);

        vm.expectRevert(Recurring.NotStarted.selector);
        recurring.charge(a, sig, 0);

        vm.warp(a.start);
        recurring.charge(a, sig, 0);
        vm.warp(a.start + 30 days - 1);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);

        // Skip to period 2 directly: only ONE charge possible there, period 1 is not back-charged.
        vm.warp(a.start + 60 days);
        recurring.charge(a, sig, 0);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
        assertEq(token.balanceOf(payer), 1000e6 - 20e6);

        vm.warp(a.end);
        vm.expectRevert(Recurring.Expired.selector);
        recurring.charge(a, sig, 0);
    }

    function test_C09b_revokeRace() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        bytes memory sig = _sigRec(a);
        vm.prank(attacker);
        vm.expectRevert(Recurring.NotPayer.selector);
        recurring.revoke(a);
        vm.prank(payer);
        recurring.revoke(a);
        vm.expectRevert(Recurring.Revoked.selector);
        recurring.charge(a, sig, 0);
    }

    // --- Send -----------------------------------------------------------------------------------

    function test_C11_sendEdges() public {
        token.mint(payer, 1000e6);
        vm.startPrank(payer);
        token.approve(address(sender), type(uint256).max);
        // receiver == sender: exact amount back, only the fee leaves.
        sender.send(payer, 100e6, 0.1e6, bytes32("self"));
        assertEq(token.balanceOf(payer), 1000e6 - 0.1e6);
        vm.expectRevert(P2FluxSend.FeeAboveMax.selector);
        sender.send(merchant, 100e6, 0.1e6 - 1, bytes32("x"));
        vm.expectRevert(P2FluxSend.AmountTooSmall.selector);
        sender.send(merchant, 1e6 - 1, 1e6, bytes32("x"));
        vm.stopPrank();

        // Relayed: a signature over total +/- 1 never settles.
        P2FluxSend.RelayedSend memory s = _rs(merchant, 10e6, bytes32("t"), 0);
        uint256 total = _relayedTotal(s);
        for (uint256 i; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 sig) = _signRs(s, i == 0 ? total + 1 : total - 1);
            vm.prank(relayer);
            vm.expectRevert();
            sender.sendWithAuthorization(s, v, r, sig);
        }
    }

    /// The allowance left over by sendWithPermit (maxFee - fee) can only ever be used by its owner.
    function test_C12_leftoverPermitAllowanceNotStealable() public {
        token.mint(payer, 200e6);
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(PAYER_KEY, payer, address(sender), 100e6 + 5e6, block.timestamp + 1);
        // Attacker front-runs the permit itself: payer's call still goes through.
        token.permit(payer, address(sender), 100e6 + 5e6, block.timestamp + 1, v, r, s);
        vm.prank(payer);
        sender.sendWithPermit(merchant, 100e6, 5e6, bytes32("p"), block.timestamp + 1, v, r, s);
        assertEq(token.allowance(payer, address(sender)), 5e6 - 0.1e6, "leftover");
        vm.prank(attacker);
        vm.expectRevert();
        sender.send(attacker, 1e6, 1e6, bytes32("steal")); // spends attacker's own (zero) allowance
        assertEq(token.balanceOf(payer), 200e6 - 100.1e6);
    }

    // --- reentrancy through the token -------------------------------------------------------------

    function test_C14_reentrancyThroughToken() public {
        ReenterPayToken t = new ReenterPayToken();
        P2FluxSplitterV2 s2 = new P2FluxSplitterV2(address(t), feeWallet, address(registry));
        t.mint(payer, 300e6);
        vm.prank(payer);
        t.approve(address(s2), type(uint256).max);
        t.arm(s2, merchant);
        // The inner call hits the replay table the outer call already wrote (effects before interactions).
        bytes32 id = s2.paymentId(address(t), merchant, 100e6, bytes32("same"));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(P2FluxSplitterV2.PaymentAlreadyProcessed.selector, id));
        s2.pay(address(t), merchant, 100e6, bytes32("same"));

        ReentrantToken rt = new ReentrantToken();
        Recurring r2 = new Recurring(admin, relayer, feeWallet, gasTreasury, address(rt), address(registry), GAS_CAP);
        rt.mint(payer, 100e6);
        vm.prank(payer);
        rt.approve(address(r2), type(uint256).max);
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            payer, merchant, address(rt), 10e6, 30 days, uint48(block.timestamp), 0, bytes32(0), 0
        );
        bytes memory sig = _signDigest(PAYER_KEY, r2.subscriptionId(a));
        rt.arm(IRecurringLike(address(r2)), abi.decode(abi.encode(a), (IRecurringLike.RecurringAuthorization)), sig);
        vm.expectRevert();
        r2.charge(a, sig, 0);
        assertEq(rt.balanceOf(payer), 100e6, "nothing moved");
    }

    // --- registry swap / constructor --------------------------------------------------------------

    function test_C15_registryAndWalletsImmutable() public view {
        assertEq(address(splitter.registry()), address(registry));
        assertEq(address(sponsored.registry()), address(registry));
        assertEq(address(recurring.registry()), address(registry));
        assertEq(address(sender.registry()), address(registry));
        assertEq(registry.admin(), admin);
        // Immutables live in bytecode: storage slot 0..n hold only mappings / the recurring relayer.
    }
}
