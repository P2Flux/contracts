// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ReviewBase} from "./ReviewBase.sol";
import {MockUSDC} from "../../../../contracts/test/MockTokens.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2 as Payments} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxSplitter} from "../../../../contracts/P2FluxSplitter.sol";

/// @notice 6-decimal token that re-enters the payments contract during transferFrom.
contract ReenterPaymentsToken is MockUSDC {
    Payments public target;
    bool public armed;

    function arm(Payments t) external {
        target = t;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (armed) {
            armed = false;
            // Different order terms, so only the guard (not the replay table) can stop it.
            target.pay(address(this), to, 1e6, bytes32("inner"));
        }
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "allowance");
        allowance[from][msg.sender] = allowed - value;
        return _move(from, to, value);
    }
}

/// @notice Review of P2FluxPaymentsV2 (commit 6144890): two entrances, one replay table.
///         test_U*_ = observation PoC (passes by showing the behaviour); test_UC*_ = checked, no issue.
contract ReviewUnifiedTest is ReviewBase {
    Payments internal pm;

    function setUp() public {
        _reviewSetUp();
        pm = sponsored;
        token.mint(payer, 1e12);
        vm.prank(payer);
        token.approve(address(pm), type(uint256).max);
    }

    function _sponsor(address r, uint256 amount, bytes32 ref, uint256 nf) internal returns (bool ok) {
        Payments.SponsoredPayment memory p = _sp(r, amount, ref, nf);
        (uint8 v, bytes32 rr, bytes32 s) = _signSp(p);
        vm.prank(relayer);
        (ok,) = address(pm).call(abi.encodeCall(Payments.payWithAuthorization, (p, v, rr, s)));
    }

    // ---------------------------------------------------------------------------------------------
    // U-01 (Medium for the API / indexer; contract behaves as designed): decision 1 means a `ref` is
    // NOT unique on chain. The same ref settles again with another amount (or recipient), through
    // either entrance, and every settlement emits an event carrying that ref.
    // ---------------------------------------------------------------------------------------------

    /// A buyer "pays" their own 100 USDC order with 1 base unit: a valid Paid(ref = order) event.
    function test_U01_underpaymentWithOrderRefEmitsPaid() public {
        bytes32 ref = bytes32("order-77");
        vm.recordLogs();
        vm.prank(payer);
        pm.pay(address(token), merchant, 1, ref);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == Payments.Paid.selector && logs[i].topics[1] == ref) seen = true;
        }
        assertTrue(seen, "Paid event with the order's ref");
        assertFalse(pm.isPaymentProcessed(address(token), merchant, 100e6, ref), "the real order is NOT paid");
        assertEq(token.balanceOf(merchant), 1, "merchant got 1 base unit");
    }

    /// Same ref, both entrances, different amounts (e.g. a re-quoted price): both settle.
    function test_U01b_sameRefDifferentAmountSettlesTwiceAcrossEntrances() public {
        bytes32 ref = bytes32("order-78");
        vm.prank(payer);
        pm.pay(address(token), merchant, 100e6, ref); // buyer had gas: self-pay
        assertTrue(_sponsor(merchant, 100.5e6, ref, 0.01e6), "sponsored retry at a re-quoted price settles");
        assertEq(token.balanceOf(merchant), 99e6 + (100.5e6 - 1.005e6 - 0.05e6));
    }

    /// The same order is still payable once on v1 and once on v2 (v1 keeps its own table).
    function test_U01c_v1AndV2SameOrderBothSettle() public {
        P2FluxSplitter v1 = new P2FluxSplitter(address(token), feeWallet);
        vm.startPrank(payer);
        token.approve(address(v1), type(uint256).max);
        v1.pay(address(token), merchant, 10e6, bytes32("o"));
        pm.pay(address(token), merchant, 10e6, bytes32("o"));
        vm.stopPrank();
        assertEq(v1.paymentId(address(token), merchant, 10e6, "o"), pm.paymentId(address(token), merchant, 10e6, "o"));
    }

    // ---------------------------------------------------------------------------------------------
    // U-02 (Info): the two entrances emit different event shapes; the self-pay `Paid` has no payer.
    // ---------------------------------------------------------------------------------------------

    function test_U02_eventShapes() public {
        vm.recordLogs();
        vm.prank(payer);
        pm.pay(address(token), merchant, 10e6, bytes32("a"));
        _sponsor(merchant, 10e6, bytes32("b"), 0.01e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        uint256 sp;
        uint256 settled;
        for (uint256 i; i < logs.length; i++) {
            bytes32 t = logs[i].topics[0];
            if (logs[i].emitter != address(pm)) continue;
            if (t == Payments.Paid.selector) {
                paid++;
                // topics: ref, recipient, token. No payer anywhere in the event.
                assertEq(logs[i].topics.length, 4);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(token));
            }
            if (t == Payments.SponsoredPaid.selector) sp++;
            if (t == Payments.PaymentSettled.selector) settled++;
        }
        assertEq(paid, 1);
        assertEq(sp, 1);
        assertEq(settled, 2, "PaymentSettled(id) is the one shape common to both entrances");
    }

    // ---------------------------------------------------------------------------------------------
    // Checked, no issue
    // ---------------------------------------------------------------------------------------------

    /// Decision 2: a sponsored attempt refused as duplicate leaves the nonce unused, but that
    /// authorization can NEVER settle later: its nonce binds the same terms, whose id is settled
    /// for good, and receiveWithAuthorization only accepts this contract as caller.
    function test_UC01_unusedAuthorizationIsDeadForever() public {
        bytes32 ref = bytes32("order-79");
        Payments.SponsoredPayment memory p = _sp(merchant, 10e6, ref, 0.01e6);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        bytes32 nonce = pm.authorizationNonce(p);

        vm.prank(payer);
        pm.pay(address(token), merchant, 10e6, ref); // auto: buyer had gas after all
        uint256 bal = token.balanceOf(payer);

        bytes32 id = pm.paymentId(address(token), merchant, 10e6, ref);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, id));
        pm.payWithAuthorization(p, v, r, s);
        assertFalse(token.authorizationState(payer, nonce), "nonce not consumed (decision 2)");

        // Later, with any rate, still dead.
        vm.warp(block.timestamp + 500);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, id));
        pm.payWithAuthorization(p, v, r, s);
        // Nobody else can redeem it on the token.
        vm.prank(attacker);
        vm.expectRevert(bytes("caller must be the payee"));
        token.receiveWithAuthorization(payer, address(pm), 10.01e6, 0, p.validBefore, nonce, v, r, s);
        assertEq(token.balanceOf(payer), bal, "buyer charged exactly once");
    }

    /// Front-running the relayer with a self-pay of the SAME terms costs the front-runner the full
    /// amount (it pays the merchant); the buyer is then not charged. Grief = relayer gas only.
    function test_UC02_frontRunSponsoredWithSelfPayCostsAttacker() public {
        bytes32 ref = bytes32("order-80");
        token.mint(attacker, 10e6);
        vm.startPrank(attacker);
        token.approve(address(pm), type(uint256).max);
        pm.pay(address(token), merchant, 10e6, ref);
        vm.stopPrank();
        uint256 bal = token.balanceOf(payer);
        assertFalse(_sponsor(merchant, 10e6, ref, 0.01e6));
        assertEq(token.balanceOf(payer), bal);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(merchant), 9.9e6);
    }

    /// A buyer's permit cannot be used by anyone else to pay (pay spends msg.sender's allowance).
    function test_UC03_permitFrontRunAndTheft() public {
        address buyer2 = vm.addr(0xB0B);
        token.mint(buyer2, 50e6);
        uint256 deadline = block.timestamp + 60;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(0xB0B, buyer2, address(pm), 50e6, deadline);
        // Attacker replays the permit with its own call: permit fails silently for msg.sender
        // = attacker, and the payment needs the attacker's own (zero) allowance.
        vm.prank(attacker);
        vm.expectRevert();
        pm.payWithPermit(address(token), attacker, 50e6, "steal", deadline, v, r, s);
        // Attacker front-runs the permit itself; the buyer's call still settles.
        token.permit(buyer2, address(pm), 50e6, deadline, v, r, s);
        vm.prank(attacker);
        vm.expectRevert(); // allowance is buyer2's, not usable by the attacker
        pm.pay(address(token), attacker, 50e6, "steal");
        vm.prank(buyer2);
        pm.payWithPermit(address(token), merchant, 50e6, "p", deadline, v, r, s);
        assertEq(token.balanceOf(merchant), 49.5e6);
    }

    /// Reentrancy through the token into the other function is stopped by the guard itself.
    function test_UC04_reentrancyGuardAcrossEntrances() public {
        ReenterPaymentsToken t = new ReenterPaymentsToken();
        Payments p2 = new Payments(address(t), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        t.mint(payer, 100e6);
        vm.prank(payer);
        t.approve(address(p2), type(uint256).max);
        t.arm(p2);
        vm.prank(payer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        p2.pay(address(t), merchant, 10e6, "outer");
    }

    /// Same terms through both entrances at any legal rate: identical percentage fee; the
    /// sponsored merchant pays exactly the fixed fee more; caps hold.
    function testFuzz_UC05_feeMathBothEntrances(uint256 amount, uint16 b, uint16 pb, uint64 f, bool asPartner) public {
        b = uint16(bound(b, 0, 200));
        pb = uint16(bound(pb, 0, b));
        f = uint64(bound(f, 0, 0.2e6));
        _setRate(Reg.Kind.OneTime, b, pb, f);
        address r1 = asPartner ? partner : merchant;
        address r2 = makeAddr("m2");
        if (asPartner) _listPartner(r2, true);
        amount = bound(amount, pm.minimumAmount(r1), 1e11);
        uint256 bps = asPartner ? pb : b;
        uint256 fee = amount * bps / 10_000;

        vm.prank(payer);
        pm.pay(address(token), r1, amount, "x");
        assertTrue(_sponsor(r2, amount, "x", 0));
        assertEq(token.balanceOf(r1), amount - fee);
        assertEq(token.balanceOf(r2), amount - fee - f);
        assertEq(token.balanceOf(feeWallet), 2 * fee);
        assertEq(token.balanceOf(gasTreasury), f);
        assertLe(fee, amount * 200 / 10_000);
    }

    /// Self-pay has no minimum beyond fee < amount; tiny self-pays are fine, tiny sponsored refused.
    function test_UC06_minimums() public {
        vm.prank(payer);
        pm.pay(address(token), merchant, 1, "tiny");
        assertEq(token.balanceOf(merchant), 1);
        uint256 m = pm.minimumAmount(merchant);
        assertFalse(_sponsor(merchant, m - 1, "t2", 0));
        assertTrue(_sponsor(merchant, m, "t3", 0));
    }

    /// Gas of each entrance vs the live v1 splitter (mock USDC; warm token storage).
    function test_UC07_gas() public {
        P2FluxSplitter v1 = new P2FluxSplitter(address(token), feeWallet);
        vm.startPrank(payer);
        token.approve(address(v1), type(uint256).max);
        v1.pay(address(token), merchant, 10e6, "warm1");
        pm.pay(address(token), merchant, 10e6, "warm2");
        uint256 g = gasleft();
        v1.pay(address(token), merchant, 10e6, "g1");
        uint256 gv1 = g - gasleft();
        g = gasleft();
        pm.pay(address(token), merchant, 10e6, "g2");
        uint256 gv2 = g - gasleft();
        vm.stopPrank();
        Payments.SponsoredPayment memory p = _sp(merchant, 10e6, "g3", 0.01e6);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        vm.prank(relayer);
        g = gasleft();
        pm.payWithAuthorization(p, v, r, s);
        uint256 gsp = g - gasleft();
        console2.log("self-pay v1", gv1);
        console2.log("self-pay v2", gv2);
        console2.log("sponsored v2", gsp);
        assertLt(gv2, gv1 + 25_000, "self-pay overhead stays bounded");
    }
}
