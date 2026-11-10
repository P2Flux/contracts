// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxTronVaults, P2FluxTronVault} from "../../contracts/tron/P2FluxTronVaults.sol";

/// Tron's USDT, as far as these contracts can tell: `transfer` returns FALSE even when it moved the tokens,
/// and the issuer can freeze any address (transfers to or from it revert).
contract TronUsdtMock {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public frozen;
    uint256 public transfers;
    mapping(address => mapping(address => uint256)) public allowance;
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        require(!frozen[from] && !frozen[to], "frozen");
        require(allowance[from][msg.sender] >= v && balanceOf[from] >= v, "allowance/balance");
        allowance[from][msg.sender] -= v;
        balanceOf[from] -= v;
        balanceOf[to] += v;
        transfers++;
        return false; // same quirk assumed
    }
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function freeze(address a, bool f) external { frozen[a] = f; }
    function transfer(address to, uint256 v) external virtual returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        require(balanceOf[msg.sender] >= v, "balance");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        transfers++;
        return false; // the quirk
    }
}

/// Tron USDT with its transfer-fee switch turned on (1%, as `basisPointsRate` would): the receiver gets less.
contract FeeUsdtMock is TronUsdtMock {
    function transfer(address to, uint256 v) external override returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        require(balanceOf[msg.sender] >= v, "balance");
        uint256 fee = v / 100;
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v - fee;
        balanceOf[address(0xFEEFEE)] += fee;
        transfers++;
        return false;
    }
}

