// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReviewBase} from "./ReviewBase.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSplitterV2} from "../../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";
import {P2FluxV2Base} from "../../../../contracts/v2/P2FluxV2Base.sol";

/// @notice A registry-shaped contract that returns whatever it is told, including the sanity values
///         the payment contracts check at construction. Stands for a wrong address in a deployment
///         manifest or a future registry with a bug.
contract RogueRegistry {
    uint16 public constant MAX_BPS = 200;
    uint64 public constant MAX_FIXED_FEE = 0.2e6;
    uint256 public constant DELAY = 48 hours;
    uint16 public bps;
    uint16 public partnerBps;
    uint64 public fixedFee;

    function set(uint16 _bps, uint16 _pbps, uint64 _fixed) external {
        bps = _bps;
        partnerBps = _pbps;
        fixedFee = _fixed;
    }

    function rates(P2FluxFeeRegistry.Kind) external view returns (uint16, uint16, uint64) {
        return (bps, partnerBps, fixedFee);
    }

    function isPartner(address) external pure returns (bool) {
        return true;
    }
}

/// @notice A contract with code that is not a registry at all.
contract NotARegistry {
    uint256 public x;
}

/// @notice Regression tests for docs/v2-review-2026-11-24.md. The review's PoCs demonstrated the
///         findings; after the fixes each one is inverted here and must pass. R-06, R-07 and R-08 are
///         accepted / handled off chain and stay as documentation of the bound.
contract ReviewFindingsTest is ReviewBase {
    function setUp() public {
        _reviewSetUp();
    }

    // --- R-01: a payment or send to the contract itself is refused ---------------------------------

    function test_R01_sendToSendContractRefused() public {
        token.mint(payer, 101e6);
        vm.startPrank(payer);
        token.approve(address(sender), type(uint256).max);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        sender.send(address(sender), 100e6, 0.1e6, bytes32("oops"));
        vm.stopPrank();
        assertEq(token.balanceOf(address(sender)), 0);
    }

    function test_R01_payToSplitterRefused() public {
        token.mint(payer, 100e6);
        vm.startPrank(payer);
        token.approve(address(splitter), type(uint256).max);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        splitter.pay(address(token), address(splitter), 100e6, bytes32("oops"));
        vm.stopPrank();
    }

    function test_R01_recurringToItselfRefused() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(address(recurring), 10e6, 0);
        bytes memory sig = _sigRec(a);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        recurring.charge(a, sig, 0);
        assertFalse(recurring.isChargeable(a));
    }

    function test_R01_relayedPathsRefuseSelf() public {
        P2FluxSend.RelayedSend memory s = _rs(address(sender), 10e6, bytes32("x"));
        vm.prank(relayer);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        sender.sendWithAuthorization(s, 0, 0, 0);
        vm.prank(relayer);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        sponsored.payWithAuthorization(_sp(address(sponsored), 10e6, bytes32("x"), 0), 0, 0, 0);
    }

    // --- R-02: caps re-checked in the payment contracts; registry validated at construction ---------

    function test_R02_rogueRegistryCannotExceedCaps() public {
        RogueRegistry rogue = new RogueRegistry();
        P2FluxSplitterV2 s2 = new P2FluxSplitterV2(address(token), feeWallet, address(rogue));
        Sponsored sp2 = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(rogue), NETWORK_CAP);
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(s2), type(uint256).max);

        rogue.set(10_000, 0, 0); // 100% fee
        vm.prank(payer);
        vm.expectRevert(P2FluxV2Base.RateAboveCap.selector);
        s2.pay(address(token), merchant, 100e6, bytes32("a"));
        vm.expectRevert(P2FluxV2Base.RateAboveCap.selector);
        sp2.minimumAmount(merchant); // no division by zero: refused before it

        rogue.set(0, 0, 100e6 - 1); // fixed fee far above 0.20
        vm.prank(relayer);
        vm.expectRevert(P2FluxV2Base.RateAboveCap.selector);
        sp2.payWithAuthorization(_sp(merchant, 100e6, bytes32("b"), 0), 0, 0, 0);

        rogue.set(100, 150, 0); // partner above standard
        vm.prank(payer);
        vm.expectRevert(P2FluxV2Base.RateAboveCap.selector);
        s2.pay(address(token), merchant, 100e6, bytes32("c"));

        rogue.set(200, 200, 0.2e6); // at the caps: works, merchant keeps amount - 2%
        vm.prank(payer);
        s2.pay(address(token), merchant, 100e6, bytes32("d"));
        assertEq(token.balanceOf(merchant), 98e6);
    }

    function test_R02_registryValidatedAtConstruction() public {
        address notReg = address(new NotARegistry());
        vm.expectRevert();
        new P2FluxSplitterV2(address(token), feeWallet, notReg);
        vm.expectRevert(P2FluxV2Base.NotAContract.selector);
        new P2FluxSplitterV2(address(token), feeWallet, makeAddr("eoa"));
    }

    // --- R-03: isChargeable follows the current rates ---------------------------------------------

    function test_R03_isChargeableFalseAfterFeeIncrease() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 0.15e6, 0);
        bytes memory sig = _sigRec(a);
        vm.prank(relayer);
        recurring.charge(a, sig, 0);
        _setRate(P2FluxFeeRegistry.Kind.Recurring, 150, 125, 0.2e6);
        vm.warp(a.start + 30 days);
        assertFalse(recurring.isChargeable(a), "view now agrees with charge");
        vm.prank(relayer);
        vm.expectRevert(Recurring.AmountTooSmall.selector);
        recurring.charge(a, sig, 0);
    }

    // --- R-04: no fixed fee when the payer (or anyone but the relayer) pays the gas ----------------

    function test_R04_noFixedFeeWhenPayerPaysOwnGas() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0.05e6);
        bytes memory sig = _sigRec(a);
        vm.prank(payer);
        recurring.charge(a, sig, 0.05e6);
        assertEq(token.balanceOf(gasTreasury), 0, "no fixed fee, no reimbursement");
        assertEq(token.balanceOf(merchant), 10e6 - 0.15e6);
    }

    // --- R-05: a scheduled rate takes effect exactly at its ETA; nobody picks the moment ------------

    function test_R05_rateEffectiveExactlyAtEta() public {
        uint256 t0 = block.timestamp;
        vm.prank(admin);
        registry.scheduleRate(P2FluxFeeRegistry.Kind.Send, P2FluxFeeRegistry.Rate(11, 11, 50_000));
        (,,, uint256 eta) = registry.pendingRate(P2FluxFeeRegistry.Kind.Send);
        assertEq(eta, t0 + 48 hours, "public, exact effective time");

        // Signed at the old rate before the ETA: settles right up to ETA - 1.
        P2FluxSend.RelayedSend memory s = _rs(merchant, 50e6, bytes32("rent"));
        vm.warp(eta - 1);
        s.validBefore = block.timestamp + 600;
        uint256 total = _relayedTotal(s);
        token.mint(payer, 2 * total);
        (uint8 v, bytes32 r, bytes32 sig) = _signRs(s, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);

        // From the ETA on, the new rate applies with no call from anyone.
        vm.warp(eta);
        (uint256 fee,) = sender.quote(50e6);
        assertEq(fee, 50e6 * 11 / 10_000);
    }

    // --- R-06 (accepted, API rule): one paymentId per contract table -------------------------------

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
        assertEq(token.balanceOf(payer), 0, "documented: the API binds each order to ONE contract");
    }

    // --- R-07 (policy, relayer-side) and R-07b (fixed: no gas quote on Send) -----------------------

    function test_R07_sendIsCheaperRailDocumented() public {
        P2FluxSend.RelayedSend memory rs = _rs(merchant, 100e6, bytes32("inv-1"));
        uint256 total = _relayedTotal(rs);
        token.mint(payer, total);
        (uint8 v, bytes32 r, bytes32 s) = _signRs(rs, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(rs, v, r, s);
        assertEq(token.balanceOf(feeWallet) + token.balanceOf(gasTreasury), 0.15e6);
    }

    function test_R07b_relayedSendTakesNoGasQuote() public {
        P2FluxSend.RelayedSend memory rs = _rs(merchant, 10e6, bytes32("x"));
        uint256 total = _relayedTotal(rs);
        assertEq(total, 10e6 + 0.01e6 + 0.05e6, "amount + 0.1% + 0.05, nothing else");
        token.mint(payer, total + NETWORK_CAP);
        // A signature over anything more (e.g. a gas quote on top) can never settle.
        (uint8 v, bytes32 r, bytes32 s) = _signRs(rs, total + NETWORK_CAP);
        vm.prank(relayer);
        vm.expectRevert(bytes("invalid authorization signature"));
        sender.sendWithAuthorization(rs, v, r, s);
        (v, r, s) = _signRs(rs, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(rs, v, r, s);
        assertEq(token.balanceOf(gasTreasury), 0.05e6);
    }

    // --- R-08 (accepted: instant relayer swap for incident response) -------------------------------

    function test_R08_compromisedRecurringAdminInstantRelayer() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 1e6);
        bytes memory sig = _sigRec(a);
        vm.prank(admin);
        recurring.setRelayer(attacker);
        vm.prank(attacker);
        recurring.charge(a, sig, GAS_CAP);
        assertEq(token.balanceOf(gasTreasury), 0.05e6 + GAS_CAP, "bounded; paid to the immutable treasury");
    }

    // --- R-09: no execute step any more; a batch takes effect by itself ---------------------------

    function test_R09_partnerBatchNeedsNoExecute() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory both = new address[](2);
        both[0] = a;
        both[1] = b;
        vm.prank(admin);
        registry.schedulePartners(both, true);
        vm.prank(admin);
        registry.cancelPartner(b); // one entry cancelled does not affect the other
        vm.warp(block.timestamp + 48 hours);
        assertTrue(registry.isPartner(a));
        assertFalse(registry.isPartner(b));
    }
}
