// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "./V2Helpers.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxRecurring} from "../../../contracts/P2FluxRecurring.sol";
import {P2FluxV2Base} from "../../../contracts/v2/P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";
import {Mock1271Wallet} from "../../../contracts/test/MockTokens.sol";

contract RecurringV2Test is V2Test {
    Recurring internal recurring;
    uint256 internal constant GAS_CAP = 50_000;
    address internal merchant;

    function setUp() public {
        _v2SetUp();
        merchant = makeAddr("merchant");
        recurring = new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        token.mint(payer, 1e18);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
    }

    function _auth(address recipient, uint256 amount, uint256 maxGas)
        internal
        view
        returns (Recurring.RecurringAuthorization memory)
    {
        return Recurring.RecurringAuthorization(
            payer, recipient, address(token), amount, 30 days, uint48(block.timestamp), 0, bytes32(uint256(1)), maxGas
        );
    }

    function _sig(Recurring.RecurringAuthorization memory a) internal view returns (bytes memory) {
        return _signDigest(PAYER_KEY, recurring.subscriptionId(a));
    }

    function _charge(Recurring.RecurringAuthorization memory a, uint256 reimbursement) internal {
        bytes memory sig = _sig(a);
        vm.prank(relayer);
        recurring.charge(a, sig, reimbursement);
    }

    /// payer debit == amount + reimbursement; merchant == amount - fee - 0.05; both tiers.
    function testFuzz_conservation(uint256 amount, uint256 reimbursement, bool asPartner) public {
        amount = bound(amount, 60_000, 1e15);
        reimbursement = bound(reimbursement, 0, GAS_CAP);
        address recipient = asPartner ? partner : merchant;
        uint256 fee = (amount * (asPartner ? RECURRING_PARTNER_BPS : RECURRING_BPS)) / 10_000;
        vm.assume(amount > fee + FIXED_FEE);
        uint256 before = token.balanceOf(payer);
        _charge(_auth(recipient, amount, GAS_CAP), reimbursement);
        assertEq(before - token.balanceOf(payer), amount + reimbursement);
        assertEq(token.balanceOf(recipient), amount - fee - FIXED_FEE);
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(gasTreasury), FIXED_FEE + reimbursement);
        assertEq(token.balanceOf(address(recurring)), 0);
    }

    function test_example() public {
        _charge(_auth(merchant, 10e6, GAS_CAP), 0.01e6);
        assertEq(token.balanceOf(merchant), 10e6 - 0.15e6 - 0.05e6);
        _charge(_auth(partner, 10e6, GAS_CAP), 0.01e6);
        assertEq(token.balanceOf(partner), 10e6 - 0.125e6 - 0.05e6);
    }

    /// A fee change applies to the NEXT charge of an existing subscription, only after the timelock,
    /// and never changes what the payer is debited.
    function test_rateChangeMidSubscription() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        _charge(a, 0);
        _setRate(P2FluxFeeRegistry.Kind.Recurring, 200, 200, 100_000);
        vm.warp(a.start + 30 days);
        uint256 payerBefore = token.balanceOf(payer);
        uint256 mBefore = token.balanceOf(merchant);
        _charge(a, 0);
        assertEq(payerBefore - token.balanceOf(payer), 10e6);
        assertEq(token.balanceOf(merchant) - mBefore, 10e6 - 0.2e6 - 0.1e6);
    }

    function testFuzz_strangerNeverReimbursed(address caller, uint256 reimbursement) public {
        vm.assume(caller != relayer);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, GAS_CAP);
        bytes memory sig = _sig(a);
        uint256 before = token.balanceOf(payer);
        vm.prank(caller);
        recurring.charge(a, sig, reimbursement);
        assertEq(before - token.balanceOf(payer), 10e6);
    }

    function test_reimbursementCaps() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0.01e6);
        bytes memory sig = _sig(a);
        vm.prank(relayer);
        vm.expectRevert(Recurring.GasReimbursementTooHigh.selector);
        recurring.charge(a, sig, 0.01e6 + 1);
        a = _auth(merchant, 10e6, 1e6);
        sig = _sig(a);
        vm.prank(relayer);
        vm.expectRevert(Recurring.GasReimbursementTooHigh.selector);
        recurring.charge(a, sig, GAS_CAP + 1);
    }

    function test_onePerPeriod() public {
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        _charge(a, 0);
        bytes memory sig = _sig(a);
        vm.prank(relayer);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
        vm.warp(block.timestamp + 30 days);
        _charge(a, 0);
    }

    /// A v1 subscription signature never charges on v2 (domain version "2", different contract).
    function test_v1SignatureRefused() public {
        P2FluxRecurring v1 = new P2FluxRecurring(admin, relayer, feeWallet, gasTreasury, address(token));
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        P2FluxRecurring.RecurringAuthorization memory a1 = P2FluxRecurring.RecurringAuthorization(
            a.payer, a.recipient, a.token, a.amount, a.period, a.start, a.end, a.salt, a.maxGasReimbursement
        );
        bytes memory sig1 = _signDigest(PAYER_KEY, v1.subscriptionId(a1));
        vm.prank(relayer);
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, sig1, 0);
    }

    function test_smartWalletPayer() public {
        Mock1271Wallet w = new Mock1271Wallet(payer);
        token.mint(address(w), 10e6);
        vm.prank(address(w));
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = _auth(merchant, 10e6, 0);
        a.payer = address(w);
        bytes memory sig = _sig(a);
        recurring.charge(a, sig, 0);
        assertEq(token.balanceOf(merchant), 10e6 - 0.15e6 - 0.05e6);
    }

    function test_guards() public {
        Recurring.RecurringAuthorization memory a;
        bytes memory sig;

        a = _auth(address(0), 10e6, 0);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        a.token = address(0xBEEF);
        vm.expectRevert(Recurring.TokenNotSupported.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 0, 0);
        vm.expectRevert(Recurring.ZeroAmount.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        a.period = 0;
        vm.expectRevert(Recurring.ZeroPeriod.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        a.end = a.start;
        vm.expectRevert(Recurring.InvalidEnd.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        a.start = uint48(block.timestamp + 1);
        vm.expectRevert(Recurring.NotStarted.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        a.start = uint48(block.timestamp - 10);
        a.end = uint48(block.timestamp);
        vm.expectRevert(Recurring.Expired.selector);
        recurring.charge(a, "", 0);

        a = _auth(merchant, 10e6, 0);
        sig = _signDigest(0xB0B, recurring.subscriptionId(a));
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);

        a = _auth(merchant, FIXED_FEE, 0);
        sig = _sig(a);
        vm.expectRevert(Recurring.AmountTooSmall.selector);
        recurring.charge(a, sig, 0);

        a = _auth(merchant, 10e6, 0);
        sig = _sig(a);
        vm.prank(makeAddr("x"));
        vm.expectRevert(Recurring.NotPayer.selector);
        recurring.revoke(a);
        vm.prank(payer);
        recurring.revoke(a);
        vm.prank(payer);
        vm.expectRevert(Recurring.AlreadyRevoked.selector);
        recurring.revoke(a);
        vm.expectRevert(Recurring.Revoked.selector);
        recurring.charge(a, sig, 0);
    }

    function test_setRelayer() public {
        vm.prank(relayer);
        vm.expectRevert(Recurring.NotAdmin.selector);
        recurring.setRelayer(makeAddr("r2"));
        vm.prank(admin);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        recurring.setRelayer(address(0));
        vm.prank(admin);
        recurring.setRelayer(makeAddr("r2"));
        assertEq(recurring.relayer(), makeAddr("r2"));
    }

    function test_constructorGuards() public {
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new Recurring(address(0), relayer, feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new Recurring(admin, address(0), feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new Recurring(admin, relayer, feeWallet, address(0), address(token), address(registry), GAS_CAP);
        vm.expectRevert(Recurring.CapTooHigh.selector);
        new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), 1e6 + 1);
    }
}
