// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "./V2Helpers.sol";
import {P2FluxPaymentsV2 as Payments} from "../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxSponsoredSplitter} from "../../../contracts/P2FluxSponsoredSplitter.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";

/// @notice The reason the two entrances live in one contract: an order paid through either one can
///         never be paid again through the other, in any order, in the same block or later.
contract PaymentsCrossEntranceTest is V2Test {
    Payments internal payments;
    address internal merchant = makeAddr("merchant");

    function setUp() public {
        _v2SetUp();
        payments = new Payments(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        vm.prank(payer);
        token.approve(address(payments), type(uint256).max);
    }

    function _terms(address recipient, uint256 amount, bytes32 ref, uint256 networkFee)
        internal
        view
        returns (Payments.SponsoredPayment memory)
    {
        return Payments.SponsoredPayment(payer, recipient, amount, ref, networkFee, block.timestamp + 600);
    }

    function _sign(Payments.SponsoredPayment memory p) internal view returns (uint8, bytes32, bytes32) {
        return _signReceive(
            PAYER_KEY,
            p.payer,
            address(payments),
            p.amount + p.networkFee,
            p.validBefore,
            payments.authorizationNonce(p)
        );
    }

    function _selfPay(address recipient, uint256 amount, bytes32 ref) internal {
        vm.prank(payer);
        payments.pay(address(token), recipient, amount, ref);
    }

    function _sponsor(Payments.SponsoredPayment memory p) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        payments.payWithAuthorization(p, v, r, s);
    }

    function _id(address recipient, uint256 amount, bytes32 ref) internal view returns (bytes32) {
        return payments.paymentId(address(token), recipient, amount, ref);
    }

    // --- the two orders -----------------------------------------------------------------------

    function test_selfPaidThenSponsoredReverts() public {
        token.mint(payer, 20.02e6);
        uint256 b0 = block.number;
        _selfPay(merchant, 10e6, "order-1");

        Payments.SponsoredPayment memory p = _terms(merchant, 10e6, "order-1", 0.02e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        bytes32 id = _id(merchant, 10e6, "order-1");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, id));
        payments.payWithAuthorization(p, v, r, s);

        assertEq(block.number, b0, "same block");
        assertEq(token.balanceOf(merchant), 9.9e6, "paid exactly once");
        assertEq(token.balanceOf(payer), 10.02e6, "second debit never happened");
        assertFalse(token.authorizationState(payer, payments.authorizationNonce(p)), "buyer signature not consumed");
    }

    function test_sponsoredThenSelfPaidReverts() public {
        token.mint(payer, 20.02e6);
        uint256 b0 = block.number;
        _sponsor(_terms(merchant, 10e6, "order-2", 0.02e6));

        bytes32 id = _id(merchant, 10e6, "order-2");
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, id));
        payments.pay(address(token), merchant, 10e6, "order-2");

        assertEq(block.number, b0, "same block");
        assertEq(token.balanceOf(merchant), 10e6 - 0.1e6 - 0.05e6, "paid exactly once, sponsored split");
        assertEq(token.balanceOf(payer), 10e6, "second debit never happened");
    }

    function test_permitEntranceAlsoShared() public {
        uint256 key = 0xB0B;
        address buyer = vm.addr(key);
        token.mint(buyer, 10e6);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(key, buyer, address(payments), 10e6, block.timestamp + 60);
        vm.prank(buyer);
        payments.payWithPermit(address(token), merchant, 10e6, "order-3", block.timestamp + 60, v, r, s);

        token.mint(payer, 10e6);
        Payments.SponsoredPayment memory p = _terms(merchant, 10e6, "order-3", 0);
        (v, r, s) = _sign(p);
        bytes32 id = _id(merchant, 10e6, "order-3");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, id));
        payments.payWithAuthorization(p, v, r, s);
    }

    /// A second attempt through the SAME entrance is refused too (no regression of v1 replay).
    function test_sameEntranceReplayStillRefused() public {
        token.mint(payer, 40e6);
        _selfPay(merchant, 10e6, "a");
        bytes32 idA = _id(merchant, 10e6, "a");
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, idA));
        payments.pay(address(token), merchant, 10e6, "a");

        Payments.SponsoredPayment memory p = _terms(merchant, 10e6, "b", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        payments.payWithAuthorization(p, v, r, s);
        bytes32 idB = _id(merchant, 10e6, "b");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, idB));
        payments.payWithAuthorization(p, v, r, s);
    }

    /// The order is identified by its full terms, so an attacker cannot block an order by paying
    /// the same ref with other terms (cheap amount, own recipient).
    function test_refAloneCannotBlockAnOrder() public {
        address attacker = makeAddr("attacker");
        token.mint(attacker, 1e6);
        vm.startPrank(attacker);
        token.approve(address(payments), type(uint256).max);
        payments.pay(address(token), attacker, 1, "order-4"); // same ref, other recipient and amount
        payments.pay(address(token), merchant, 1, "order-4"); // same ref and recipient, other amount
        vm.stopPrank();

        token.mint(payer, 10e6);
        _sponsor(_terms(merchant, 10e6, "order-4", 0));
        assertTrue(payments.isPaymentProcessed(address(token), merchant, 10e6, "order-4"));
    }

    /// Fuzz: any amount, any network fee, either order, either tier. Exactly one settlement.
    function testFuzz_crossEntranceExactlyOnce(
        uint256 amount,
        uint256 networkFee,
        bytes32 ref,
        bool sponsoredFirst,
        bool asPartner
    ) public {
        address recipient = asPartner ? partner : merchant;
        amount = bound(amount, payments.minimumAmount(recipient), 1e15);
        networkFee = bound(networkFee, 0, NETWORK_CAP);
        token.mint(payer, 2 * amount + networkFee);
        Payments.SponsoredPayment memory p = _terms(recipient, amount, ref, networkFee);
        if (sponsoredFirst) _sponsoredThenSelf(p);
        else _selfThenSponsored(p);

        uint256 fee = amount * (asPartner ? ONE_TIME_PARTNER_BPS : ONE_TIME_BPS) / 10_000;
        uint256 fixedSide = sponsoredFirst ? FIXED_FEE : 0;
        uint256 gasSide = sponsoredFirst ? FIXED_FEE + networkFee : 0;
        assertEq(token.balanceOf(recipient), amount - fee - fixedSide, "merchant paid once");
        assertEq(token.balanceOf(gasTreasury), gasSide, "fixed fee only on sponsored");
        assertEq(token.balanceOf(payer), sponsoredFirst ? amount : amount + networkFee, "buyer debited once");
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(address(payments)), 0);
    }

    function _dup(Payments.SponsoredPayment memory p) internal view returns (bytes memory) {
        return abi.encodeWithSelector(Payments.PaymentAlreadyProcessed.selector, _id(p.recipient, p.amount, p.ref));
    }

    function _sponsoredThenSelf(Payments.SponsoredPayment memory p) internal {
        _sponsor(p);
        bytes memory dup = _dup(p);
        vm.prank(payer);
        vm.expectRevert(dup);
        payments.pay(address(token), p.recipient, p.amount, p.ref);
    }

    function _selfThenSponsored(Payments.SponsoredPayment memory p) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        _selfPay(p.recipient, p.amount, p.ref);
        bytes memory dup = _dup(p);
        vm.prank(relayer);
        vm.expectRevert(dup);
        payments.payWithAuthorization(p, v, r, s);
    }

    /// The fixed fee appears only on the sponsored entrance, for the same order terms.
    function test_fixedFeeOnlyOnSponsored() public {
        token.mint(payer, 20e6);
        _selfPay(merchant, 10e6, "x");
        assertEq(token.balanceOf(merchant), 9.9e6);
        assertEq(token.balanceOf(gasTreasury), 0);
        _sponsor(_terms(merchant, 10e6, "y", 0));
        assertEq(token.balanceOf(merchant), 9.9e6 + 9.85e6);
        assertEq(token.balanceOf(gasTreasury), 0.05e6);
    }

    // --- signature domains --------------------------------------------------------------------

    /// A buyer signature made for the v1 sponsored splitter (V1 nonce domain, v1 address) never
    /// settles on v2, even for identical terms.
    function test_v1SponsoredSignatureRefused() public {
        P2FluxSponsoredSplitter v1 =
            new P2FluxSponsoredSplitter(address(token), feeWallet, gasTreasury, relayer, 100_000, NETWORK_CAP);
        P2FluxSponsoredSplitter.SponsoredPayment memory p1 =
            P2FluxSponsoredSplitter.SponsoredPayment(payer, merchant, 10e6, "v1", 0, block.timestamp + 600);
        bytes32 n1 = v1.authorizationNonce(p1);
        // Even signed to the v2 address with the v1 nonce, the v2 nonce differs: refused.
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(PAYER_KEY, payer, address(payments), 10e6, p1.validBefore, n1);
        token.mint(payer, 10e6);
        vm.prank(relayer);
        vm.expectRevert(bytes("invalid authorization signature"));
        payments.payWithAuthorization(_terms(merchant, 10e6, "v1", 0), v, r, s);
        assertTrue(payments.authorizationNonce(_terms(merchant, 10e6, "v1", 0)) != n1);
    }

    /// A self-pay permit gives the contract an allowance, but the sponsored entrance never uses
    /// allowances: the relayer cannot turn a buyer's leftover allowance into a sponsored payment.
    function test_leftoverAllowanceNotUsableBySponsoredEntrance() public {
        token.mint(payer, 100e6); // payer approved max in setUp
        Payments.SponsoredPayment memory p = _terms(merchant, 10e6, "z", 0);
        vm.prank(relayer);
        vm.expectRevert(); // no valid EIP-3009 signature: nothing can move
        payments.payWithAuthorization(p, 27, bytes32(0), bytes32(0));
        assertEq(token.balanceOf(payer), 100e6);
    }

    /// The same order hit through both entrances in one block, in a random order, by different
    /// callers (buyer, relayer): exactly one wins, the other is refused, whatever the rates.
    function testFuzz_sameBlockRandomOrderWithRateChange(bool sponsoredFirst, uint16 bps, uint64 fixedFee) public {
        bps = uint16(bound(bps, 0, 200));
        fixedFee = uint64(bound(fixedFee, 0, 200_000));
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, bps, fixedFee);
        token.mint(payer, 20e6);
        Payments.SponsoredPayment memory p = _terms(merchant, 10e6, "blk", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        uint256 blockBefore = block.number;
        uint256 wins;
        for (uint256 k; k < 2; k++) {
            bool doSponsored = (k == 0) == sponsoredFirst;
            if (doSponsored) {
                vm.prank(relayer);
                try payments.payWithAuthorization(p, v, r, s) {
                    wins++;
                } catch {}
            } else {
                vm.prank(payer);
                try payments.pay(address(token), merchant, 10e6, "blk") {
                    wins++;
                } catch {}
            }
        }
        assertEq(block.number, blockBefore);
        assertEq(wins, 1);
        uint256 fee = 10e6 * uint256(bps) / 10_000;
        assertEq(token.balanceOf(merchant), sponsoredFirst ? 10e6 - fee - fixedFee : 10e6 - fee);
    }
}
