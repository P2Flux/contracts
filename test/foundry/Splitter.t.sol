// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {P2FluxSplitter} from "../../contracts/P2FluxSplitter.sol";
import {MockUSDC} from "../../contracts/test/MockTokens.sol";

/// @notice Fuzz suite for the one-time splitter: conservation, the 1% fee at every rounding
///         boundary, single settlement per intent, and the token pin.
contract SplitterFuzzTest is P2FluxTest {
    P2FluxSplitter internal splitter;

    function setUp() public {
        _baseSetUp();
        splitter = new P2FluxSplitter(address(token), feeWallet);
    }

    function _fund(uint256 amount) internal {
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(splitter), amount);
    }

    /// Buyer outflow == merchant receipt + fee, to the base unit, for any amount.
    function testFuzz_pay_conservesValue(uint256 amount, bytes32 ref, uint256 recipientSeed) public {
        amount = bound(amount, 1, type(uint128).max);
        address recipient = _cleanAddress(recipientSeed, address(splitter));
        _fund(amount);

        vm.prank(payer);
        splitter.pay(address(token), recipient, amount, ref);

        uint256 fee = (amount * 100) / 10_000;
        assertEq(token.balanceOf(payer), 0, "buyer debited exactly the amount");
        assertEq(token.balanceOf(recipient), amount - fee, "merchant receives amount minus 1%");
        assertEq(token.balanceOf(feeWallet), fee, "fee wallet receives exactly the fee");
        assertEq(token.balanceOf(address(splitter)), 0, "splitter never holds value");
        assertEq(token.balanceOf(recipient) + token.balanceOf(feeWallet), amount, "nothing created or lost");
        assertTrue(splitter.isPaymentProcessed(address(token), recipient, amount, ref));
    }

    /// The fee can never exceed 1% and rounding always favours the merchant.
    function testFuzz_fee_neverExceedsOnePercent(uint256 amount) public view {
        amount = bound(amount, 1, type(uint128).max);
        uint256 fee = (amount * splitter.ONE_TIME_BPS()) / 10_000;
        assertLe(fee * 10_000, amount * 100, "fee above 1%");
        assertLt(amount * 100 - fee * 10_000, 10_000, "fee rounds down by less than one unit");
    }

    function test_fee_roundingBoundaries() public {
        uint256[6] memory amounts = [uint256(1), 99, 100, 199, 200, 10_000];
        uint256[6] memory fees = [uint256(0), 0, 1, 1, 2, 100];
        for (uint256 i; i < amounts.length; i++) {
            address recipient = address(uint160(0xBEEF00 + i));
            _fund(amounts[i]);
            vm.prank(payer);
            splitter.pay(address(token), recipient, amounts[i], bytes32(i));
            assertEq(token.balanceOf(recipient), amounts[i] - fees[i]);
        }
    }

    /// One intent settles once. A different reference is a different intent.
    function testFuzz_pay_replayReverts(uint256 amount, bytes32 ref, bytes32 otherRef) public {
        amount = bound(amount, 1, type(uint64).max);
        vm.assume(ref != otherRef);
        address recipient = makeAddr("merchant");
        _fund(amount * 3);

        vm.startPrank(payer);
        splitter.pay(address(token), recipient, amount, ref);
        bytes32 id = splitter.paymentId(address(token), recipient, amount, ref);
        vm.expectRevert(abi.encodeWithSelector(P2FluxSplitter.PaymentAlreadyProcessed.selector, id));
        splitter.pay(address(token), recipient, amount, ref);
        splitter.pay(address(token), recipient, amount, otherRef);
        vm.stopPrank();
    }

    /// No other token - including an address with no code - can produce a settlement.
    function testFuzz_pay_refusesAnyOtherToken(address other, uint256 amount, bytes32 ref) public {
        vm.assume(other != address(token));
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(payer);
        vm.expectRevert(P2FluxSplitter.TokenNotSupported.selector);
        splitter.pay(other, makeAddr("merchant"), amount, ref);
    }

    /// A failed transfer leaves the intent payable: the replay guard is rolled back with it.
    function testFuzz_pay_failureLeavesIntentOpen(uint256 amount, bytes32 ref) public {
        amount = bound(amount, 2, type(uint64).max);
        address recipient = makeAddr("merchant");
        token.mint(payer, amount - 1); // one unit short
        vm.startPrank(payer);
        token.approve(address(splitter), type(uint256).max);
        vm.expectRevert();
        splitter.pay(address(token), recipient, amount, ref);
        vm.stopPrank();
        assertFalse(splitter.isPaymentProcessed(address(token), recipient, amount, ref));
        assertEq(token.balanceOf(recipient), 0);
    }

    /// Every term is part of the id: change any one and it is a different intent.
    function testFuzz_paymentId_bindsEveryTerm(address r1, address r2, uint256 a1, uint256 a2, bytes32 f1, bytes32 f2)
        public
        view
    {
        bytes32 base = splitter.paymentId(address(token), r1, a1, f1);
        if (r1 != r2) assertNotEq(base, splitter.paymentId(address(token), r2, a1, f1));
        if (a1 != a2) assertNotEq(base, splitter.paymentId(address(token), r1, a2, f1));
        if (f1 != f2) assertNotEq(base, splitter.paymentId(address(token), r1, a1, f2));
        assertNotEq(base, splitter.paymentId(address(0xdead), r1, a1, f1));
    }

    /// A front-run (already consumed) permit must not block a payment that has its allowance.
    function testFuzz_payWithPermit_survivesGarbagePermit(uint256 amount, bytes32 ref, bytes32 junkR, bytes32 junkS)
        public
    {
        amount = bound(amount, 1, type(uint64).max);
        address recipient = makeAddr("merchant");
        _fund(amount);
        vm.prank(payer);
        splitter.payWithPermit(address(token), recipient, amount, ref, block.timestamp + 1, 27, junkR, junkS);
        assertEq(token.balanceOf(payer), 0);
    }

    /// ... and a garbage permit with no allowance behind it moves nothing.
    function testFuzz_payWithPermit_garbageAloneMovesNothing(uint256 amount, bytes32 ref, bytes32 junkR, bytes32 junkS)
        public
    {
        amount = bound(amount, 1, type(uint64).max);
        token.mint(payer, amount);
        vm.prank(payer);
        vm.expectRevert();
        splitter.payWithPermit(address(token), makeAddr("merchant"), amount, ref, block.timestamp + 1, 27, junkR, junkS);
        assertEq(token.balanceOf(payer), amount);
    }

    function test_payWithPermit_validPermit() public {
        uint256 amount = 25e6;
        token.mint(payer, amount);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PAYER_KEY, payer, address(splitter), amount, block.timestamp + 60);
        vm.prank(payer);
        splitter.payWithPermit(address(token), makeAddr("merchant"), amount, "ref", block.timestamp + 60, v, r, s);
        assertEq(token.balanceOf(makeAddr("merchant")), amount - amount / 100);
    }

    function test_constructor_refusesCodelessTokenAndZeroAddresses() public {
        vm.expectRevert(P2FluxSplitter.NotAContract.selector);
        new P2FluxSplitter(address(0xC0DE1E55), feeWallet);
        vm.expectRevert(P2FluxSplitter.ZeroAddress.selector);
        new P2FluxSplitter(address(0), feeWallet);
        MockUSDC real = new MockUSDC();
        vm.expectRevert(P2FluxSplitter.ZeroAddress.selector);
        new P2FluxSplitter(address(real), address(0));
    }
}
