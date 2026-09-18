// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {P2FluxSponsoredSplitter} from "../../contracts/P2FluxSponsoredSplitter.sol";

/// @notice Fuzz suite for sponsored one-time payments: the buyer is debited price + quoted network
///         fee and nothing else, every destination is fixed by the signature, and no malformed
///         submission can settle.
contract SponsoredSplitterFuzzTest is P2FluxTest {
    P2FluxSponsoredSplitter internal splitter;

    function setUp() public {
        _baseSetUp();
        splitter = new P2FluxSponsoredSplitter(
            address(token), feeWallet, gasTreasury, relayer, FIXED_NETWORK_FEE, SPONSORED_FEE_CAP
        );
    }

    function _terms(address recipient, uint256 amount, bytes32 ref, uint256 networkFee)
        internal
        view
        returns (P2FluxSponsoredSplitter.SponsoredPayment memory p)
    {
        p = P2FluxSponsoredSplitter.SponsoredPayment({
            payer: payer,
            recipient: recipient,
            amount: amount,
            ref: ref,
            networkFee: networkFee,
            validBefore: block.timestamp + 600
        });
    }

    function _sign(P2FluxSponsoredSplitter.SponsoredPayment memory p)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return _signReceive(
            PAYER_KEY,
            p.payer,
            address(splitter),
            p.amount + p.networkFee,
            p.validBefore,
            splitter.authorizationNonce(p)
        );
    }

    /// buyer outflow == merchant + P2Flux fee + fixed network fee + quoted network fee. Exactly.
    function testFuzz_conservation(uint256 amount, uint256 networkFee, bytes32 ref, uint256 recipientSeed) public {
        amount = bound(amount, splitter.minimumAmount(), 1e15);
        networkFee = bound(networkFee, 0, SPONSORED_FEE_CAP);
        address recipient = _cleanAddress(recipientSeed, address(splitter));
        token.mint(payer, amount + networkFee);

        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(recipient, amount, ref, networkFee);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        splitter.payWithAuthorization(p, v, r, s);

        uint256 fee = (amount * 100) / 10_000;
        assertEq(token.balanceOf(payer), 0, "buyer debited exactly amount + networkFee");
        assertEq(token.balanceOf(recipient), amount - fee - FIXED_NETWORK_FEE, "merchant net");
        assertEq(token.balanceOf(feeWallet), fee, "profit fee only");
        assertEq(token.balanceOf(gasTreasury), networkFee + FIXED_NETWORK_FEE, "gas side only");
        assertEq(token.balanceOf(address(splitter)), 0, "custody lasted one transaction");
        assertGt(token.balanceOf(recipient), 0, "merchant is never left with nothing");
    }

    /// Anything that is not the relayer is refused before any value moves.
    function testFuzz_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        uint256 amount = 5e6;
        token.mint(payer, amount);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), amount, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(caller);
        vm.expectRevert(P2FluxSponsoredSplitter.NotRelayer.selector);
        splitter.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(payer), amount);
    }

    /// No quote, however signed, can carry more than the hard cap on top of the price.
    function testFuzz_networkFeeAboveCapRefused(uint256 networkFee) public {
        networkFee = bound(networkFee, SPONSORED_FEE_CAP + 1, type(uint128).max);
        uint256 amount = 5e6;
        token.mint(payer, amount + networkFee);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), amount, "ref", networkFee);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert(P2FluxSponsoredSplitter.NetworkFeeTooHigh.selector);
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// Below the minimum the merchant would receive nothing: refused, never silently settled.
    function testFuzz_amountBelowMinimumRefused(uint256 amount) public {
        uint256 minimum = splitter.minimumAmount();
        amount = bound(amount, 1, minimum - 1);
        token.mint(payer, amount);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), amount, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert(P2FluxSponsoredSplitter.AmountTooSmall.selector);
        splitter.payWithAuthorization(p, v, r, s);
    }

    function test_minimumAmount_isTheExactBoundary() public view {
        uint256 minimum = splitter.minimumAmount();
        uint256 feeAtMin = (minimum * 100) / 10_000;
        assertGt(minimum, feeAtMin + FIXED_NETWORK_FEE, "minimum itself settles");
        uint256 below = minimum - 1;
        assertLe(below, (below * 100) / 10_000 + FIXED_NETWORK_FEE, "one unit less does not");
    }

    /// The signature binds every term: submit anything other than what was signed and the token refuses.
    function testFuzz_tamperedTermsRefused(uint8 field, uint256 delta) public {
        uint256 amount = 50e6;
        uint256 networkFee = 4_000;
        token.mint(payer, 1e12);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), amount, "ref", networkFee);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);

        delta = bound(delta, 1, 100_000);
        field = uint8(bound(field, 0, 4));
        if (field == 0) p.recipient = makeAddr("attacker");
        if (field == 1) p.amount = amount + delta;
        if (field == 2) {
            p.networkFee = (networkFee + delta) % (SPONSORED_FEE_CAP + 1) == networkFee
                ? networkFee + 1
                : (networkFee + delta) % (SPONSORED_FEE_CAP + 1);
        }
        if (field == 3) p.ref = bytes32(delta);
        if (field == 4) p.validBefore = p.validBefore + delta;

        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(makeAddr("attacker")), 0, "nothing reaches a substituted recipient");
        assertEq(token.balanceOf(payer), 1e12, "buyer untouched");
    }

    function testFuzz_wrongSignerRefused(uint256 key) public {
        key = bound(key, 1, type(uint128).max);
        vm.assume(key != PAYER_KEY);
        token.mint(payer, 5e6);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), 5e6, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(key, p.payer, address(splitter), p.amount, p.validBefore, splitter.authorizationNonce(p));
        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// The nonce commits to the chain id, so a signature made for one chain is dead on another.
    function testFuzz_wrongChainRefused(uint64 otherChain) public {
        vm.assume(otherChain != block.chainid && otherChain != 0);
        token.mint(payer, 5e6);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), 5e6, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.chainId(otherChain);
        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
    }

    function test_replayRefused_andAuthorizationSingleUse() public {
        token.mint(payer, 20e6);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), 5e6, "ref", 1_000);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.startPrank(relayer);
        splitter.payWithAuthorization(p, v, r, s);
        bytes32 id = splitter.paymentId(address(token), p.recipient, p.amount, p.ref);
        vm.expectRevert(abi.encodeWithSelector(P2FluxSponsoredSplitter.PaymentAlreadyProcessed.selector, id));
        splitter.payWithAuthorization(p, v, r, s);
        vm.stopPrank();
        assertTrue(token.authorizationState(payer, splitter.authorizationNonce(p)));
    }

    function test_expiredQuoteRefused() public {
        token.mint(payer, 5e6);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), 5e6, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.warp(p.validBefore);
        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// Insufficient funds cannot settle as valid, and leave the intent payable.
    function testFuzz_insufficientBalanceRefused(uint256 shortfall) public {
        uint256 amount = 5e6;
        shortfall = bound(shortfall, 1, amount);
        token.mint(payer, amount - shortfall);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), amount, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
        assertFalse(splitter.isPaymentProcessed(address(token), p.recipient, amount, p.ref));
    }

    /// Dust donated to the contract must neither brick it nor leak out of it.
    function testFuzz_donatedDustIsInert(uint256 dust) public {
        dust = bound(dust, 1, 1e12);
        token.mint(address(splitter), dust);
        token.mint(payer, 5e6);
        P2FluxSponsoredSplitter.SponsoredPayment memory p = _terms(makeAddr("merchant"), 5e6, "ref", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        splitter.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(address(splitter)), dust, "donation neither spent nor grown");
    }
}
