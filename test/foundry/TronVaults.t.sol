// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxTronVaults, P2FluxTronVault} from "../../contracts/tron/P2FluxTronVaults.sol";

/// Tron's USDT, as far as these contracts can tell: `transfer` returns FALSE even when it moved the
/// tokens, and the issuer can freeze any address (transfers to or from it revert).
contract TronUsdtMock {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public frozen;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function freeze(address a, bool f) external { frozen[a] = f; }
    function transfer(address to, uint256 v) external returns (bool) {
        require(!frozen[msg.sender] && !frozen[to], "frozen");
        require(balanceOf[msg.sender] >= v, "balance");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
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

    function _pay(uint256 v) internal returns (address vault) {
        vault = vaults.vaultOf(merchant);
        usdt.mint(vault, v); // a buyer's plain transfer
    }

    function test_vault_address_is_predictable_and_deployed_there() public {
        address predicted = _pay(10e6);
        vaults.payout(merchant, 0);
        assertGt(predicted.code.length, 0, "deployed at the predicted address");
        assertEq(P2FluxTronVault(predicted).merchant(), merchant);
        assertEq(P2FluxTronVault(predicted).factory(), address(vaults));
    }

    function test_anyone_pays_out_free_merchant_gets_99_percent() public {
        _pay(10e6);
        _pay(5e6);
        vm.prank(address(0xC0FFEE));
        vaults.payout(merchant, 0);
        // 15 USDT in, one unit stays (VAULT_FLOOR): 14.999999 paid out, 1% of that is the fee.
        assertEq(usdt.balanceOf(merchant), 14_999_999 - 149_999);
        assertEq(vaults.accruedFees(), 149_999);
        assertEq(usdt.balanceOf(address(vaults)), 149_999);
        assertEq(usdt.balanceOf(vaults.vaultOf(merchant)), 1, 'one unit stays: the next buyer pays the cheaper rate');
    }

    function test_relayer_charges_the_payout_cost_within_the_limits() public {
        _pay(50e6);
        vm.prank(relayer);
        vaults.payout(merchant, 4_400_000);
        assertEq(usdt.balanceOf(merchant), 49_999_999 - 499_999 - 4_400_000);
        assertEq(vaults.accruedPayoutFees(), 4_400_000);
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
        _pay(0);
        address m2 = address(0xB0B);
        usdt.mint(vaults.vaultOf(m2), 10e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronVaults.PayoutFeeTooHigh.selector);
        vaults.payout(m2, 1_000_001); // more than 10% of 10 USDT
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
    }

    function test_sweep_sends_shares_to_fixed_destinations() public {
        _pay(100e6);
        vm.prank(relayer);
        vaults.payout(merchant, 3e6);
        vm.prank(address(0xC0FFEE));
        vaults.sweep();
        assertEq(usdt.balanceOf(feeWallet), 999_999);
        assertEq(usdt.balanceOf(gasTreasury), 3e6);
        assertEq(vaults.accruedFees(), 0);
        assertEq(vaults.accruedPayoutFees(), 0);
    }

    function test_frozen_factory_never_locks_a_merchant() public {
        _pay(10e6);
        vaults.payout(merchant, 0); // deploys
        _pay(10e6);
        usdt.freeze(address(vaults), true);
        vaults.payout(merchant, 0);
        assertEq(usdt.balanceOf(merchant), (9_999_999 - 99_999) + 10e6, "second batch paid in full, no fee");
        assertEq(vaults.accruedFees(), 99_999, "only the first batch's fee accrued");
    }

    function test_frozen_fee_wallet_keeps_its_share_accrued_other_share_still_leaves() public {
        _pay(100e6);
        vm.prank(relayer);
        vaults.payout(merchant, 3e6);
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

    function test_only_the_factory_can_release_a_vault() public {
        _pay(10e6);
        vaults.payout(merchant, 0);
        address vault = vaults.vaultOf(merchant);
        usdt.mint(vault, 10e6);
        vm.expectRevert(P2FluxTronVault.NotFactory.selector);
        P2FluxTronVault(vault).release(address(usdt), 10e6, 0);
    }

    /// Whatever the amounts and fees: the merchant gets everything but the fee and the allowed payout fee,
    /// and P2Flux's accrual equals what the factory actually holds.
    function testFuzz_conservation(uint96 a, uint96 b, uint32 pf) public {
        uint256 held = uint256(a) + uint256(b);
        vm.assume(held > 1);
        uint256 total = held - 1; // VAULT_FLOOR stays
        usdt.mint(vaults.vaultOf(merchant), a);
        usdt.mint(vaults.vaultOf(merchant), b);
        uint256 payoutFee = pf % (vaults.MAX_PAYOUT_FEE() + 1);
        if (payoutFee * 10 > total) payoutFee = 0;
        vm.prank(relayer);
        vaults.payout(merchant, payoutFee);
        uint256 fee = (total * vaults.FEE_BPS()) / 10_000;
        assertEq(usdt.balanceOf(merchant), total - fee - payoutFee);
        assertEq(usdt.balanceOf(address(vaults)), vaults.accruedFees() + vaults.accruedPayoutFees());
        assertEq(usdt.balanceOf(vaults.vaultOf(merchant)), 1);
    }

    function test_a_vault_holding_only_its_floor_is_empty() public {
        _pay(1);
        vm.expectRevert(P2FluxTronVaults.ZeroAmount.selector);
        vaults.payout(merchant, 0);
    }
}
