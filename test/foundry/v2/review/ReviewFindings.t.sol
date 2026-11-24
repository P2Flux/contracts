// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./ReviewBase.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSplitterV2} from "../../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice A registry-shaped contract that returns whatever it is told. Stands for a wrong address in
///         a deployment manifest (or a future registry with a bug): nothing in the payment contracts
///         re-checks what it returns.
contract RogueRegistry {
    uint256 public bps;
    uint256 public fixedFee;

    function set(uint256 _bps, uint256 _fixed) external {
        bps = _bps;
        fixedFee = _fixed;
    }

    function feeFor(P2FluxFeeRegistry.Kind, address) external view returns (uint256, uint256) {
        return (bps, fixedFee);
    }
}

/// @notice PoCs for the findings in docs/v2-review-2026-11-24.md. Each test PASSES by demonstrating
///         the behaviour the finding describes; once a fix lands the matching test must be inverted.
contract ReviewFindingsTest is ReviewBase {
    function setUp() public {
        _reviewSetUp();
    }

    // ---------------------------------------------------------------------------------------------
    // R-01 (Low): a payment or send whose recipient is the contract itself locks the funds forever.
    // ---------------------------------------------------------------------------------------------

    function test_R01_sendToSendContractLocksFunds() public {
        token.mint(payer, 101e6);
        vm.startPrank(payer);
        token.approve(address(sender), type(uint256).max);
        sender.send(address(sender), 100e6, 0.1e6, bytes32("oops"));
        vm.stopPrank();
        // 100 USDC now sits in a contract with no withdrawal function. Nobody can move it.
        assertEq(token.balanceOf(address(sender)), 100e6, "locked in P2FluxSend");
    }

    function test_R01_payToSplitterLocksFunds() public {
        token.mint(payer, 100e6);
        vm.startPrank(payer);
        token.approve(address(splitter), type(uint256).max);
        splitter.pay(address(token), address(splitter), 100e6, bytes32("oops"));
        vm.stopPrank();
        assertEq(token.balanceOf(address(splitter)), 99e6, "net locked in P2FluxSplitterV2");
    }

    function test_R01_recurringToItselfLocksFundsEveryPeriod() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(address(recurring), 10e6, 0);
        recurring.charge(a, _sigRec(a), 0);
        vm.warp(block.timestamp + 30 days);
        recurring.charge(a, _sigRec(a), 0);
        assertEq(token.balanceOf(address(recurring)), 2 * (10e6 - 0.15e6 - 0.05e6), "locked, grows per period");
    }

    /// Control: the relayed paths are already protected by the residual-balance guard.
    function test_R01_control_relayedPathsRefuseSelf() public {
        P2FluxSend.RelayedSend memory s = _rs(address(sender), 10e6, bytes32("x"), 0);
        uint256 total = _relayedTotal(s);
        token.mint(payer, total);
        (uint8 v, bytes32 r, bytes32 sig) = _signRs(s, total);
        vm.prank(relayer);
        vm.expectRevert(P2FluxSend.ResidualBalance.selector);
        sender.sendWithAuthorization(s, v, r, sig);
    }

    // ---------------------------------------------------------------------------------------------
    // R-02 (Low): payment contracts trust the registry's numbers without re-checking the caps.
    // ---------------------------------------------------------------------------------------------

    function test_R02_rogueRegistryTakesWholePayment() public {
        RogueRegistry rogue = new RogueRegistry();
        P2FluxSplitterV2 s2 = new P2FluxSplitterV2(address(token), feeWallet, address(rogue));
        Sponsored sp2 = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(rogue), NETWORK_CAP);

        // 100% "fee": merchant receives zero, the fee wallet the whole 100 USDC.
        rogue.set(10_000, 0);
        token.mint(payer, 100e6);
        vm.startPrank(payer);
        token.approve(address(s2), type(uint256).max);
        s2.pay(address(token), merchant, 100e6, bytes32("a"));
        vm.stopPrank();
        assertEq(token.balanceOf(merchant), 0, "merchant got nothing");
        assertEq(token.balanceOf(feeWallet), 100e6);

        // Fixed fee far above MAX_FIXED_FEE: merchant left with 1 base unit of a 100 USDC sale.
        rogue.set(0, 100e6 - 1);
        Sponsored.SponsoredPayment memory p =
            Sponsored.SponsoredPayment(payer, merchant, 100e6, bytes32("b"), 0, block.timestamp + 600);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_KEY, payer, address(sp2), p.amount, p.validBefore, sp2.authorizationNonce(p));
        token.mint(payer, 100e6);
        vm.prank(relayer);
        sp2.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(merchant), 1, "merchant got 1 base unit");
        assertEq(token.balanceOf(gasTreasury), 100e6 - 1);

        // And minimumAmount() divides by zero at bps = 10_000.
        rogue.set(10_000, 0);
        vm.expectRevert();
        sp2.minimumAmount(merchant);
    }

    // ---------------------------------------------------------------------------------------------
    // R-03 (Low): a fee increase inside the caps permanently bricks small existing subscriptions, and
    // isChargeable() keeps reporting them as chargeable.
    // ---------------------------------------------------------------------------------------------

    function test_R03_feeIncreaseBricksSmallSubscription() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        // 0.15 USDC per month: fine at today's 1.5% + 0.05.
        Recurring.RecurringAuthorization memory a = _auth(merchant, 0.15e6, 0);
        bytes memory sig = _sigRec(a);
        vm.prank(relayer);
        recurring.charge(a, sig, 0);

        // Admin raises the recurring fixed fee to the cap (0.20), legitimately, after 48 h.
        _setRate(P2FluxFeeRegistry.Kind.Recurring, 150, 125, 0.2e6);
        vm.warp(a.start + 30 days);

        assertTrue(recurring.isChargeable(a), "view says chargeable");
        vm.prank(relayer);
        vm.expectRevert(Recurring.AmountTooSmall.selector);
        recurring.charge(a, sig, 0);
        // No path exists to charge it again at the new rate: the payer must re-sign a new amount.
    }

    // ---------------------------------------------------------------------------------------------
    // R-04 (Informational / owner rule): the recurring fixed fee is taken even when the relayer did
    // not pay the gas (payer, merchant or anyone else executes the charge).
    // ---------------------------------------------------------------------------------------------

    function test_R04_fixedFeeChargedWhenPayerPaysOwnGas() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0.05e6);
        bytes memory sig = _sigRec(a);
        vm.prank(payer); // the buyer pays their own gas
        recurring.charge(a, sig, 0.05e6);
        assertEq(token.balanceOf(gasTreasury), 0.05e6, "fixed fee still taken (reimbursement correctly 0)");
        assertEq(token.balanceOf(merchant), 10e6 - 0.15e6 - 0.05e6);
    }

    // ---------------------------------------------------------------------------------------------
    // R-05 (Informational): anyone picks the moment a due rate change applies, anywhere in a 7-day
    // window; every relayed send signed at the old rate dies at that moment.
    // ---------------------------------------------------------------------------------------------

    function test_R05_strangerExecutesRateAndKillsInFlightSends() public {
        P2FluxSend.RelayedSend memory s = _rs(merchant, 50e6, bytes32("rent"), 0);
        uint256 total = _relayedTotal(s); // quoted at 0.1%
        token.mint(payer, total);

        vm.prank(admin);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.Send, P2FluxFeeRegistry.Rate(11, 11, 50_000));
        vm.warp(block.timestamp + 48 hours + 3 days); // due for days; nobody executed yet
        s.validBefore = block.timestamp + 600;
        (uint8 v, bytes32 r, bytes32 sig) = _signRs(s, total); // API still quotes the live rate

        vm.prank(attacker);
        registry.executeRate(P2FluxFeeRegistry.Kind.Send); // front-runs the relayer

        vm.prank(relayer);
        vm.expectRevert(bytes("invalid authorization signature")); // signed total no longer matches
        sender.sendWithAuthorization(s, v, r, sig);
    }

    // ---------------------------------------------------------------------------------------------
    // R-06 (Informational): one order (recipient, amount, ref) can be settled once PER contract: v2
    // splitter and v2 sponsored (and v1's two) keep separate tables for the same paymentId.
    // ---------------------------------------------------------------------------------------------

    function test_R06_sameOrderPaidTwiceAcrossContracts() public {
        bytes32 ref = bytes32("order-42");
        token.mint(payer, 200e6);
        vm.startPrank(payer);
        token.approve(address(splitter), type(uint256).max);
        splitter.pay(address(token), merchant, 100e6, ref);
        vm.stopPrank();

        Sponsored.SponsoredPayment memory p = _sp(merchant, 100e6, ref, 0);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);

        assertEq(
            splitter.paymentId(address(token), merchant, 100e6, ref),
            sponsored.paymentId(address(token), merchant, 100e6, ref)
        );
        assertEq(token.balanceOf(payer), 0, "buyer paid the same order twice");
    }

    // ---------------------------------------------------------------------------------------------
    // R-07 (Informational / business): a relayed Send is a gasless, ref-tagged payment rail at 0.1%
    // + 0.05, against 1% + 0.05 for a sponsored one-time payment.
    // ---------------------------------------------------------------------------------------------

    function test_R07_sendUndercutsSponsoredPayment() public {
        // Sponsored checkout, 100 USDC: P2Flux revenue 1.00 + 0.05 fixed.
        Sponsored.SponsoredPayment memory p = _sp(merchant, 100e6, bytes32("inv-1"), 0);
        (uint8 v, bytes32 r, bytes32 s) = _signSp(p);
        token.mint(payer, 100e6);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
        uint256 viaCheckout = token.balanceOf(feeWallet) + token.balanceOf(gasTreasury);

        // Same sale as a relayed send with the invoice number as ref: merchant even gets MORE.
        address merchant2 = makeAddr("merchant2");
        P2FluxSend.RelayedSend memory rs = _rs(merchant2, 100e6, bytes32("inv-1"), 0);
        uint256 total = _relayedTotal(rs);
        token.mint(payer, total);
        (v, r, s) = _signRs(rs, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(rs, v, r, s);
        uint256 viaSend = token.balanceOf(feeWallet) + token.balanceOf(gasTreasury) - viaCheckout;

        assertEq(viaCheckout, 1.05e6);
        assertEq(viaSend, 0.15e6, "P2Flux earns 0.15 instead of 1.05 on a 100 USDC sale");
        assertEq(token.balanceOf(merchant2), 100e6);
    }

    /// R-07b: the owner rule "the API quotes zero extra gas" for Send is not enforced on chain.
    function test_R07b_relayedSendAcceptsNetworkFee() public {
        P2FluxSend.RelayedSend memory rs = _rs(merchant, 10e6, bytes32("x"), NETWORK_CAP);
        uint256 total = _relayedTotal(rs);
        token.mint(payer, total);
        (uint8 v, bytes32 r, bytes32 s) = _signRs(rs, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(rs, v, r, s);
        assertEq(token.balanceOf(gasTreasury), 0.05e6 + NETWORK_CAP);
    }

    // ---------------------------------------------------------------------------------------------
    // R-08 (Informational): the recurring admin swaps the relayer instantly (no timelock, unlike
    // every registry change), and the new relayer takes max reimbursement on every due charge.
    // ---------------------------------------------------------------------------------------------

    function test_R08_compromisedRecurringAdminInstantRelayer() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 1e6); // payer signed a loose cap
        bytes memory sig = _sigRec(a);

        vm.prank(admin);
        recurring.setRelayer(attacker); // same block, no delay
        vm.prank(attacker);
        recurring.charge(a, sig, GAS_CAP);
        assertEq(token.balanceOf(gasTreasury), 0.05e6 + GAS_CAP, "bounded by GAS_REIMBURSEMENT_HARD_CAP");
        // Note: the reimbursement goes to gasTreasury (immutable), not to the attacker. The attacker
        // can only make payers overpay P2Flux's own treasury; impact = payer overcharge <= cap/charge.
    }

    // ---------------------------------------------------------------------------------------------
    // R-09 (Informational): executePartners is all-or-nothing; one stale entry blocks the batch.
    // ---------------------------------------------------------------------------------------------

    function test_R09_executePartnersAllOrNothing() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        vm.prank(admin);
        registry.schedulePartners(_one(a), true);
        vm.warp(block.timestamp + 48 hours);
        address[] memory both = new address[](2);
        both[0] = a;
        both[1] = b; // never scheduled
        vm.expectRevert(P2FluxFeeRegistry.NothingPending.selector);
        registry.executePartners(both);
        assertFalse(registry.isPartner(a));
        registry.executePartners(_one(a));
        assertTrue(registry.isPartner(a));
    }
}
