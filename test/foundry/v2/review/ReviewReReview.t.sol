// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReviewBase} from "./ReviewBase.sol";
import {MockFiatToken} from "../../../../contracts/test/MockTokens.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxV2Base} from "../../../../contracts/v2/P2FluxV2Base.sol";
import {P2FluxPaymentsV2} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxPaymentsV2 as Sponsored} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice Registry stand-in that passes the constructor sanity read, then returns anything.
contract FuzzRegistry {
    uint16 public constant MAX_BPS = 200;
    uint64 public constant MAX_FIXED_FEE = 0.2e6;
    uint256 public constant DELAY = 48 hours;
    uint16 b;
    uint16 pb;
    uint64 f;
    bool p;

    function set(uint16 _b, uint16 _pb, uint64 _f, bool _p) external {
        (b, pb, f, p) = (_b, _pb, _f, _p);
    }

    function rates(Reg.Kind) external view returns (uint16, uint16, uint64) {
        return (b, pb, f);
    }

    function isPartner(address) external view returns (bool) {
        return p;
    }
}

/// @notice Re-review (2026-11-24, commits a33faac + 2dadf12): the auto-effective timelock and the
///         fixes for R-02 / R-03 / R-04 / R-07b. `test_RR*` = checked, no issue; `test_N*` = new
///         observation (passes by showing the behaviour).
contract ReviewReReviewTest is ReviewBase {
    function setUp() public {
        _reviewSetUp();
        token.mint(payer, 1e15);
        vm.startPrank(payer);
        token.approve(address(recurring), type(uint256).max);
        token.approve(address(splitter), type(uint256).max);
        token.approve(address(sender), type(uint256).max);
        vm.stopPrank();
    }

    function _sched(Reg.Kind k, uint16 b, uint16 pb, uint64 f) internal {
        vm.prank(admin);
        registry.scheduleRate(k, Reg.Rate(b, pb, f));
    }

    // --- 1. timelock boundaries and view consistency ---------------------------------------------

    /// A rate change and a partner unlisting scheduled in the same block switch together, exactly
    /// at ETA, in every one of the four contracts (and not one second earlier).
    function test_RR1_sameBlockRateAndPartnerAllContractsSwitchAtEta() public {
        uint256 t0 = block.timestamp;
        _sched(Reg.Kind.OneTime, 200, 150, 0.2e6);
        _sched(Reg.Kind.Recurring, 200, 150, 0.2e6);
        _sched(Reg.Kind.Send, 20, 20, 0.1e6);
        vm.prank(admin);
        registry.schedulePartners(_one(partner), false);
        uint256 eta = t0 + 48 hours;

        vm.warp(eta - 1);
        _assertAll(partner, 75, 0.05e6, 125, 10, 0.05e6);
        vm.warp(eta);
        _assertAll(partner, 200, 0.2e6, 200, 20, 0.1e6); // partner now unlisted -> standard rates
    }

    function _assertAll(address r, uint256 oneBps, uint256 oneFixed, uint256 recBps, uint256 sendBps, uint256 sendFixed)
        internal
    {
        // Send
        (uint256 fee, uint256 fx) = sender.quote(100e6);
        assertEq(fee, 100e6 * sendBps / 10_000, "send bps");
        assertEq(fx, sendFixed, "send fixed");
        // Sponsored (closed form from the expected numbers)
        assertEq(sponsored.minimumAmount(r), oneFixed * 10_000 / (10_000 - oneBps) + 1, "sponsored min");
        // Splitter: a real payment in this block
        uint256 before = token.balanceOf(feeWallet);
        vm.prank(payer);
        splitter.pay(address(token), r, 100e6, keccak256(abi.encode(block.timestamp)));
        assertEq(token.balanceOf(feeWallet) - before, 100e6 * oneBps / 10_000, "splitter fee");
        // Recurring: a real relayer charge in this block
        Recurring.RecurringAuthorization memory a = _auth(r, 10e6, 0);
        a.salt = keccak256(abi.encode(block.timestamp));
        before = token.balanceOf(feeWallet);
        vm.prank(relayer);
        recurring.charge(a, _sigRec(a), 0);
        assertEq(token.balanceOf(feeWallet) - before, 10e6 * recBps / 10_000, "recurring fee");
    }

    function test_RR2_cancelOnlyBeforeEffect() public {
        uint256 t0 = block.timestamp;
        _sched(Reg.Kind.OneTime, 150, 100, 0.1e6);
        vm.warp(t0 + 48 hours); // effective now
        vm.prank(admin);
        vm.expectRevert(Reg.NothingPending.selector);
        registry.cancelRate(Reg.Kind.OneTime);
        (uint16 b,,) = registry.rates(Reg.Kind.OneTime);
        assertEq(b, 150);

        // Pending at eta-1 can be cancelled; the old value stays, never the pre-previous one.
        _sched(Reg.Kind.OneTime, 200, 200, 0.2e6);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(admin);
        registry.cancelRate(Reg.Kind.OneTime);
        vm.warp(block.timestamp + 365 days);
        (b,,) = registry.rates(Reg.Kind.OneTime);
        assertEq(b, 150, "cancelled change never applies; effective one survives the cancel");
        (,,, uint256 at) = registry.pendingRate(Reg.Kind.OneTime);
        assertEq(at, 0);
    }

    /// Overwrite while pending: the first value never applies, the second needs its own 48 h.
    function test_RR3_overwriteWhilePending() public {
        uint256 t0 = block.timestamp;
        _sched(Reg.Kind.Recurring, 200, 200, 0.2e6);
        vm.warp(t0 + 47 hours);
        _sched(Reg.Kind.Recurring, 120, 100, 0.03e6);
        vm.warp(t0 + 48 hours);
        (uint16 b,,) = registry.rates(Reg.Kind.Recurring);
        assertEq(b, 150, "neither applies yet");
        vm.warp(t0 + 95 hours - 1);
        (b,,) = registry.rates(Reg.Kind.Recurring);
        assertEq(b, 150);
        vm.warp(t0 + 95 hours);
        (b,,) = registry.rates(Reg.Kind.Recurring);
        assertEq(b, 120);
        // A new schedule AFTER effect rolls the effective value into `current` first.
        _sched(Reg.Kind.Recurring, 180, 180, 0);
        (b,,) = registry.rates(Reg.Kind.Recurring);
        assertEq(b, 120, "effective value kept while the next one waits");
    }

    /// Partners: duplicates in one batch, list-then-unlist while pending, cancel after effect.
    function test_RR4_partnerEdges() public {
        address m = makeAddr("m");
        address[] memory dup = new address[](2);
        dup[0] = m;
        dup[1] = m;
        vm.prank(admin);
        registry.schedulePartners(dup, true);
        vm.warp(block.timestamp + 47 hours);
        vm.prank(admin);
        registry.schedulePartners(_one(m), false); // change of mind while pending
        vm.warp(block.timestamp + 1 hours);
        assertFalse(registry.isPartner(m), "first schedule never applied");
        vm.warp(block.timestamp + 47 hours);
        assertFalse(registry.isPartner(m));
        vm.prank(admin);
        vm.expectRevert(Reg.NothingPending.selector);
        registry.cancelPartner(m);
        // `partner` (listed in setUp) stays listed across an unrelated schedule/cancel.
        vm.prank(admin);
        registry.schedulePartners(_one(partner), false);
        vm.prank(admin);
        registry.cancelPartner(partner);
        vm.warp(block.timestamp + 10 days);
        assertTrue(registry.isPartner(partner));
    }

    // --- 2. R-02: caps re-checked in the payment contracts ---------------------------------------

    /// Whatever a registry returns, a payment either reverts RateAboveCap or stays inside the caps,
    /// and minimumAmount never divides by zero.
    function testFuzz_RR5_rogueRegistryAlwaysCapped(uint16 b, uint16 pb, uint64 f, bool isP, uint256 amount) public {
        FuzzRegistry fr = new FuzzRegistry();
        fr.set(b, pb, f, isP);
        Sponsored sp = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(fr), NETWORK_CAP);
        bool legal = b <= 200 && pb <= b && f <= 0.2e6;
        if (!legal) {
            vm.expectRevert(P2FluxV2Base.RateAboveCap.selector);
            sp.minimumAmount(merchant);
            return;
        }
        uint256 m = sp.minimumAmount(merchant);
        amount = bound(amount, m, 1e15);
        Sponsored.SponsoredPayment memory p =
            Sponsored.SponsoredPayment(payer, merchant, amount, "x", 0, block.timestamp + 60);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_KEY, payer, address(sp), amount, p.validBefore, sp.authorizationNonce(p));
        uint256 before = token.balanceOf(merchant);
        vm.prank(relayer);
        sp.payWithAuthorization(p, v, r, s);
        assertGe(token.balanceOf(merchant) - before + amount * 200 / 10_000 + 0.2e6, amount);
    }

    // --- 3. R-04: fixed fee only when the relayer executes -----------------------------------------

    function test_RR6_fixedFeeOnlyForRelayerEvenWithZeroReimbursement() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0.05e6);
        bytes memory sig = _sigRec(a);
        uint256 g0 = token.balanceOf(gasTreasury);
        vm.prank(relayer);
        recurring.charge(a, sig, 0); // relayer, no reimbursement: fixed fee still due
        assertEq(token.balanceOf(gasTreasury) - g0, 0.05e6);
        // A non-relayer passing a reimbursement gets neither reimbursement nor fixed fee.
        vm.warp(block.timestamp + 30 days);
        g0 = token.balanceOf(gasTreasury);
        vm.prank(attacker);
        recurring.charge(a, sig, 0.05e6);
        assertEq(token.balanceOf(gasTreasury) - g0, 0);
    }

    /// N-01 (Info, accepted trade-off): anyone may front-run the relayer each period. The charge
    /// then skips the 0.05 fixed fee, and the relayer's own transaction reverts (wasted gas).
    function test_N01_thirdPartyFrontRunsRelayerSkipsFixedFee() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0.05e6);
        bytes memory sig = _sigRec(a);
        vm.prank(attacker); // e.g. the merchant's own bot
        recurring.charge(a, sig, 0);
        assertEq(token.balanceOf(gasTreasury), 0, "P2Flux gets no fixed fee");
        assertEq(token.balanceOf(merchant), 10e6 - 0.15e6);
        vm.prank(relayer);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0.05e6);
    }

    /// N-02 (Info): between fee and fee + fixed, a subscription is chargeable by anyone but not by
    /// the relayer, and isChargeable (relayer view) says false. Consistent for the relayer; noted
    /// so the scheduler does not treat "false" as "dead".
    function test_N02_isChargeableIsRelayerView() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 0.05e6, 0);
        bytes memory sig = _sigRec(a);
        assertFalse(recurring.isChargeable(a));
        vm.prank(relayer);
        vm.expectRevert(Recurring.AmountTooSmall.selector);
        recurring.charge(a, sig, 0);
        vm.prank(attacker);
        recurring.charge(a, sig, 0); // 0.05 - 1.5% fee, no fixed fee
        assertEq(token.balanceOf(merchant), 0.05e6 - 750);
    }

    // --- 4. Send without the gas field --------------------------------------------------------------

    /// A signature made over the OLD layout (networkFee in the nonce and in the total) never settles.
    function test_RR7_oldSendLayoutSignatureRefused() public {
        P2FluxSend.RelayedSend memory s = _rs(merchant, 10e6, bytes32("old"));
        (uint256 fee, uint256 fx) = sender.quote(s.amount);
        bytes32 oldNonce = keccak256(
            abi.encode(
                sender.SEND_DOMAIN(),
                block.chainid,
                address(sender),
                address(token),
                s.from,
                s.to,
                s.amount,
                s.ref,
                uint256(0),
                s.validBefore
            )
        );
        assertTrue(oldNonce != sender.authorizationNonce(s));
        (uint8 v, bytes32 r, bytes32 sig) =
            _signReceive(PAYER_KEY, payer, address(sender), s.amount + fee + fx, s.validBefore, oldNonce);
        vm.prank(relayer);
        vm.expectRevert(bytes("invalid authorization signature"));
        sender.sendWithAuthorization(s, v, r, sig);
        // The correct new-layout signature settles exactly once.
        (v, r, sig) = _signRs(s, s.amount + fee + fx);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        vm.prank(relayer);
        vm.expectRevert();
        sender.sendWithAuthorization(s, v, r, sig);
        assertEq(token.balanceOf(merchant), 10e6);
    }

    // --- 5. R-03: isChargeable == relayer charge succeeds, under rate changes ----------------------

    function testFuzz_RR8_isChargeableMatchesRelayerCharge(
        uint256 amount,
        uint48 period,
        uint48 startOff,
        uint48 endOff,
        uint256 jump,
        uint16 b,
        uint64 f,
        bool asPartner,
        bool chargeFirst,
        bool revokeIt
    ) public {
        address r = asPartner ? partner : merchant;
        amount = bound(amount, 1, 1e9);
        period = uint48(bound(period, 0, 60 days));
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            payer,
            r,
            address(token),
            amount,
            period,
            uint48(block.timestamp + bound(startOff, 0, 10 days)),
            0,
            bytes32(uint256(9)),
            0
        );
        if (endOff % 3 == 0) a.end = uint48(a.start + bound(endOff, 0, 90 days));
        bytes memory sig = _sigRec(a);
        b = uint16(bound(b, 0, 200));
        _sched(Reg.Kind.Recurring, b, b, uint64(bound(f, 0, 0.2e6)));
        if (chargeFirst && recurring.isChargeable(a)) {
            vm.prank(relayer);
            recurring.charge(a, sig, 0);
        }
        vm.warp(block.timestamp + bound(jump, 0, 100 days)); // may cross the rate ETA
        if (revokeIt) {
            vm.prank(payer);
            recurring.revoke(a);
        }
        bool view_ = recurring.isChargeable(a);
        vm.prank(relayer);
        (bool ok,) = address(recurring).call(abi.encodeCall(Recurring.charge, (a, sig, 0)));
        assertEq(view_, ok, "isChargeable disagrees with the relayer charge");
    }
}
