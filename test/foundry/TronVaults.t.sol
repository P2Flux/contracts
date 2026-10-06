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
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function freeze(address a, bool f) external { frozen[a] = f; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        require(balanceOf[msg.sender] >= v, "balance");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        transfers++;
        return false; // the quirk
    }
}

contract TronVaultsTest is Test {
    TronUsdtMock usdt;
    P2FluxTronVaults vaults;
    address feeWallet = address(0xFEE);
    address gasTreasury = address(0x6A5);
    address relayer = address(0xBEEF);
    address merchant = address(0xA11CE);

    function setUp() public {
        usdt = new TronUsdtMock();
        vaults = new P2FluxTronVaults(address(usdt), feeWallet, gasTreasury, relayer, bytes1(0xff));
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

    function test_payout_fee_capped_absolutely_and_at_a_tenth() public {
        _pay(200e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeeTooHigh.selector);
        vaults.payout(merchant, 8_000_001);
        address m2 = address(0xB0B);
        usdt.mint(vaults.vaultOf(m2), 10e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeeTooHigh.selector);
        vaults.payout(m2, 1_000_001); // more than 10% of ~10 USDT
    }

    function test_charged_payouts_at_most_every_12_hours_free_ones_always() public {
        _pay(50e6);
        vm.prank(relayer);
        vaults.payout(merchant, 1e6);
        _pay(50e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PaidPayoutTooSoon.selector);
        vaults.payout(merchant, 1e6);
        vaults.payout(merchant, 0); // free payout still works
        _pay(50e6);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(relayer);
        vaults.payout(merchant, 1e6);
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
}
