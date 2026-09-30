// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxTest} from "./Helpers.sol";
import {P2FluxBatchVaults} from "../../contracts/P2FluxBatchVaults.sol";
import {P2FluxX402Splitter, P2FluxX402Vault} from "../../contracts/P2FluxX402Splitter.sol";
import {MockUSDC} from "../../contracts/test/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The batch vaults: the only thing they can do is pay a seller 97% and P2Flux 3%.
contract BatchVaultsTest is P2FluxTest {
    P2FluxBatchVaults internal vaults;
    address internal seller = makeAddr("seller");

    function setUp() public {
        _baseSetUp();
        vaults = new P2FluxBatchVaults(address(token), feeWallet);
    }

    function _fund(address recipient, uint256 amount) internal returns (address vault) {
        vault = vaults.vaultOf(recipient);
        token.mint(vault, amount);
    }

    function test_constructor_refusesZeroAddresses() public {
        vm.expectRevert(P2FluxBatchVaults.ZeroAddress.selector);
        new P2FluxBatchVaults(address(0), feeWallet);
        vm.expectRevert(P2FluxBatchVaults.ZeroAddress.selector);
        new P2FluxBatchVaults(address(token), address(0));
    }

    function test_flush_pays97And3() public {
        _fund(seller, 2_000_000);
        vm.expectEmit(true, false, false, true, address(vaults));
        emit P2FluxBatchVaults.Flushed(seller, 1_940_000, 60_000);
        vaults.flush(seller);
        assertEq(token.balanceOf(seller), 1_940_000);
        assertEq(token.balanceOf(feeWallet), 60_000);
        assertEq(token.balanceOf(vaults.vaultOf(seller)), 0);
    }

    function testFuzz_flush_feeIsExactly3PercentRoundedDown(uint256 amount) public {
        amount = bound(amount, 1, 1e15);
        _fund(seller, amount);
        vaults.flush(seller);
        uint256 fee = (amount * 300) / 10_000;
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(seller), amount - fee);
    }

    function test_flush_tinyAmountRoundsFeeToZero() public {
        _fund(seller, 33);
        vaults.flush(seller);
        assertEq(token.balanceOf(seller), 33);
        assertEq(token.balanceOf(feeWallet), 0);
    }

    function test_flush_zeroReverts() public {
        vm.expectRevert(P2FluxBatchVaults.ZeroAmount.selector);
        vaults.flush(seller);
    }

    function test_flush_zeroRecipientReverts() public {
        vm.expectRevert(P2FluxBatchVaults.ZeroAddress.selector);
        vaults.flush(address(0));
    }

    function testFuzz_anyoneMayFlush_moneyGoesOnlyToSellerAndFeeWallet(address caller, uint256 amount) public {
        vm.assume(caller != seller && caller != feeWallet);
        amount = bound(amount, 1, 1e15);
        _fund(seller, amount);
        uint256 callerBefore = token.balanceOf(caller);
        vm.prank(caller);
        vaults.flush(seller);
        assertEq(token.balanceOf(caller), callerBefore);
        assertEq(token.balanceOf(seller) + token.balanceOf(feeWallet), amount);
    }

    function test_blacklistedFeeWallet_allGoesToSeller() public {
        token.setBlacklisted(feeWallet, true);
        _fund(seller, 1_000_000);
        vm.expectEmit(true, false, false, true, address(vaults));
        emit P2FluxBatchVaults.Flushed(seller, 1_000_000, 0);
        vaults.flush(seller);
        assertEq(token.balanceOf(seller), 1_000_000);
    }

    function test_blacklistedSeller_nothingMoves() public {
        token.setBlacklisted(seller, true);
        address vault = _fund(seller, 1_000_000);
        vm.expectRevert();
        vaults.flush(seller);
        assertEq(token.balanceOf(vault), 1_000_000);
        assertEq(token.balanceOf(feeWallet), 0);
    }

    function testFuzz_vaultOf_matchesDeployedVault(address recipient) public {
        vm.assume(recipient != address(0));
        address predicted = vaults.vaultOf(recipient);
        token.mint(predicted, 100);
        vaults.flush(recipient);
        assertGt(predicted.code.length, 0);
        assertEq(P2FluxX402Vault(predicted).recipient(), recipient);
        assertEq(P2FluxX402Vault(predicted).factory(), address(vaults));
    }

    function test_secondFlush_reusesVault() public {
        _fund(seller, 1_000_000);
        vaults.flush(seller);
        _fund(seller, 500_000);
        vaults.flush(seller);
        assertEq(token.balanceOf(seller), 970_000 + 485_000);
        assertEq(token.balanceOf(feeWallet), 30_000 + 15_000);
    }

    function test_nobodyButTheFactoryCanRelease() public {
        address vault = _fund(seller, 1_000_000);
        vaults.flush(seller);
        token.mint(vault, 1_000);
        vm.expectRevert(P2FluxX402Vault.NotFactory.selector);
        P2FluxX402Vault(vault).release(IERC20(address(token)), address(this), 1_000, 0);
    }

    function test_otherTokenInVault_untouched() public {
        MockUSDC other = new MockUSDC();
        address vault = _fund(seller, 1_000_000);
        other.mint(vault, 777);
        vaults.flush(seller);
        assertEq(other.balanceOf(vault), 777);
    }

    function test_batchVaultIsNotTheExactVault() public {
        address proxy = makeAddr("proxy");
        vm.etch(proxy, hex"00");
        P2FluxX402Splitter splitter = new P2FluxX402Splitter(address(token), feeWallet, relayer, proxy, 3_000);
        assertTrue(splitter.vaultOf(seller) != vaults.vaultOf(seller));
    }

    function test_vaultCannotBeFlushedByAnotherFactory() public {
        P2FluxBatchVaults rogue = new P2FluxBatchVaults(address(token), makeAddr("rogueFee"));
        address vault = _fund(seller, 1_000_000);
        vaults.flush(seller);
        token.mint(vault, 1_000_000);
        // Another factory derives a different address for the same seller and never reaches this vault.
        assertTrue(rogue.vaultOf(seller) != vault);
        vm.expectRevert(P2FluxBatchVaults.ZeroAmount.selector);
        rogue.flush(seller);
        assertEq(token.balanceOf(vault), 1_000_000);
    }
}

