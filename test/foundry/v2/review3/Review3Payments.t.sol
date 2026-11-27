// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "../V2Helpers.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";

/// @notice Review 3 (27 Nov 2026, pre-mainnet gate): adversarial checks on P2FluxPaymentsV2.
contract Review3PaymentsTest is V2Test {
    P2FluxPaymentsV2 internal pay;
    address internal merchant = makeAddr("r3-merchant");
    address internal attacker = makeAddr("r3-attacker");

    function setUp() public {
        _v2SetUp();
        pay = new P2FluxPaymentsV2(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        token.mint(payer, 1e12);
    }

    function _sp(address rcpt, uint256 amount, bytes32 ref, uint256 nf)
        internal
        view
        returns (P2FluxPaymentsV2.SponsoredPayment memory)
    {
        return P2FluxPaymentsV2.SponsoredPayment(payer, rcpt, amount, ref, nf, block.timestamp + 1 hours);
    }

    function _sign(P2FluxPaymentsV2.SponsoredPayment memory p) internal view returns (uint8, bytes32, bytes32) {
        return
            _signReceive(PAYER_KEY, p.payer, address(pay), p.amount + p.networkFee, p.validBefore, pay.authorizationNonce(p));
    }

    function _settle(P2FluxPaymentsV2.SponsoredPayment memory p, uint8 v, bytes32 r, bytes32 s) internal {
        vm.prank(relayer);
        pay.payWithAuthorization(p, v, r, s);
    }

    // The relayer cannot change ANY signed term: each single-field change must revert.
    function test_r3_relayerCannotAlterAnyTerm() public {
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, 10e6, "order-1", 100_000);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        P2FluxPaymentsV2.SponsoredPayment memory q;

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.recipient = attacker;
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.amount = 10e6 - 1; // same total, shifted into the network fee
        q.networkFee = 100_001;
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.amount = 10e6 + 50_000; // same total, less network fee
        q.networkFee = 50_000;
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.ref = "order-2";
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.validBefore += 1;
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        q = _sp(merchant, 10e6, "order-1", 100_000);
        q.payer = attacker;
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(q, v, r, s);

        // Nobody but the relayer; and the token refuses a direct redeem by a stranger.
        vm.prank(attacker);
        vm.expectRevert(P2FluxPaymentsV2.NotRelayer.selector);
        pay.payWithAuthorization(p, v, r, s);
        bytes32 nonce = pay.authorizationNonce(p);
        vm.prank(attacker);
        vm.expectRevert();
        token.receiveWithAuthorization(payer, address(pay), 10e6 + 100_000, 0, p.validBefore, nonce, v, r, s);

        // The untouched terms still settle, exactly.
        uint256 before = token.balanceOf(payer);
        _settle(p, v, r, s);
        assertEq(before - token.balanceOf(payer), 10e6 + 100_000);
        assertEq(token.balanceOf(merchant), 10e6 - 100_000 - 50_000);
        assertEq(token.balanceOf(feeWallet), 100_000);
        assertEq(token.balanceOf(gasTreasury), 50_000 + 100_000);
        assertEq(token.balanceOf(address(pay)), 0);
    }

    // A second deployment (same code, same chain) cannot reuse the signature.
    function test_r3_noCrossContractReplay() public {
        P2FluxPaymentsV2 other =
            new P2FluxPaymentsV2(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, 10e6, "order-1", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert();
        other.payWithAuthorization(p, v, r, s);
        assertTrue(other.authorizationNonce(p) != pay.authorizationNonce(p));
    }

    // One id, two entrances, both orders. A failed attempt leaves the order payable.
    function test_r3_crossEntranceOnce() public {
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, 10e6, "A", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.startPrank(payer);
        token.approve(address(pay), type(uint256).max);
        pay.pay(address(token), merchant, 10e6, "A");
        vm.stopPrank();
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(p, v, r, s);

        p = _sp(merchant, 10e6, "B", 0);
        (v, r, s) = _sign(p);
        // failed attempt first (bad signature): must not mark the order
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(p, v, r, bytes32(uint256(s) ^ 1));
        assertFalse(pay.isPaymentProcessed(address(token), merchant, 10e6, "B"));
        _settle(p, v, r, s);
        vm.prank(payer);
        vm.expectRevert();
        pay.pay(address(token), merchant, 10e6, "B");
    }

    // A victim's standing (unlimited) allowance cannot be spent by anyone else through any entrance.
    function test_r3_standingAllowanceCannotBeSpentByOthers() public {
        vm.prank(payer);
        token.approve(address(pay), type(uint256).max);
        uint256 before = token.balanceOf(payer);

        vm.prank(attacker); // attacker has no balance: the pull is from the attacker, never the victim
        vm.expectRevert();
        pay.pay(address(token), attacker, 5e6, "x");

        // permit signed by the victim, submitted by the attacker: owner is msg.sender, so it is useless
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PAYER_KEY, payer, address(pay), 5e6, block.timestamp + 1 hours);
        vm.prank(attacker);
        vm.expectRevert();
        pay.payWithPermit(address(token), attacker, 5e6, "x", block.timestamp + 1 hours, v, r, s);

        // even the relayer cannot use the allowance: the sponsored path needs an EIP-3009 signature
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(attacker, 5e6, "x", 0);
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(p, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(token.balanceOf(payer), before);
    }

    // Id squatting: marking a victim's order id costs the full amount, paid to the order's recipient.
    function test_r3_squatCostsFullPayment() public {
        token.mint(attacker, 10e6);
        vm.startPrank(attacker);
        token.approve(address(pay), type(uint256).max);
        pay.pay(address(token), merchant, 10e6, "victim-order");
        vm.stopPrank();
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(merchant), 10e6 - 100_000); // merchant was really paid
        // any other terms are a different id: the victim's own order is untouched
        assertFalse(pay.isPaymentProcessed(address(token), merchant, 10e6 - 1, "victim-order"));
        assertFalse(pay.isPaymentProcessed(address(token), attacker, 10e6, "victim-order"));
    }

    // minimumAmount is exact for every allowed rate (grid), and the contract agrees at the boundary.
    function test_r3_minimumAmountExactGrid() public pure {
        uint256[6] memory fixedFees = [uint256(0), 1, 9_999, 50_000, 199_999, 200_000];
        for (uint256 bps = 0; bps <= 200; bps++) {
            for (uint256 i = 0; i < fixedFees.length; i++) {
                uint256 f = fixedFees[i];
                uint256 m = (f * 10_000) / (10_000 - bps) + 1;
                assertTrue(m - (m * bps) / 10_000 > f, "minimum does not clear");
                uint256 b = m - 1;
                assertFalse(b - (b * bps) / 10_000 > f, "minimum is not the smallest");
            }
        }
    }

    function test_r3_minimumAmountBoundarySettles() public {
        uint256 m = pay.minimumAmount(merchant);
        assertEq(m, 50_506);
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, m - 1, "min-1", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert(P2FluxPaymentsV2.AmountTooSmall.selector);
        pay.payWithAuthorization(p, v, r, s);
        p = _sp(merchant, m, "min", 0);
        (v, r, s) = _sign(p);
        _settle(p, v, r, s);
        assertEq(token.balanceOf(merchant), 1);
    }

    // A rate change that matures between signing and settling never moves more from the PAYER;
    // the merchant's net drops, bounded by the hard caps. Numbers for the report.
    function test_r3_rateChangeBetweenSignAndSettle() public {
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, 10e6, "late", 100_000);
        p.validBefore = block.timestamp + 3 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        _setRate(P2FluxFeeRegistry.Kind.OneTime, 200, 200, 200_000); // worst the admin can ever do
        uint256 before = token.balanceOf(payer);
        _settle(p, v, r, s);
        assertEq(before - token.balanceOf(payer), 10e6 + 100_000); // payer: exactly what was signed
        assertEq(token.balanceOf(merchant), 10e6 - 200_000 - 200_000); // 9.60 instead of 9.85
    }

    // Conservation and caps under any allowed rate, either entrance.
    function testFuzz_r3_conservationSponsored(uint256 amount, uint16 bps, uint16 pb, uint64 fixedFee, uint256 nf, bool listed)
        public
    {
        bps = uint16(bound(bps, 0, 200));
        pb = uint16(bound(pb, 0, bps));
        fixedFee = uint64(bound(fixedFee, 0, 200_000));
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, pb, fixedFee);
        P2FluxPaymentsV2.SponsoredPayment memory p =
            _sp(listed ? partner : merchant, bound(amount, 1, 1e11), "f", bound(nf, 0, NETWORK_CAP));
        uint256 fee = p.amount * (listed ? pb : bps) / 10_000;
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        if (p.amount <= fee + fixedFee) {
            vm.prank(relayer);
            vm.expectRevert(P2FluxPaymentsV2.AmountTooSmall.selector);
            pay.payWithAuthorization(p, v, r, s);
            return;
        }
        _settle(p, v, r, s);
        assertEq(1e12 - token.balanceOf(payer), p.amount + p.networkFee);
        assertEq(token.balanceOf(p.recipient), p.amount - fee - fixedFee);
        assertEq(token.balanceOf(gasTreasury), uint256(fixedFee) + p.networkFee);
        assertEq(token.balanceOf(feeWallet), fee);
        assertLe(fee * 10_000, p.amount * 200);
        assertEq(token.balanceOf(address(pay)), 0);
    }

    function testFuzz_r3_conservationSelfPay(uint256 amount, uint16 bps, uint16 pb, uint64 fixedFee, bool listed) public {
        bps = uint16(bound(bps, 0, 200));
        pb = uint16(bound(pb, 0, bps));
        amount = bound(amount, 1, 1e11);
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, pb, uint64(bound(fixedFee, 0, 200_000)));
        address rcpt = listed ? partner : merchant;
        uint256 fee = amount * (listed ? pb : bps) / 10_000;
        vm.startPrank(payer);
        token.approve(address(pay), amount);
        pay.pay(address(token), rcpt, amount, "f");
        vm.stopPrank();
        assertEq(1e12 - token.balanceOf(payer), amount);
        assertEq(token.balanceOf(rcpt), amount - fee);
        assertEq(token.balanceOf(gasTreasury), 0);
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(address(pay)), 0);
    }

    // Blacklisted fee wallet: fee-bearing payments revert for everyone (no funds stuck, order stays
    // payable); only sub-fee dust still passes. Blacklisted recipient: only that recipient.
    function test_r3_blacklistEffects() public {
        vm.prank(payer);
        token.approve(address(pay), type(uint256).max);

        token.setBlacklisted(merchant, true);
        vm.prank(payer);
        vm.expectRevert();
        pay.pay(address(token), merchant, 10e6, "m");
        vm.prank(payer);
        pay.pay(address(token), partner, 10e6, "p"); // others unaffected
        token.setBlacklisted(merchant, false);

        token.setBlacklisted(feeWallet, true);
        vm.prank(payer);
        vm.expectRevert();
        pay.pay(address(token), merchant, 10e6, "m"); // every fee-bearing payment is blocked
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(merchant, 10e6, "s", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(address(pay)), 0);
        assertFalse(pay.isPaymentProcessed(address(token), merchant, 10e6, "m"));
        vm.prank(payer);
        pay.pay(address(token), merchant, 99, "dust"); // fee == 0: no transfer to the fee wallet
        token.setBlacklisted(feeWallet, false);
        _settle(p, v, r, s); // the same signature settles once the block is lifted
    }

    // Recipient == token contract or fee wallet or gas treasury: no lock, exact conservation.
    function test_r3_oddRecipients() public {
        vm.startPrank(payer);
        token.approve(address(pay), type(uint256).max);
        vm.expectRevert();
        pay.pay(address(token), address(pay), 1e6, "self");
        vm.expectRevert();
        pay.pay(address(token), address(0), 1e6, "zero");
        pay.pay(address(token), feeWallet, 1e6, "fw");
        pay.pay(address(token), payer, 1e6, "me");
        vm.stopPrank();
        P2FluxPaymentsV2.SponsoredPayment memory p = _sp(gasTreasury, 1e6, "gt", 1000);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        _settle(p, v, r, s);
        p = _sp(address(pay), 1e6, "self", 0);
        (v, r, s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert();
        pay.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(address(pay)), 0);
    }
}