contract TronVaultsTest is Test {
    TronUsdtMock usdt;
    P2FluxTronVaults vaults;
    address feeWallet = address(0xFEE);
    address gasTreasury = address(0x6A5);
    address relayer = address(0xBEEF);
    address merchant = address(0xA11CE);
    address admin = address(0xAD);

    function setUp() public {
        usdt = new TronUsdtMock();
        vaults = new P2FluxTronVaults(admin, address(usdt), feeWallet, gasTreasury, relayer, bytes1(0xff));
        vm.warp(1_800_000_000);
    }

    function _vault() internal view returns (P2FluxTronVault) {
        return P2FluxTronVault(vaults.vaultOf(merchant));
    }

    function _pay(uint256 v) internal {
        usdt.mint(vaults.vaultOf(merchant), v); // a buyer's plain transfer
    }

    function test_vault_is_a_minimal_proxy_at_the_predicted_address() public {
        address predicted = vaults.vaultOf(merchant);
        _pay(10e6);
        vaults.payout(merchant, 0);
        assertEq(predicted.code.length, 45, "EIP-1167 runtime code");
        assertEq(_vault().merchant(), merchant);
        assertEq(_vault().factory(), address(vaults));
    }

    function test_vaults_of_different_merchants_differ() public view {
        assertTrue(vaults.vaultOf(merchant) != vaults.vaultOf(address(0xB0B)));
    }

    function test_a_payout_is_one_transfer_and_p2flux_share_stays_reserved() public {
        _pay(10e6);
        _pay(5e6);
        uint256 before = usdt.transfers();
        vm.prank(address(0xC0FFEE));
        vaults.payout(merchant, 0);
        assertEq(usdt.transfers() - before, 1, "only the merchant's transfer");
        // 15 USDT in; one unit stays (VAULT_FLOOR); 1% of 14.999999 is reserved in the vault.
        assertEq(usdt.balanceOf(merchant), 14_999_999 - 149_999);
        assertEq(_vault().reservedFee(), 149_999);
        assertEq(usdt.balanceOf(address(_vault())), 149_999 + 1);
    }

    function test_reserved_share_is_never_paid_out_again() public {
        _pay(10e6);
        vaults.payout(merchant, 0);
        vm.expectRevert(P2FluxTronVaults.ZeroAmount.selector);
        vaults.payout(merchant, 0); // only the reserve and the floor are left
        _pay(10e6);
        vaults.payout(merchant, 0);
        assertEq(usdt.balanceOf(merchant), (9_999_999 - 99_999) + (10e6 - 100_000));
        assertEq(_vault().reservedFee(), 99_999 + 100_000);
    }

    function test_collect_and_sweep_take_exactly_the_reserve() public {
        _pay(100e6);
        vm.prank(relayer);
        vaults.payout(merchant, 3e6);
        vm.prank(address(0xC0FFEE));
        vaults.collect(merchant);
        assertEq(_vault().reservedFee(), 0);
        assertEq(usdt.balanceOf(address(_vault())), 1, "only the floor stays");
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet), 999_999);
        assertEq(usdt.balanceOf(gasTreasury), 3e6);
        assertEq(usdt.balanceOf(address(vaults)), 0);
    }

    function test_relayer_charges_the_payout_cost_within_the_limits() public {
        _pay(50e6);
        vm.prank(relayer);
        vaults.payout(merchant, 2_400_000);
        assertEq(usdt.balanceOf(merchant), 49_999_999 - 499_999 - 2_400_000);
        assertEq(_vault().reservedPayoutFee(), 2_400_000);
    }

    function test_only_the_relayer_may_charge_a_payout_fee() public {
        _pay(50e6);
        vm.expectRevert(P2FluxTronVaults.NotRelayer.selector);
        vaults.payout(merchant, 1);
    }

    function test_payout_fee_capped_absolutely_and_at_half() public {
        _pay(200e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeeTooHigh.selector);
        vaults.payout(merchant, 25_000_001);
        address m2 = address(0xB0B);
        usdt.mint(vaults.vaultOf(m2), 10e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeeTooHigh.selector);
        vaults.payout(m2, 5_000_000); // more than half of 9.999999
        vm.prank(relayer);
        vaults.payout(m2, 2_900_000); // an immediate payout of a 10 USDT payment
    }

    function test_charged_payouts_frequent_but_within_a_daily_budget() public {
        for (uint256 i = 0; i < 3; i++) {
            _pay(60e6);
            vm.prank(relayer);
            vaults.payout(merchant, 25e6); // 75 USDT charged in a day
            vm.warp(block.timestamp + 1 hours);
        }
        _pay(60e6);
        vm.prank(relayer);
        vaults.payout(merchant, 20e6); // 95
        _pay(60e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeesExhausted.selector);
        vaults.payout(merchant, 5_000_001);
        vm.prank(relayer);
        vaults.payout(merchant, 5e6); // exactly the 100 USDT budget
        _pay(50e6);
        vaults.payout(merchant, 0); // a free payout is never limited
        _pay(50e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(relayer);
        vaults.payout(merchant, 25e6); // a new day
    }

    function test_empty_vault_cannot_be_paid_out() public {
        vm.expectRevert(P2FluxTronVaults.ZeroAmount.selector);
        vaults.payout(merchant, 0);
        _pay(1);
        vm.expectRevert(P2FluxTronVaults.ZeroAmount.selector);
        vaults.payout(merchant, 0);
    }

    function test_frozen_factory_never_locks_a_merchant_and_keeps_its_reserve() public {
        _pay(10e6);
        vaults.payout(merchant, 0);
        usdt.freeze(address(vaults), true);
        vaults.collect(merchant); // cannot receive: the reserve simply stays in the vault
        assertEq(_vault().reservedFee(), 99_999);
        _pay(10e6);
        vaults.payout(merchant, 0); // payouts unaffected
        assertEq(usdt.balanceOf(merchant), (9_999_999 - 99_999) + (10e6 - 100_000));
    }

    function test_frozen_fee_wallet_keeps_its_share_accrued_other_share_still_leaves() public {
        _pay(100e6);
        vm.prank(relayer);
        vaults.payout(merchant, 3e6);
        vaults.collect(merchant);
        usdt.freeze(feeWallet, true);
        vaults.sweep();
        assertEq(usdt.balanceOf(gasTreasury), 3e6);
        assertEq(vaults.accruedFees(), 999_999, "still owed, not lost");
        usdt.freeze(feeWallet, false);
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet), 999_999);
    }

    function test_frozen_merchant_moves_nothing() public {
        _pay(10e6);
        usdt.freeze(merchant, true);
        vm.expectRevert(P2FluxTronVault.TransferFailed.selector);
        vaults.payout(merchant, 0);
        assertEq(usdt.balanceOf(vaults.vaultOf(merchant)), 10e6);
    }

    function test_only_the_factory_can_release_or_collect() public {
        _pay(10e6);
        vaults.payout(merchant, 0);
        P2FluxTronVault v = _vault();
        vm.expectRevert(P2FluxTronVault.NotFactory.selector);
        v.release(address(usdt), 1, 0, 0);
        vm.expectRevert(P2FluxTronVault.NotFactory.selector);
        v.collect(address(usdt));
    }

    function test_nobody_can_initialise_a_vault_or_the_implementation_again() public {
        _pay(10e6);
        vaults.payout(merchant, 0);
        P2FluxTronVault v = _vault();
        P2FluxTronVault impl = P2FluxTronVault(vaults.implementation());
        vm.expectRevert(P2FluxTronVault.AlreadyInitialized.selector);
        v.initialize(address(0xBAD));
        vm.expectRevert(P2FluxTronVault.AlreadyInitialized.selector);
        impl.initialize(address(0xBAD));
    }

    /// Any sequence of payments, payouts and collections: the merchant gets everything but the fees and the
    /// allowed payout fees; the vault holds exactly the floor plus what is reserved and not yet paid out.
    function testFuzz_conservation(uint96 a, uint96 b, uint32 pf, bool collectBetween) public {
        uint256 first = uint256(a) + 2;
        _pay(first);
        uint256 amount1 = first - 1;
        uint256 fee1 = (amount1 * 100) / 10_000;
        uint256 pfee = pf % (vaults.MAX_PAYOUT_FEE() + 1);
        if (pfee * 10 > amount1 || amount1 - fee1 < pfee) pfee = 0;
        vm.prank(relayer);
        vaults.payout(merchant, pfee);
        if (collectBetween) vaults.collect(merchant);
        uint256 second = uint256(b) + 1;
        _pay(second);
        vaults.payout(merchant, 0);
        uint256 fee2 = (second * 100) / 10_000;
        assertEq(usdt.balanceOf(merchant), (amount1 - fee1 - pfee) + (second - fee2));
        uint256 reserved = _vault().reservedFee() + _vault().reservedPayoutFee();
        assertEq(usdt.balanceOf(address(_vault())), 1 + reserved);
        vaults.collect(merchant);
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet) + usdt.balanceOf(gasTreasury), fee1 + fee2 + pfee);
    }

    // --- subscriptions ------------------------------------------------------

    uint256 buyerKey = 0xB0B0;

    function _auth(uint256 amount, uint256 maxGas) internal view returns (P2FluxTronVaults.RecurringAuthorization memory a) {
        a = P2FluxTronVaults.RecurringAuthorization({
            payer: vm.addr(buyerKey), recipient: merchant, token: address(usdt), amount: amount,
            period: 30 days, start: uint48(block.timestamp), end: 0, salt: bytes32(uint256(1)), maxGasReimbursement: maxGas
        });
    }

    function _sign(P2FluxTronVaults.RecurringAuthorization memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(buyerKey, vaults.subscriptionId(a));
        return abi.encodePacked(r, s_, v);
    }

    function _fund(uint256 v) internal {
        usdt.mint(vm.addr(buyerKey), v);
        vm.prank(vm.addr(buyerKey));
        usdt.approve(address(vaults), type(uint256).max);
    }

    function test_charge_is_one_transfer_into_the_vault_and_payout_takes_no_second_fee() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 5e6);
        bytes memory sig = _sign(a);
        assertTrue(vaults.isValidAuthorization(a, sig));
        uint256 before = usdt.transfers();
        vm.prank(relayer);
        vaults.charge(a, sig, 2_500_000);
        assertEq(usdt.transfers() - before, 1, "payer -> vault only");
        assertEq(usdt.balanceOf(vaults.vaultOf(merchant)), 12_500_000);
        assertEq(usdt.balanceOf(vm.addr(buyerKey)), 100e6 - 12_500_000);
        vaults.payout(merchant, 0);
        // 10 - 2% - 0.10 = 9.70, minus the one unit left as floor (fee-free credit carries over)
        assertEq(usdt.balanceOf(merchant), 9_700_000 - 1);
        vaults.collect(merchant);
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet), 200_000);
        assertEq(usdt.balanceOf(gasTreasury), 100_000 + 2_500_000);
        assertEq(usdt.balanceOf(vaults.vaultOf(merchant)), 1);
    }

    function test_subscription_and_one_time_money_mix_correctly() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 5e6);
        vaults.charge(a, _sign(a), 0); // anyone, no reimbursement
        _pay(20e6); // a one-time payment into the same vault
        vaults.payout(merchant, 0);
        // subscription: 9.70 net (fee-free); one-time part: 20 - floor, 1%
        uint256 oneTime = 20e6 - 1;
        assertEq(usdt.balanceOf(merchant), 9_700_000 + oneTime - (oneTime * 100) / 10_000);
        vaults.collect(merchant);
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet), 200_000 + (oneTime * 100) / 10_000);
        assertEq(usdt.balanceOf(gasTreasury), 100_000);
    }

    function test_charge_once_per_period() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 0);
        bytes memory sig = _sign(a);
        vaults.charge(a, sig, 0);
        vm.expectRevert(P2FluxTronVaults.AlreadyChargedThisPeriod.selector);
        vaults.charge(a, sig, 0);
        vm.warp(block.timestamp + 30 days);
        vaults.charge(a, sig, 0);
        assertEq(usdt.balanceOf(vm.addr(buyerKey)), 80e6);
    }

    function test_charge_refuses_wrong_signature_term_change_and_revoked() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 0);
        bytes memory sig = _sign(a);
        P2FluxTronVaults.RecurringAuthorization memory b = _auth(11e6, 0);
        vm.expectRevert(P2FluxTronVaults.InvalidSignature.selector);
        vaults.charge(b, sig, 0);
        vm.expectRevert(P2FluxTronVaults.NotPayer.selector);
        vaults.revoke(a);
        vm.prank(vm.addr(buyerKey));
        vaults.revoke(a);
        vm.expectRevert(P2FluxTronVaults.Revoked.selector);
        vaults.charge(a, sig, 0);
    }

    function test_reimbursement_relayer_only_and_capped() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 9e6);
        bytes memory sig = _sign(a);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.GasReimbursementTooHigh.selector);
        vaults.charge(a, sig, 5_000_001); // above the hard cap though signed 9
        vaults.charge(a, sig, 4e6); // not the relayer: reimbursement ignored
        assertEq(usdt.balanceOf(vm.addr(buyerKey)), 90e6);
    }

    function test_amount_must_cover_fees_and_token_is_pinned() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(100_000, 0);
        bytes memory sig = _sign(a);
        vm.expectRevert(P2FluxTronVaults.AmountTooSmall.selector);
        vaults.charge(a, sig, 0);
        a = _auth(10e6, 0);
        a.token = address(0xDEAD);
        sig = _sign(a);
        vm.expectRevert(P2FluxTronVaults.TokenNotSupported.selector);
        vaults.charge(a, sig, 0);
    }

    function test_high_s_signature_refused() public {
        _fund(100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 0);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(buyerKey, vaults.subscriptionId(a));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(s_)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(P2FluxTronVaults.InvalidSignature.selector);
        vaults.charge(a, flipped, 0);
    }

    function test_no_allowance_moves_nothing() public {
        usdt.mint(vm.addr(buyerKey), 100e6);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(10e6, 0);
        bytes memory sig = _sign(a);
        vm.expectRevert(); // the token refuses
        vaults.charge(a, sig, 0);
        assertEq(vaults.lastChargedPeriodPlusOne(vaults.subscriptionId(a)), 0);
    }

    function test_relayer_rotation_admin_only() public {
        vm.expectRevert(P2FluxTronVaults.NotAdmin.selector);
        vaults.setRelayer(address(1));
        vm.prank(admin);
        vaults.setRelayer(address(0x1234));
        assertEq(vaults.relayer(), address(0x1234));
    }

    /// Subscriptions and one-time payments in one vault, any order of payouts: nothing created or lost,
    /// and P2Flux gets exactly 2% + 0.10 + reimbursement per charge and 1% of the one-time part.
    function testFuzz_mixed_conservation(uint64 amt, uint64 oneTime, uint32 gas, bool payoutBetween) public {
        uint256 amount = uint256(amt) % 1e12 + 200_000;
        uint256 reimb = uint256(gas) % 5e6;
        _fund(amount + reimb);
        P2FluxTronVaults.RecurringAuthorization memory a = _auth(amount, 5e6);
        bytes memory sig = _sign(a);
        vm.prank(relayer);
        vaults.charge(a, sig, reimb);
        if (payoutBetween) vaults.payout(merchant, 0);
        _pay(uint256(oneTime) + 2);
        vaults.payout(merchant, 0);
        vaults.collect(merchant);
        vaults.sweep();
        uint256 inTotal = amount + reimb + uint256(oneTime) + 2;
        address v = vaults.vaultOf(merchant);
        assertEq(usdt.balanceOf(merchant) + usdt.balanceOf(feeWallet) + usdt.balanceOf(gasTreasury) + usdt.balanceOf(v), inTotal);
        assertEq(usdt.balanceOf(gasTreasury), 100_000 + reimb);
        assertLe(usdt.balanceOf(v), 2, "only floor/fee-free dust remains");
    }

    function test_deploy_ahead_of_the_first_payment_at_the_predicted_address() public {
        address predicted = vaults.vaultOf(merchant);
        assertEq(predicted.code.length, 0);
        assertEq(vaults.deploy(merchant), predicted);
        assertEq(predicted.code.length, 45);
        assertEq(vaults.deploy(merchant), predicted, "idempotent");
        _pay(10e6);
        vaults.payout(merchant, 0);
        assertEq(usdt.balanceOf(merchant), 9_999_999 - 99_999);
    }

    function test_a_usdt_transfer_fee_never_locks_the_merchant_and_p2flux_books_what_arrived() public {
        FeeUsdtMock t = new FeeUsdtMock();
        P2FluxTronVaults v = new P2FluxTronVaults(admin, address(t), feeWallet, gasTreasury, relayer, bytes1(0xff));
        t.mint(v.vaultOf(merchant), 100e6);
        vm.prank(relayer);
        v.payout(merchant, 2e6);
        // 99.999999 payable: 1% fee 0.999999, cost 2, net 97 sent; the merchant receives 1% less of that
        assertEq(t.balanceOf(merchant), 97e6 - 970_000);
        v.collect(merchant);
        assertEq(v.accruedPayoutFees(), 2e6, "the cost first");
        assertEq(v.accruedFees(), 2_999_999 - 29_999 - 2e6, "the token fee comes out of P2Flux's share");
        v.sweep();
        assertGt(t.balanceOf(feeWallet), 0);
        assertGt(t.balanceOf(gasTreasury), 0);
    }
}