/// @notice Stateful: whatever reaches vaults is always exactly seller + fee afterwards.
contract BatchVaultsHandler is Test {
    P2FluxBatchVaults internal vaults;
    MockUSDCMintable internal token;
    address[3] internal sellers = [address(0xA1), address(0xA2), address(0xA3)];
    uint256 public deposited;

    constructor(P2FluxBatchVaults _vaults, MockUSDCMintable _token) {
        vaults = _vaults;
        token = _token;
    }

    function donate(uint8 who, uint256 amount) external {
        amount = bound(amount, 1, 1e13);
        token.mint(vaults.vaultOf(sellers[who % 3]), amount);
        deposited += amount;
    }

    function flush(uint8 who) external {
        address s = sellers[who % 3];
        if (token.balanceOf(vaults.vaultOf(s)) == 0) return;
        vaults.flush(s);
    }

    function held() external view returns (uint256 total) {
        for (uint256 i; i < 3; i++) {
            total += token.balanceOf(sellers[i]) + token.balanceOf(vaults.vaultOf(sellers[i]));
        }
    }
}

contract MockUSDCMintable is MockUSDC {}

contract BatchVaultsInvariantTest is Test {
    P2FluxBatchVaults internal vaults;
    MockUSDCMintable internal token;
    BatchVaultsHandler internal handler;
    address internal feeWallet = makeAddr("feeWallet");

    function setUp() public {
        token = new MockUSDCMintable();
        vaults = new P2FluxBatchVaults(address(token), feeWallet);
        handler = new BatchVaultsHandler(vaults, token);
        targetContract(address(handler));
    }

    function invariant_conservation() public view {
        assertEq(handler.held() + token.balanceOf(feeWallet), handler.deposited());
    }

    function invariant_factoryHoldsNothing() public view {
        assertEq(token.balanceOf(address(vaults)), 0);
    }

    function invariant_feeNeverAbove3Percent() public view {
        assertLe(token.balanceOf(feeWallet) * 10_000, handler.deposited() * 300);
    }
}
