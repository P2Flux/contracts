// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "../V2Helpers.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";

/// @dev A 1271 "wallet" that says yes to everything (a buggy wallet / 7702 delegate).
contract YesWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice Review 3b (27 Nov 2026): adversarial checks of RecurringV2 + Send before mainnet.
contract Review3bTest is V2Test {
    Recurring internal recurring;
    P2FluxSend internal sender;
    uint256 internal constant GAS_CAP = 50_000; // as script/DeployV2.s.sol
    address internal merchant = makeAddr("merchant");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        _v2SetUp();
        recurring = new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        sender = new P2FluxSend(address(token), feeWallet, gasTreasury, relayer, address(registry));
        token.mint(payer, 1_000_000e6);
        vm.startPrank(payer);
        token.approve(address(recurring), type(uint256).max);
        token.approve(address(sender), type(uint256).max);
        vm.stopPrank();
    }

    function _a(uint256 amount, uint48 period, uint48 start, uint48 end, uint256 maxGas)
        internal
        view
        returns (Recurring.RecurringAuthorization memory)
    {
        return Recurring.RecurringAuthorization(
            payer, merchant, address(token), amount, period, start, end, bytes32(uint256(7)), maxGas
        );
    }

    function _sig(Recurring.RecurringAuthorization memory a) internal view returns (bytes memory) {
        return _signDigest(PAYER_KEY, recurring.subscriptionId(a));
    }

    // ---------------------------------------------------------------- findings

    /// F1: no minimum period. One signed "10 USDC, period = 1" + unlimited allowance = 10 USDC per
    ///     second, by anyone, forever. 600 USDC gone in one minute.
    function test_F1_periodOneSecondDrains() public {
        Recurring.RecurringAuthorization memory a = _a(10e6, 1, uint48(block.timestamp), 0, 0);
        bytes memory sig = _sig(a);
        uint256 before = token.balanceOf(payer);
        for (uint256 i; i < 60; i++) {
            vm.prank(merchant);
            recurring.charge(a, sig, 0);
            vm.warp(block.timestamp + 1);
        }
        assertEq(before - token.balanceOf(payer), 600e6);
    }

    /// F2: a back-dated start puts a period boundary anywhere: two full charges 1 second apart,
    ///     right after signing a "monthly" subscription.
    function test_F2_backdatedStartDoubleChargeAtSigning() public {
        Recurring.RecurringAuthorization memory a =
            _a(100e6, 30 days, uint48(block.timestamp - 30 days + 1), 0, 0);
        bytes memory sig = _sig(a);
        uint256 before = token.balanceOf(payer);
        vm.prank(merchant);
        recurring.charge(a, sig, 0);
        vm.warp(block.timestamp + 1);
        vm.prank(merchant);
        recurring.charge(a, sig, 0);
        assertEq(before - token.balanceOf(payer), 200e6);
    }

    /// F3: the signature is public after the first charge; anyone charges every later period
    ///     until the payer revokes ON CHAIN. An off-chain "cancel" stops nothing. Funds go only
    ///     to the signed recipient. A front-running stranger/merchant also strips P2Flux's fixed
    ///     fee and reimbursement, and the relayer's own transaction reverts.
    function test_F3_publicSignatureChargedByStranger_andFixedFeeBypass() public {
        Recurring.RecurringAuthorization memory a = _a(100e6, 30 days, uint48(block.timestamp), 0, GAS_CAP);
        bytes memory sig = _sig(a);
        vm.prank(relayer);
        recurring.charge(a, sig, GAS_CAP);
        uint256 treasuryAfterFirst = token.balanceOf(gasTreasury);
        assertEq(treasuryAfterFirst, FIXED_FEE + GAS_CAP);

        vm.warp(block.timestamp + 30 days);
        uint256 m = token.balanceOf(merchant);
        uint256 p = token.balanceOf(payer);
        vm.prank(stranger);
        recurring.charge(a, sig, GAS_CAP); // reimbursement ignored
        assertEq(p - token.balanceOf(payer), 100e6);
        assertEq(token.balanceOf(merchant) - m, 100e6 - 1.5e6); // no fixed fee: merchant +0.05
        assertEq(token.balanceOf(gasTreasury), treasuryAfterFirst);
        assertEq(token.balanceOf(stranger), 0);

        vm.prank(relayer);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, GAS_CAP);
    }

    /// F4: a payer whose account answers ERC-1271 with "yes" to everything (buggy wallet) can be
    ///     charged ANY terms by anyone, with no signature. Not a contract bug; stated so the API
    ///     never relies on isValidAuthorization as proof of consent for unknown wallet code.
    function test_F4_alwaysYesWalletChargedWithoutConsent() public {
        YesWallet w = new YesWallet();
        token.mint(address(w), 1000e6);
        vm.prank(address(w));
        token.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            address(w), stranger, address(token), 1000e6, 1, uint48(block.timestamp), 0, 0, 0
        );
        vm.prank(stranger);
        recurring.charge(a, hex"", 0);
        assertEq(token.balanceOf(address(w)), 0);
    }

    // ------------------------------------------------------------ invariants

    /// I1: whatever the registry says (within caps) and whoever calls, the payer is debited exactly
    ///     amount + reimbursement, reimbursement <= min(signed, hard cap) and only for the relayer.
    function testFuzz_I1_payerDebitBounded(uint256 amount, uint16 bps, uint64 fixedFee, uint256 maxGas, uint256 asked, bool byRelayer)
        public
    {
        amount = bound(amount, 1, 1_000_000e6);
        _setRate(P2FluxFeeRegistry.Kind.Recurring, bound(bps, 0, 200), 0, bound(fixedFee, 0, 0.2e6));
        Recurring.RecurringAuthorization memory a = _a(amount, 30 days, uint48(block.timestamp), 0, maxGas);
        bytes memory sig = _sig(a);
        uint256 p = token.balanceOf(payer);
        vm.prank(byRelayer ? relayer : stranger);
        try recurring.charge(a, sig, asked) {
            uint256 reimb = byRelayer ? asked : 0;
            assertEq(p - token.balanceOf(payer), amount + reimb);
            assertLe(reimb, maxGas);
            assertLe(reimb, GAS_CAP);
            _merchantFloor(amount);
        } catch {
            assertEq(token.balanceOf(payer), p);
        }
    }

    function _merchantFloor(uint256 amount) internal view {
        uint256 got = token.balanceOf(merchant);
        assertGt(got, 0);
        if (amount > (amount * 200) / 10_000 + 0.2e6) assertGe(got, amount - (amount * 200) / 10_000 - 0.2e6);
        assertEq(token.balanceOf(address(recurring)), 0);
    }

    /// I2: boundaries. Not before start; at start; once per period; at end-1 yes, at end no; no backfill.
    function test_I2_periodBoundaries() public {
        uint48 start = uint48(block.timestamp + 100);
        Recurring.RecurringAuthorization memory a = _a(5e6, 1000, start, start + 2500, 0);
        bytes memory sig = _sig(a);
        vm.warp(start - 1);
        vm.expectRevert(Recurring.NotStarted.selector);
        recurring.charge(a, sig, 0);
        vm.warp(start);
        recurring.charge(a, sig, 0);
        vm.warp(start + 999);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
        // skip period 1 entirely: no backfill, period 2 is charged once
        vm.warp(start + 2499);
        recurring.charge(a, sig, 0);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
        vm.warp(start + 2500);
        vm.expectRevert(Recurring.Expired.selector);
        recurring.charge(a, sig, 0);
        assertEq(token.balanceOf(merchant), 2 * (5e6 - 75_000));
    }

    /// I3: any single changed term, another contract instance, or another chain kills the signature.
    function test_I3_signatureBoundToEveryTerm() public {
        Recurring.RecurringAuthorization memory a = _a(5e6, 1000, uint48(block.timestamp), 0, 10);
        bytes memory sig = _sig(a);
        Recurring.RecurringAuthorization memory b;
        b = _a(5e6, 1000, uint48(block.timestamp), 0, 10); b.recipient = stranger; _refused(b, sig);
        b = _a(5e6 + 1, 1000, uint48(block.timestamp), 0, 10); _refused(b, sig);
        b = _a(5e6, 999, uint48(block.timestamp), 0, 10); _refused(b, sig);
        b = _a(5e6, 1000, uint48(block.timestamp - 1), 0, 10); _refused(b, sig);
        b = _a(5e6, 1000, uint48(block.timestamp), uint48(block.timestamp + 5000), 10); _refused(b, sig);
        b = _a(5e6, 1000, uint48(block.timestamp), 0, 11); _refused(b, sig);
        b = _a(5e6, 1000, uint48(block.timestamp), 0, 10); b.salt = bytes32(uint256(8)); _refused(b, sig);
        b = _a(5e6, 1000, uint48(block.timestamp), 0, 10); b.payer = stranger; _refused(b, sig);

        Recurring other =
            new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        vm.prank(payer);
        token.approve(address(other), type(uint256).max);
        vm.expectRevert(Recurring.InvalidSignature.selector);
        other.charge(a, sig, 0);

        vm.chainId(1);
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);
        vm.chainId(31337);

        // malleated (high-s) and compact 64-byte forms are refused; the original still works
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory mal = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, mal, 0);
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(a, abi.encodePacked(r, vs), 0);
        recurring.charge(a, sig, 0);
    }

    function _refused(Recurring.RecurringAuthorization memory b, bytes memory sig) internal {
        vm.expectRevert(Recurring.InvalidSignature.selector);
        recurring.charge(b, sig, 0);
    }

    /// I4: revoke - only the payer; works before start; wins when mined first; a failed transfer
    ///     (allowance 0) leaves the period chargeable (state not stuck).
    function test_I4_revokeAndFailedTransfer() public {
        Recurring.RecurringAuthorization memory a = _a(5e6, 1000, uint48(block.timestamp + 50), 0, 0);
        bytes memory sig = _sig(a);
        vm.prank(merchant);
        vm.expectRevert(Recurring.NotPayer.selector);
        recurring.revoke(a);
        vm.prank(payer);
        recurring.revoke(a); // before start
        vm.warp(block.timestamp + 50);
        vm.expectRevert(Recurring.Revoked.selector);
        recurring.charge(a, sig, 0);

        Recurring.RecurringAuthorization memory c = _a(6e6, 1000, uint48(block.timestamp), 0, 0);
        bytes memory sigC = _sig(c);
        vm.prank(payer);
        token.approve(address(recurring), 0);
        vm.expectRevert();
        recurring.charge(c, sigC, 0);
        assertEq(recurring.lastChargedPeriodPlusOne(recurring.subscriptionId(c)), 0);
        vm.prank(payer);
        token.approve(address(recurring), 6e6);
        recurring.charge(c, sigC, 0);
        assertEq(token.allowance(payer, address(recurring)), 0);
    }

    /// I5: EIP-7702 designator account: own key accepted, another key refused.
    function test_I5_7702OwnKeyOnly() public {
        vm.etch(payer, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        Recurring.RecurringAuthorization memory a = _a(5e6, 1000, uint48(block.timestamp), 0, 0);
        assertTrue(recurring.isValidAuthorization(a, _sig(a)));
        assertFalse(recurring.isValidAuthorization(a, _signDigest(0xB0B, recurring.subscriptionId(a))));
    }

    /// I6: admin (or a stolen relayer key) gains nothing: the reimbursement is capped at 0.05 USDC
    ///     per subscription per period and lands in the immutable gas treasury, never the caller.
    function test_I6_relayerCompromiseBound() public {
        address evil = makeAddr("evil");
        vm.prank(admin);
        recurring.setRelayer(evil);
        Recurring.RecurringAuthorization memory a = _a(100e6, 1000, uint48(block.timestamp), 0, 1e6);
        bytes memory sig = _sig(a);
        vm.prank(evil);
        vm.expectRevert(Recurring.GasReimbursementTooHigh.selector);
        recurring.charge(a, sig, GAS_CAP + 1);
        uint256 p = token.balanceOf(payer);
        vm.prank(evil);
        recurring.charge(a, sig, GAS_CAP);
        assertEq(p - token.balanceOf(payer), 100e6 + GAS_CAP);
        assertEq(token.balanceOf(evil), 0);
    }

    // ------------------------------------------------------------------ Send

    function _rs(address to, uint256 amount, bytes32 ref) internal view returns (P2FluxSend.RelayedSend memory) {
        return P2FluxSend.RelayedSend(payer, to, amount, ref, block.timestamp + 600);
    }

    function _signSend(P2FluxSend.RelayedSend memory s, address to3009, uint256 value)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        return _signReceive(PAYER_KEY, s.from, to3009, value, s.validBefore, sender.authorizationNonce(s));
    }

    /// S1: a leaked authorization is useless: not redeemable at the token by anyone, not by a
    ///     stranger through Send, not on a second Send instance, not with any changed term, not twice.
    function test_S1_leakedAuthorizationUseless() public {
        P2FluxSend.RelayedSend memory s = _rs(merchant, 100e6, bytes32("r"));
        uint256 total = 100e6 + 100_000 + FIXED_FEE;
        (uint8 v, bytes32 r, bytes32 sg) = _signSend(s, address(sender), total);
        bytes32 nonce = sender.authorizationNonce(s);

        vm.prank(stranger);
        vm.expectRevert();
        token.receiveWithAuthorization(payer, address(sender), total, 0, s.validBefore, nonce, v, r, sg);
        vm.prank(stranger);
        vm.expectRevert();
        token.transferWithAuthorization(payer, address(sender), total, 0, s.validBefore, nonce, abi.encodePacked(r, sg, v));
        vm.prank(stranger);
        vm.expectRevert(P2FluxSend.NotRelayer.selector);
        sender.sendWithAuthorization(s, v, r, sg);

        P2FluxSend other = new P2FluxSend(address(token), feeWallet, gasTreasury, relayer, address(registry));
        vm.prank(relayer);
        vm.expectRevert();
        other.sendWithAuthorization(s, v, r, sg);

        P2FluxSend.RelayedSend memory t;
        t = _rs(stranger, 100e6, bytes32("r")); _relayRefused(t, v, r, sg);
        t = _rs(merchant, 100e6 - 1, bytes32("r")); _relayRefused(t, v, r, sg);
        t = _rs(merchant, 100e6, bytes32("x")); _relayRefused(t, v, r, sg);
        t = _rs(merchant, 100e6, bytes32("r")); t.validBefore += 1; _relayRefused(t, v, r, sg);
        t = _rs(merchant, 100e6, bytes32("r")); t.from = stranger; _relayRefused(t, v, r, sg);

        uint256 p = token.balanceOf(payer);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sg);
        assertEq(p - token.balanceOf(payer), total);
        assertEq(token.balanceOf(merchant), 100e6);
        assertEq(token.balanceOf(address(sender)), 0);
        _relayRefused(s, v, r, sg); // replay
    }

    function _relayRefused(P2FluxSend.RelayedSend memory t, uint8 v, bytes32 r, bytes32 sg) internal {
        vm.prank(relayer);
        vm.expectRevert();
        sender.sendWithAuthorization(t, v, r, sg);
    }

    /// S2: any rate change between signing and relay makes the relay revert; sender never pays a
    ///     fee they did not sign. Direct path: maxFee guard.
    function testFuzz_S2_feeChangeNeverOvercharges(uint256 amount, uint16 bps, uint64 fixedFee) public {
        amount = bound(amount, 1e6, 100_000e6);
        bps = uint16(bound(bps, 0, 200));
        fixedFee = uint64(bound(fixedFee, 0, 0.2e6));
        P2FluxSend.RelayedSend memory s =
            P2FluxSend.RelayedSend(payer, merchant, amount, bytes32("f"), block.timestamp + 10 days);
        (uint256 fee0, uint256 fixed0) = sender.quote(amount);
        uint256 total = amount + fee0 + fixed0;
        (uint8 v, bytes32 r, bytes32 sg) = _signSend(s, address(sender), total);
        _setRate(P2FluxFeeRegistry.Kind.Send, bps, bps, fixedFee);
        (uint256 fee1, uint256 fixed1) = sender.quote(amount);
        uint256 p = token.balanceOf(payer);
        vm.prank(relayer);
        try sender.sendWithAuthorization(s, v, r, sg) {
            assertEq(fee1 + fixed1, fee0 + fixed0);
            assertEq(p - token.balanceOf(payer), total);
        } catch {
            assertEq(token.balanceOf(payer), p);
        }
        // direct
        p = token.balanceOf(payer);
        vm.prank(payer);
        try sender.send(merchant, amount, fee0, bytes32("d")) {
            assertLe(p - token.balanceOf(payer), amount + fee0);
        } catch {
            assertGt(fee1, fee0);
        }
    }

    /// S3: USDC sent straight to the Send contract can never be taken out by a later send.
    function test_S3_strandedDonationNotExtractable() public {
        token.mint(address(sender), 500e6);
        P2FluxSend.RelayedSend memory s = _rs(merchant, 1e6, bytes32("z"));
        (uint256 fee, uint256 fx) = sender.quote(1e6);
        (uint8 v, bytes32 r, bytes32 sg) = _signSend(s, address(sender), 1e6 + fee + fx);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sg);
        assertEq(token.balanceOf(address(sender)), 500e6);
    }
}
