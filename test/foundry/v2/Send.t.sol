// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test, OverpayToken} from "./V2Helpers.sol";
import {P2FluxSend} from "../../../contracts/v2/P2FluxSend.sol";
import {P2FluxV2Base} from "../../../contracts/v2/P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";

contract SendTest is V2Test {
    P2FluxSend internal sender;

    function setUp() public {
        _v2SetUp();
        sender = new P2FluxSend(address(token), feeWallet, gasTreasury, relayer, address(registry));
        vm.prank(payer);
        token.approve(address(sender), type(uint256).max);
    }

    function _relayed(address to, uint256 amount, bytes32 ref) internal view returns (P2FluxSend.RelayedSend memory) {
        return P2FluxSend.RelayedSend(payer, to, amount, ref, block.timestamp + 600);
    }

    function _sign(P2FluxSend.RelayedSend memory s, uint256 value) internal view returns (uint8, bytes32, bytes32) {
        return _signReceive(PAYER_KEY, s.from, address(sender), value, s.validBefore, sender.authorizationNonce(s));
    }

    function _total(P2FluxSend.RelayedSend memory s) internal view returns (uint256) {
        (uint256 fee, uint256 fixedFee) = sender.quote(s.amount);
        return s.amount + fee + fixedFee;
    }

    // --- direct ---

    /// Receiver gets exactly `amount`; sender pays amount + 0.1% on top; fee wallet gets the 0.1%.
    function testFuzz_direct_exact(uint256 amount, uint256 seed, bytes32 ref) public {
        amount = bound(amount, 1e6, 1e18);
        address to = _cleanV2(seed, address(sender));
        uint256 fee = (amount * SEND_BPS) / 10_000;
        token.mint(payer, amount + fee);
        vm.prank(payer);
        sender.send(to, amount, fee, ref);
        assertEq(token.balanceOf(to), amount, "receiver gets the exact amount");
        assertEq(token.balanceOf(payer), 0, "sender paid amount + fee");
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(gasTreasury), 0, "no fixed fee when the sender pays gas");
        assertEq(token.balanceOf(address(sender)), 0);
    }

    function test_direct_example() public {
        token.mint(payer, 100.1e6);
        vm.prank(payer);
        sender.send(makeAddr("bob"), 100e6, 0.1e6, "x");
        assertEq(token.balanceOf(makeAddr("bob")), 100e6);
        assertEq(token.balanceOf(feeWallet), 0.1e6);
    }

    /// The direct path never takes more fee than the sender capped, even if the rate changed.
    function test_direct_maxFeeGuard() public {
        token.mint(payer, 200e6);
        _setRate(P2FluxFeeRegistry.Kind.Send, 20, 20, FIXED_FEE);
        vm.prank(payer);
        vm.expectRevert(P2FluxSend.FeeAboveMax.selector);
        sender.send(makeAddr("bob"), 100e6, 0.1e6, "x");
    }

    function test_direct_guards() public {
        vm.startPrank(payer);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        sender.send(address(0), 1e6, 1e6, "x");
        vm.expectRevert(P2FluxSend.AmountTooSmall.selector);
        sender.send(makeAddr("bob"), 1e6 - 1, 1e6, "x");
        vm.stopPrank();
    }

    function test_direct_minimumIsOneUsdc() public {
        token.mint(payer, 1.001e6);
        vm.prank(payer);
        sender.send(makeAddr("bob"), 1e6, 1000, "x");
        assertEq(token.balanceOf(makeAddr("bob")), 1e6);
        assertEq(token.balanceOf(feeWallet), 1000);
    }

    function test_sendWithPermit() public {
        uint256 key = 0xB0B;
        address alice = vm.addr(key);
        token.mint(alice, 10.01e6);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, alice, address(sender), 10.01e6, block.timestamp + 60);
        vm.prank(alice);
        sender.sendWithPermit(makeAddr("bob"), 10e6, 0.01e6, "p", block.timestamp + 60, v, r, s);
        assertEq(token.balanceOf(makeAddr("bob")), 10e6);
        assertEq(token.balanceOf(alice), 0);
    }

    // --- relayed ---

    /// Receiver exact; sender debit = amount + 0.1% + 0.05; destinations exact.
    function testFuzz_relayed_exact(uint256 amount, uint256 seed, bytes32 ref) public {
        amount = bound(amount, 1e6, 1e18);
        address to = _cleanV2(seed, address(sender));
        P2FluxSend.RelayedSend memory s = _relayed(to, amount, ref);
        uint256 total = _total(s);
        token.mint(payer, total);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(s, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        uint256 fee = (amount * SEND_BPS) / 10_000;
        assertEq(total, amount + fee + FIXED_FEE, "no gas quote on top of the fixed fee");
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(gasTreasury), FIXED_FEE);
        assertEq(token.balanceOf(address(sender)), 0);
    }

    function test_relayed_example() public {
        P2FluxSend.RelayedSend memory s = _relayed(makeAddr("bob"), 100e6, "x");
        uint256 total = _total(s);
        assertEq(total, 100e6 + 0.1e6 + 0.05e6);
        token.mint(payer, total);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(s, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        assertEq(token.balanceOf(makeAddr("bob")), 100e6);
    }

    /// A rate change after signing invalidates the signature: the sender is never charged a fee
    /// they did not sign for.
    function test_relayed_rateChangeInvalidatesSignature() public {
        P2FluxSend.RelayedSend memory s = _relayed(makeAddr("bob"), 100e6, "x");
        s.validBefore = block.timestamp + 3 days;
        uint256 total = _total(s);
        token.mint(payer, 1000e6);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(s, total);
        _setRate(P2FluxFeeRegistry.Kind.Send, 20, 20, FIXED_FEE);
        vm.prank(relayer);
        vm.expectRevert("invalid authorization signature");
        sender.sendWithAuthorization(s, v, r, sig);
    }

    function test_relayed_replayRefused() public {
        P2FluxSend.RelayedSend memory s = _relayed(makeAddr("bob"), 5e6, "x");
        uint256 total = _total(s);
        token.mint(payer, 2 * total);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(s, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        vm.prank(relayer);
        vm.expectRevert("authorization is used or canceled");
        sender.sendWithAuthorization(s, v, r, sig);
    }

    function test_relayed_cannotTamper() public {
        P2FluxSend.RelayedSend memory s = _relayed(makeAddr("bob"), 5e6, "x");
        token.mint(payer, 100e6);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(s, _total(s));
        P2FluxSend.RelayedSend memory bad = s;
        bad.to = makeAddr("thief");
        vm.prank(relayer);
        vm.expectRevert("invalid authorization signature");
        sender.sendWithAuthorization(bad, v, r, sig);
        bad = _relayed(makeAddr("bob"), 5e6, "y");
        vm.prank(relayer);
        vm.expectRevert("invalid authorization signature");
        sender.sendWithAuthorization(bad, v, r, sig);
    }

    function testFuzz_relayed_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        vm.prank(caller);
        vm.expectRevert(P2FluxSend.NotRelayer.selector);
        sender.sendWithAuthorization(_relayed(makeAddr("bob"), 5e6, "x"), 0, 0, 0);
    }

    function test_relayed_guards() public {
        vm.startPrank(relayer);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        sender.sendWithAuthorization(_relayed(address(0), 5e6, "x"), 0, 0, 0);
        P2FluxSend.RelayedSend memory s = _relayed(makeAddr("bob"), 5e6, "x");
        s.from = address(0);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        sender.sendWithAuthorization(s, 0, 0, 0);
        vm.expectRevert(P2FluxSend.AmountTooSmall.selector);
        sender.sendWithAuthorization(_relayed(makeAddr("bob"), 1e6 - 1, "x"), 0, 0, 0);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        sender.sendWithAuthorization(_relayed(address(sender), 5e6, "x"), 0, 0, 0);
        vm.stopPrank();
    }

    function test_residualBalanceGuard() public {
        OverpayToken t = new OverpayToken();
        P2FluxSend s2 = new P2FluxSend(address(t), feeWallet, gasTreasury, relayer, address(registry));
        vm.prank(relayer);
        vm.expectRevert(P2FluxSend.ResidualBalance.selector);
        s2.sendWithAuthorization(_relayed(makeAddr("bob"), 5e6, "x"), 0, 0, 0);
    }

    function test_constructorGuards() public {
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new P2FluxSend(address(token), feeWallet, address(0), relayer, address(registry));
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new P2FluxSend(address(token), feeWallet, gasTreasury, address(0), address(registry));
    }

    /// R-01 regression: sending to the Send contract itself is refused (it would be locked forever).
    function test_direct_selfRecipientRefused() public {
        token.mint(payer, 101e6);
        vm.prank(payer);
        vm.expectRevert(P2FluxV2Base.InvalidRecipient.selector);
        sender.send(address(sender), 100e6, 0.1e6, "oops");
    }
}
