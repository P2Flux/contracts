// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "./V2Helpers.sol";
import {P2FluxSplitterV2} from "../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxV2Base} from "../../../contracts/v2/P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";
import {FalseReturnToken} from "../../../contracts/test/MockTokens.sol";

contract EighteenDecimals {
    uint8 public constant decimals = 18;
}

contract SplitterV2Test is V2Test {
    P2FluxSplitterV2 internal splitter;

    function setUp() public {
        _v2SetUp();
        splitter = new P2FluxSplitterV2(address(token), feeWallet, address(registry));
        vm.prank(payer);
        token.approve(address(splitter), type(uint256).max);
    }

    function _pay(address recipient, uint256 amount, bytes32 ref) internal {
        vm.prank(payer);
        splitter.pay(address(token), recipient, amount, ref);
    }

    /// buyer debit == amount; recipient == amount - fee; fee wallet == fee; standard and partner.
    function testFuzz_conservation(uint256 amount, bytes32 ref, uint256 seed, bool asPartner) public {
        amount = bound(amount, 1, 1e18);
        address recipient = asPartner ? partner : _cleanV2(seed, address(splitter));
        token.mint(payer, amount);
        _pay(recipient, amount, ref);
        uint256 fee = (amount * (asPartner ? ONE_TIME_PARTNER_BPS : ONE_TIME_BPS)) / 10_000;
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(recipient), amount - fee);
        assertEq(token.balanceOf(feeWallet), fee);
        assertLe(fee * 10_000, amount * 200, "fee never above the hard cap");
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_examples() public {
        token.mint(payer, 200e6);
        _pay(makeAddr("m"), 100e6, "a");
        assertEq(token.balanceOf(makeAddr("m")), 99e6);
        assertEq(token.balanceOf(feeWallet), 1e6);
        _pay(partner, 100e6, "b");
        assertEq(token.balanceOf(partner), 99.25e6);
        assertEq(token.balanceOf(feeWallet), 1.75e6);
    }

    /// The merchant cannot pick a lower fee: the tier is the registry's, keyed by recipient.
    function test_nonPartnerPaysStandardEvenIfCallingDirectly() public {
        address m = makeAddr("m");
        token.mint(m, 100e6);
        vm.startPrank(m);
        token.approve(address(splitter), type(uint256).max);
        splitter.pay(address(token), m, 100e6, "self");
        vm.stopPrank();
        assertEq(token.balanceOf(feeWallet), 1e6);
    }

    function test_rateChangeAppliesAfterTimelock() public {
        _setRate(P2FluxFeeRegistry.Kind.OneTime, 50, 25, 0);
        token.mint(payer, 100e6);
        _pay(makeAddr("m"), 100e6, "a");
        assertEq(token.balanceOf(feeWallet), 0.5e6);
    }

    function test_replayRefused() public {
        token.mint(payer, 2e6);
        _pay(makeAddr("m"), 1e6, "a");
        bytes32 id = splitter.paymentId(address(token), makeAddr("m"), 1e6, "a");
        assertTrue(splitter.isPaymentProcessed(address(token), makeAddr("m"), 1e6, "a"));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(P2FluxSplitterV2.PaymentAlreadyProcessed.selector, id));
        splitter.pay(address(token), makeAddr("m"), 1e6, "a");
    }

    function test_guards() public {
        vm.startPrank(payer);
        vm.expectRevert(P2FluxSplitterV2.TokenNotSupported.selector);
        splitter.pay(address(0xBEEF), makeAddr("m"), 1e6, "a");
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        splitter.pay(address(token), address(0), 1e6, "a");
        vm.expectRevert(P2FluxSplitterV2.ZeroAmount.selector);
        splitter.pay(address(token), makeAddr("m"), 0, "a");
        vm.expectRevert(P2FluxSplitterV2.TokenNotSupported.selector);
        splitter.payWithPermit(address(0xBEEF), makeAddr("m"), 1e6, "a", 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_constructorGuards() public {
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new P2FluxSplitterV2(address(0), feeWallet, address(registry));
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new P2FluxSplitterV2(address(token), address(0), address(registry));
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new P2FluxSplitterV2(address(token), feeWallet, address(0));
        vm.expectRevert(P2FluxV2Base.NotAContract.selector);
        new P2FluxSplitterV2(address(0xBEEF), feeWallet, address(registry));
        vm.expectRevert(P2FluxV2Base.NotAContract.selector);
        new P2FluxSplitterV2(address(token), feeWallet, address(0xBEEF));
        address wrong = address(new EighteenDecimals());
        vm.expectRevert(P2FluxV2Base.WrongDecimals.selector);
        new P2FluxSplitterV2(wrong, feeWallet, address(registry));
    }

    function test_payWithPermit() public {
        uint256 key = 0xB0B;
        address buyer = vm.addr(key);
        token.mint(buyer, 10e6);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, buyer, address(splitter), 10e6, block.timestamp + 60);
        vm.prank(buyer);
        splitter.payWithPermit(address(token), makeAddr("m"), 10e6, "p", block.timestamp + 60, v, r, s);
        assertEq(token.balanceOf(makeAddr("m")), 9.9e6);
    }

    /// A token that returns false must not count as paid.
    function test_falseReturnTokenFails() public {
        FalseReturnToken t = new FalseReturnToken();
        P2FluxSplitterV2 s2 = new P2FluxSplitterV2(address(t), feeWallet, address(registry));
        t.mint(payer, 1e6);
        vm.prank(payer);
        t.approve(address(s2), 1e6);
        t.setFailTransfers(true);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(t)));
        s2.pay(address(t), makeAddr("m"), 1e6, "a");
        assertFalse(s2.isPaymentProcessed(address(t), makeAddr("m"), 1e6, "a"));
    }

    /// R-01 regression: paying the splitter itself is refused (it would be locked forever).
    function test_selfRecipientRefused() public {
        token.mint(payer, 100e6);
        vm.prank(payer);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        splitter.pay(address(token), address(splitter), 100e6, "oops");
    }

    /// R-04: the buyer pays their own gas here, so no fixed fee, whatever the registry's fixed fee is.
    function test_noFixedFeeWhenBuyerPaysGas() public {
        _setRate(P2FluxFeeRegistry.Kind.OneTime, 100, 75, 200_000);
        token.mint(payer, 10e6);
        _pay(makeAddr("m"), 10e6, "a");
        assertEq(token.balanceOf(makeAddr("m")), 9.9e6);
        assertEq(token.balanceOf(gasTreasury), 0);
    }
}
