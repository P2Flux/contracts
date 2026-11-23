// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test, OverpayToken} from "./V2Helpers.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxV2Base} from "../../../contracts/v2/P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";

contract SponsoredSplitterV2Test is V2Test {
    Sponsored internal splitter;

    function setUp() public {
        _v2SetUp();
        splitter = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
    }

    function _terms(address recipient, uint256 amount, bytes32 ref, uint256 networkFee)
        internal
        view
        returns (Sponsored.SponsoredPayment memory)
    {
        return Sponsored.SponsoredPayment(payer, recipient, amount, ref, networkFee, block.timestamp + 600);
    }

    function _sign(Sponsored.SponsoredPayment memory p) internal view returns (uint8, bytes32, bytes32) {
        return _signReceive(
            PAYER_KEY,
            p.payer,
            address(splitter),
            p.amount + p.networkFee,
            p.validBefore,
            splitter.authorizationNonce(p)
        );
    }

    function _settle(Sponsored.SponsoredPayment memory p) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// buyer debit == amount + networkFee; merchant == amount - fee - 0.05; exact, both tiers.
    function testFuzz_conservation(uint256 amount, uint256 networkFee, bytes32 ref, uint256 seed, bool asPartner)
        public
    {
        address recipient = asPartner ? partner : _cleanAddress(seed, address(splitter));
        amount = bound(amount, splitter.minimumAmount(recipient), 1e18);
        networkFee = bound(networkFee, 0, NETWORK_CAP);
        token.mint(payer, amount + networkFee);
        _settle(_terms(recipient, amount, ref, networkFee));

        uint256 fee = (amount * (asPartner ? ONE_TIME_PARTNER_BPS : ONE_TIME_BPS)) / 10_000;
        assertEq(token.balanceOf(payer), 0, "buyer debited exactly amount + networkFee");
        assertEq(token.balanceOf(recipient), amount - fee - FIXED_FEE, "merchant net");
        assertEq(token.balanceOf(feeWallet), fee, "fee wallet: percentage fee only");
        assertEq(token.balanceOf(gasTreasury), FIXED_FEE + networkFee, "gas side only");
        assertEq(token.balanceOf(address(splitter)), 0);
        assertGt(token.balanceOf(recipient), 0);
    }

    function test_example() public {
        token.mint(payer, 10.02e6);
        _settle(_terms(makeAddr("m"), 10e6, "a", 0.02e6));
        assertEq(token.balanceOf(makeAddr("m")), 9.85e6); // 10 - 0.10 - 0.05
        assertEq(token.balanceOf(feeWallet), 0.1e6);
        assertEq(token.balanceOf(gasTreasury), 0.07e6);
    }

    /// minimumAmount is the exact boundary for any rate inside the caps.
    function testFuzz_minimumAmountIsExact(uint16 bps, uint64 fixedFee) public {
        bps = uint16(bound(bps, 0, 200));
        fixedFee = uint64(bound(fixedFee, 0, 200_000));
        _setRate(P2FluxFeeRegistry.Kind.OneTime, bps, bps, fixedFee);
        uint256 m = splitter.minimumAmount(address(1));
        assertGt(m - (m * bps) / 10_000, fixedFee, "minimum leaves the merchant something");
        uint256 below = m - 1;
        assertLe(below - (below * bps) / 10_000, fixedFee, "one less does not");
    }

    function test_amountTooSmall() public {
        uint256 m = splitter.minimumAmount(makeAddr("m"));
        token.mint(payer, m);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), m - 1, "a", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert(Sponsored.AmountTooSmall.selector);
        splitter.payWithAuthorization(p, v, r, s);
        _settle(_terms(makeAddr("m"), m, "a", 0));
        assertEq(token.balanceOf(makeAddr("m")), 1);
    }

    function testFuzz_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), 5e6, "a", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(caller);
        vm.expectRevert(Sponsored.NotRelayer.selector);
        splitter.payWithAuthorization(p, v, r, s);
    }

    function test_guards() public {
        vm.startPrank(relayer);
        Sponsored.SponsoredPayment memory p = _terms(address(0), 5e6, "a", 0);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        splitter.payWithAuthorization(p, 0, 0, 0);
        p = _terms(makeAddr("m"), 5e6, "a", 0);
        p.payer = address(0);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        splitter.payWithAuthorization(p, 0, 0, 0);
        p = _terms(makeAddr("m"), 0, "a", 0);
        vm.expectRevert(Sponsored.ZeroAmount.selector);
        splitter.payWithAuthorization(p, 0, 0, 0);
        p = _terms(makeAddr("m"), 5e6, "a", NETWORK_CAP + 1);
        vm.expectRevert(Sponsored.NetworkFeeTooHigh.selector);
        splitter.payWithAuthorization(p, 0, 0, 0);
        vm.stopPrank();
    }

    function test_replayRefused() public {
        token.mint(payer, 20e6);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), 5e6, "a", 0);
        _settle(p);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        bytes32 id = splitter.paymentId(address(token), p.recipient, p.amount, p.ref);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Sponsored.PaymentAlreadyProcessed.selector, id));
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// The relayer cannot change any signed term: recipient, amount, ref, networkFee, payer.
    function test_relayerCannotTamper() public {
        token.mint(payer, 20e6);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), 5e6, "a", 0.01e6);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        Sponsored.SponsoredPayment[5] memory bad;
        for (uint256 i; i < 5; i++) {
            bad[i] = _terms(makeAddr("m"), 5e6, "a", 0.01e6); // fresh copy each: memory structs alias
        }
        bad[0].recipient = makeAddr("thief");
        bad[1].amount = 4e6;
        bad[2].ref = "b";
        bad[3].networkFee = 0.02e6;
        bad[4].validBefore = p.validBefore + 1;
        for (uint256 i; i < 5; i++) {
            vm.prank(relayer);
            vm.expectRevert("invalid authorization signature");
            splitter.payWithAuthorization(bad[i], v, r, s);
        }
        vm.prank(relayer);
        splitter.payWithAuthorization(p, v, r, s);
    }

    /// A fee change between quote and execution changes only the merchant's split; buyer debit same.
    function test_rateChangeDoesNotTouchBuyerDebit() public {
        token.mint(payer, 10e6);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), 10e6, "a", 0);
        p.validBefore = block.timestamp + 3 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        _setRate(P2FluxFeeRegistry.Kind.OneTime, 200, 200, 200_000);
        vm.prank(relayer);
        splitter.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(makeAddr("m")), 10e6 - 0.2e6 - 0.2e6);
    }

    function test_dustDonationDoesNotBrick() public {
        token.mint(address(splitter), 1);
        token.mint(payer, 5e6);
        _settle(_terms(makeAddr("m"), 5e6, "a", 0));
        assertEq(token.balanceOf(address(splitter)), 1);
    }

    function test_residualBalanceGuard() public {
        OverpayToken t = new OverpayToken();
        Sponsored s2 = new Sponsored(address(t), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        vm.prank(relayer);
        vm.expectRevert(Sponsored.ResidualBalance.selector);
        s2.payWithAuthorization(_terms(makeAddr("m"), 5e6, "a", 0), 0, 0, 0);
    }

    function test_blacklistedFeeWalletReverts() public {
        token.mint(payer, 5e6);
        token.setBlacklisted(feeWallet, true);
        Sponsored.SponsoredPayment memory p = _terms(makeAddr("m"), 5e6, "a", 0);
        (uint8 v, bytes32 r, bytes32 s) = _sign(p);
        vm.prank(relayer);
        vm.expectRevert();
        splitter.payWithAuthorization(p, v, r, s);
        assertEq(token.balanceOf(payer), 5e6, "nothing moved");
    }

    function test_constructorGuards() public {
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new Sponsored(address(token), feeWallet, address(0), relayer, address(registry), NETWORK_CAP);
        vm.expectRevert(P2FluxV2Base.ZeroAddress.selector);
        new Sponsored(address(token), feeWallet, gasTreasury, address(0), address(registry), NETWORK_CAP);
        vm.expectRevert(Sponsored.CapTooHigh.selector);
        new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(registry), 1e6 + 1);
    }
}
