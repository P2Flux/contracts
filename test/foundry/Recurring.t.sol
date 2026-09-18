// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {P2FluxRecurring} from "../../contracts/P2FluxRecurring.sol";

/// @notice Fuzz suite for recurring charges: conservation, one charge per period, the EIP-712
///         binding of every signed field, chain/domain separation, revocation and access control.
contract RecurringFuzzTest is P2FluxTest {
    P2FluxRecurring internal recurring;

    uint256 internal constant NETWORK_FEE = 100_000;
    uint256 internal constant GAS_HARD_CAP = 50_000;
    uint256 internal constant MIN_AMOUNT = 102_041; // first amount with amount > 2% + 0.10

    function setUp() public {
        _baseSetUp();
        recurring = new P2FluxRecurring(admin, relayer, feeWallet, gasTreasury, address(token));
        token.mint(payer, 1e18);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
    }

    function _auth(uint256 amount, uint48 period, uint256 maxGas)
        internal
        view
        returns (P2FluxRecurring.RecurringAuthorization memory a)
    {
        a = P2FluxRecurring.RecurringAuthorization({
            payer: payer,
            recipient: makeAddrView("merchant"),
            token: address(token),
            amount: amount,
            period: period,
            start: uint48(block.timestamp),
            end: 0,
            salt: bytes32(uint256(4242)),
            maxGasReimbursement: maxGas
        });
    }

    /// @dev `makeAddr` labels (a state change); this is the same derivation without the label.
    function makeAddrView(string memory name) internal pure returns (address) {
        return vm.addr(uint256(keccak256(abi.encodePacked(name))));
    }

    function _sig(P2FluxRecurring.RecurringAuthorization memory a) internal view returns (bytes memory) {
        return _signDigest(PAYER_KEY, recurring.subscriptionId(a));
    }

    /// payer outflow == merchant net + 2% fee + fixed network fee + gas reimbursement. Exactly.
    function testFuzz_charge_conservation(uint256 amount, uint256 reimbursement, uint256 maxGas) public {
        amount = bound(amount, MIN_AMOUNT, 1e15);
        maxGas = bound(maxGas, 0, GAS_HARD_CAP);
        reimbursement = bound(reimbursement, 0, maxGas);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(amount, 30 days, maxGas);
        bytes memory sig = _sig(a);
        uint256 before = token.balanceOf(payer);

        vm.prank(relayer);
        recurring.charge(a, sig, reimbursement);

        uint256 fee = (amount * 200) / 10_000;
        assertEq(before - token.balanceOf(payer), amount + reimbursement, "payer debited amount + reimbursement");
        assertEq(token.balanceOf(a.recipient), amount - fee - NETWORK_FEE, "merchant net");
        assertEq(token.balanceOf(feeWallet), fee, "fee wallet gets the 2% only");
        assertEq(token.balanceOf(gasTreasury), NETWORK_FEE + reimbursement, "treasury gets the gas side only");
        assertEq(token.balanceOf(address(recurring)), 0, "contract holds nothing");
        assertGt(token.balanceOf(a.recipient), 0);
    }

    /// Only the relayer can be reimbursed. Anyone else may trigger a due charge, but for zero extra.
    function testFuzz_strangerIsNeverReimbursed(address caller, uint256 reimbursement) public {
        vm.assume(caller != relayer);
        reimbursement = bound(reimbursement, 0, type(uint128).max);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, GAS_HARD_CAP);
        bytes memory sig = _sig(a);
        uint256 before = token.balanceOf(payer);
        vm.prank(caller);
        recurring.charge(a, sig, reimbursement);
        assertEq(before - token.balanceOf(payer), 10e6, "no reimbursement for a non-relayer");
        assertEq(token.balanceOf(gasTreasury), NETWORK_FEE);
    }

    /// Reimbursement is capped twice: by what the payer signed and by the protocol hard cap.
    function testFuzz_reimbursementCaps(uint256 maxGas, uint256 reimbursement) public {
        maxGas = bound(maxGas, 0, 1e9);
        uint256 ceiling = maxGas < GAS_HARD_CAP ? maxGas : GAS_HARD_CAP;
        reimbursement = bound(reimbursement, ceiling + 1, type(uint128).max);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, maxGas);
        bytes memory sig = _sig(a);
        vm.prank(relayer);
        vm.expectRevert(P2FluxRecurring.GasReimbursementTooHigh.selector);
        recurring.charge(a, sig, reimbursement);
    }

    /// One charge per period, however often and by whomever it is asked; the next period is chargeable.
    function testFuzz_oncePerPeriod(uint48 period, uint256 offsetInPeriod, uint8 periodsAhead) public {
        period = uint48(bound(period, 1 hours, 366 days));
        offsetInPeriod = bound(offsetInPeriod, 0, period - 1);
        periodsAhead = uint8(bound(periodsAhead, 1, 12));
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, period, 0);
        bytes memory sig = _sig(a);

        vm.warp(a.start + offsetInPeriod);
        recurring.charge(a, sig, 0);
        vm.expectRevert(P2FluxRecurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
        vm.warp(uint256(a.start) + period - 1);
        vm.expectRevert(P2FluxRecurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);

        // Skipping ahead charges ONE period - there is no catch-up billing for the gap.
        uint256 before = token.balanceOf(payer);
        vm.warp(uint256(a.start) + uint256(period) * periodsAhead);
        recurring.charge(a, sig, 0);
        assertEq(before - token.balanceOf(payer), 10e6, "exactly one period collected after a gap");
        vm.expectRevert(P2FluxRecurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
    }

    /// Modify ANY signed field after signing and the authorization is void.
    function testFuzz_tamperedAuthorizationRefused(uint8 field, uint256 delta) public {
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 10_000);
        a.end = a.start + 365 days;
        bytes memory sig = _sig(a);
        delta = bound(delta, 1, 1e6);
        field = uint8(bound(field, 0, 7));
        if (field == 0) a.recipient = makeAddr("attacker");
        if (field == 1) a.amount += delta;
        if (field == 2) a.period += uint48(delta);
        if (field == 3) a.start -= uint48(delta);
        if (field == 4) a.end += uint48(delta);
        if (field == 5) a.salt = bytes32(uint256(a.salt) + delta); // always a different salt
        if (field == 6) a.maxGasReimbursement += delta;
        if (field == 7) a.payer = makeAddr("someoneElse");

        vm.prank(relayer);
        vm.expectRevert(P2FluxRecurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);
        assertEq(token.balanceOf(makeAddr("attacker")), 0);
    }

    /// The EIP-712 domain carries the chain id and this contract: neither can be swapped.
    function testFuzz_wrongChainRefused(uint64 otherChain) public {
        vm.assume(otherChain != block.chainid && otherChain != 0);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        bytes memory sig = _sig(a);
        vm.chainId(otherChain);
        vm.expectRevert(P2FluxRecurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);
    }

    function test_signatureForAnotherDeploymentRefused() public {
        P2FluxRecurring other = new P2FluxRecurring(admin, relayer, feeWallet, gasTreasury, address(token));
        vm.prank(payer);
        token.approve(address(other), type(uint256).max);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        bytes memory sig = _sig(a); // signed for `recurring`
        vm.expectRevert(P2FluxRecurring.InvalidSignature.selector);
        other.charge(a, sig, 0);
    }

    function testFuzz_wrongSignerRefused(uint256 key) public {
        key = bound(key, 1, type(uint128).max);
        vm.assume(key != PAYER_KEY);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        bytes memory sig = _signDigest(key, recurring.subscriptionId(a));
        vm.expectRevert(P2FluxRecurring.InvalidSignature.selector);
        recurring.charge(a, sig, 0);
    }

    /// An ERC-6492 wrapper must never be accepted, whatever precedes the magic suffix.
    function testFuzz_erc6492SuffixRefused(bytes memory prefix) public {
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        bytes memory wrapped = abi.encodePacked(
            _sig(a), prefix, bytes32(0x6492649264926492649264926492649264926492649264926492649264926492)
        );
        vm.expectRevert(P2FluxRecurring.InvalidSignature.selector);
        recurring.charge(a, wrapped, 0);
    }

    function testFuzz_amountBelowMinimumRefused(uint256 amount) public {
        amount = bound(amount, 1, MIN_AMOUNT - 1);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(amount, 30 days, 0);
        bytes memory sig = _sig(a);
        vm.expectRevert(P2FluxRecurring.AmountTooSmall.selector);
        recurring.charge(a, sig, 0);
    }

    function test_minimumBoundaryIsExact() public {
        P2FluxRecurring.RecurringAuthorization memory a = _auth(MIN_AMOUNT, 30 days, 0);
        recurring.charge(a, _sig(a), 0);
        assertEq(token.balanceOf(a.recipient), 1, "the minimum leaves the merchant exactly one base unit");
    }

    function testFuzz_timeWindow(uint48 startDelay, uint48 lifetime) public {
        startDelay = uint48(bound(startDelay, 1, 365 days));
        lifetime = uint48(bound(lifetime, 1, 365 days));
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 1 hours, 0);
        a.start = uint48(block.timestamp) + startDelay;
        a.end = a.start + lifetime;
        bytes memory sig = _sig(a);

        vm.expectRevert(P2FluxRecurring.NotStarted.selector);
        recurring.charge(a, sig, 0);
        vm.warp(a.end);
        vm.expectRevert(P2FluxRecurring.Expired.selector);
        recurring.charge(a, sig, 0);
        vm.warp(a.end - 1);
        recurring.charge(a, sig, 0);
    }

    function testFuzz_invalidEndRefused(uint48 back) public {
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 1 hours, 0);
        back = uint48(bound(back, 0, a.start - 1));
        a.end = a.start - back; // end <= start, and non-zero
        bytes memory sig = _sig(a);
        vm.expectRevert(P2FluxRecurring.InvalidEnd.selector);
        recurring.charge(a, sig, 0);
    }

    /// Only the payer can revoke, revocation is permanent, and it stops every later charge.
    function testFuzz_revocation(address stranger) public {
        vm.assume(stranger != payer);
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        bytes memory sig = _sig(a);

        vm.prank(stranger);
        vm.expectRevert(P2FluxRecurring.NotPayer.selector);
        recurring.revoke(a);

        vm.prank(payer);
        recurring.revoke(a);
        vm.prank(payer);
        vm.expectRevert(P2FluxRecurring.AlreadyRevoked.selector);
        recurring.revoke(a);

        vm.prank(relayer);
        vm.expectRevert(P2FluxRecurring.Revoked.selector);
        recurring.charge(a, sig, 0);
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(P2FluxRecurring.Revoked.selector);
        recurring.charge(a, sig, 0);
    }

    /// The one privileged function: only the immutable admin may move the relayer, never to zero.
    function testFuzz_setRelayer_onlyAdmin(address caller, address next) public {
        vm.assume(caller != admin);
        vm.prank(caller);
        vm.expectRevert(P2FluxRecurring.NotAdmin.selector);
        recurring.setRelayer(next);
        assertEq(recurring.relayer(), relayer);

        vm.prank(admin);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        recurring.setRelayer(address(0));
    }

    /// Rotating the relayer moves the reimbursement privilege and nothing else: no destination changes.
    function test_relayerRotationCannotRedirectFunds() public {
        address next = makeAddr("nextRelayer");
        vm.prank(admin);
        recurring.setRelayer(next);
        assertEq(recurring.feeWallet(), feeWallet);
        assertEq(recurring.gasTreasury(), gasTreasury);

        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, GAS_HARD_CAP);
        bytes memory sig = _sig(a);
        vm.prank(relayer); // the OLD relayer is now a stranger
        recurring.charge(a, sig, GAS_HARD_CAP);
        assertEq(token.balanceOf(gasTreasury), NETWORK_FEE, "old relayer gets no reimbursement");
        assertEq(token.balanceOf(next), 0, "the relayer itself is never paid by the contract");
    }

    function testFuzz_otherTokenRefused(address other) public {
        vm.assume(other != address(token));
        P2FluxRecurring.RecurringAuthorization memory a = _auth(10e6, 30 days, 0);
        a.token = other;
        bytes memory sig = _sig(a);
        vm.expectRevert(P2FluxRecurring.TokenNotSupported.selector);
        recurring.charge(a, sig, 0);
    }
}
