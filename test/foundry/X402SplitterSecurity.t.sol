// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxTest} from "./Helpers.sol";
import {
    P2FluxX402Splitter,
    P2FluxX402Vault,
    ISignatureTransfer,
    IX402UptoPermit2Proxy
} from "../../contracts/P2FluxX402Splitter.sol";
import {MockUptoPermit2Proxy} from "../../contracts/test/MockX402.sol";
import {
    MockFiatToken,
    MockUSDC,
    Mock1271Wallet,
    WrongMagicWallet,
    RevertingWallet
} from "../../contracts/test/MockTokens.sol";

/// @dev An ERC-1271 wallet that burns gas in a VIEW before saying yes: the payer an attacker would
///      write to make the relayer pay for computation.
contract ViewGasBurnerWallet {
    function isValidSignature(bytes32 digest, bytes calldata) external pure returns (bytes4) {
        bytes32 h = digest;
        for (uint256 i = 0; i < 200_000; i++) {
            h = keccak256(abi.encode(h));
        }
        return h == bytes32(0) ? bytes4(0xffffffff) : bytes4(0x1626ba7e);
    }
}

/// @dev An ERC-1271 wallet that tries to call back into the splitter while its signature is checked.
contract ReentrantWallet {
    P2FluxX402Splitter internal splitter;
    address internal target;

    constructor(P2FluxX402Splitter _splitter, address _target) {
        splitter = _splitter;
        target = _target;
    }

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        splitter.flush(target);
        return 0x1626ba7e;
    }
}

/// @notice The findings of the 2026-09-29 security review, each as a test that failed before its fix,
///         and the properties the review confirmed, each as a regression test.
contract X402SplitterSecurityTest is P2FluxTest {
    P2FluxX402Splitter internal splitter;
    MockUptoPermit2Proxy internal proxy;

    uint256 internal constant MIN_FEE = 3_000;
    uint256 internal constant OTHER_KEY = 0xB0B;
    address internal other;
    address internal seller = makeAddr("seller");
    address internal sellerVault;

    event Paid(bytes32 indexed ref, address indexed recipient, address indexed token, uint256 net, uint256 fee);
    event Flushed(address indexed recipient, uint256 net, uint256 fee);

    function setUp() public {
        _baseSetUp();
        other = vm.addr(OTHER_KEY);
        proxy = new MockUptoPermit2Proxy();
        splitter = new P2FluxX402Splitter(address(token), feeWallet, relayer, address(proxy), MIN_FEE);
        sellerVault = splitter.vaultOf(seller);
    }

    function _auth(address from, uint256 value, bytes32 nonce)
        internal
        view
        returns (P2FluxX402Splitter.Authorization memory)
    {
        return P2FluxX402Splitter.Authorization({
            from: from, value: value, validAfter: 0, validBefore: block.timestamp + 300, nonce: nonce
        });
    }

    function _settle(uint256 key, address from, address recipient, uint256 value, uint256 fee, bytes32 nonce) internal {
        P2FluxX402Splitter.Authorization memory a = _auth(from, value, nonce);
        bytes memory sig = _signTransfer(key, from, splitter.vaultOf(recipient), value, a.validBefore, nonce);
        vm.prank(relayer);
        splitter.settleWithAuthorization(recipient, fee, a, sig);
    }

    function _permit(uint256 max, uint256 nonce) internal view returns (ISignatureTransfer.PermitTransferFrom memory) {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: max}),
            nonce: nonce,
            deadline: block.timestamp + 300
        });
    }

    function _witness() internal view returns (IX402UptoPermit2Proxy.Witness memory) {
        return IX402UptoPermit2Proxy.Witness({to: sellerVault, facilitator: address(splitter), validAfter: 0});
    }

    // --- C1: the payment id binds the payer -------------------------------------------------------

    /// Two wallets may use the same nonce: nobody can block a payment by paying first with its nonce.
    function testFuzz_sameNonceTwoPayers_bothSettle(bytes32 nonce, uint256 value) public {
        value = bound(value, 10_000, 1e12);
        token.mint(payer, value);
        token.mint(other, value);

        _settle(OTHER_KEY, other, seller, value, 0, nonce); // the attacker, first, same seller/amount/nonce
        _settle(PAYER_KEY, payer, seller, value, 0, nonce); // the victim still settles

        assertEq(token.balanceOf(seller), 2 * value);
        assertTrue(splitter.refOf(payer, nonce) != splitter.refOf(other, nonce));
    }

    /// An `upto` nonce equal to another payer's `exact` nonce does not collide either.
    function test_crossScheme_sameNonce_noCollision() public {
        bytes32 nonce = bytes32(uint256(42));
        token.mint(payer, 1e6);
        token.mint(other, 1e6);
        vm.prank(other);
        token.approve(address(proxy), 1e6);

        vm.prank(relayer);
        splitter.settleUpto(seller, 0, _permit(1e6, 42), 1e6, other, _witness(), "");
        _settle(PAYER_KEY, payer, seller, 1e6, 0, nonce);
        assertEq(token.balanceOf(seller), 2e6);
    }

    /// The same payer, the same nonce, is still one payment.
    function test_samePayerSameNonce_stillRefused() public {
        token.mint(payer, 2e6);
        _settle(PAYER_KEY, payer, seller, 1e6, 0, "n");
        P2FluxX402Splitter.Authorization memory a = _auth(payer, 1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, sellerVault, 1e6, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert();
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    // --- C2: a frozen fee wallet locks nothing ----------------------------------------------------

    function test_feeWalletBlacklisted_settlementPaysTheSellerEverything() public {
        token.setBlacklisted(feeWallet, true);
        token.mint(payer, 1e6);
        vm.expectEmit(address(splitter));
        emit Paid(splitter.refOf(payer, "n"), seller, address(token), 1e6, 0);
        _settle(PAYER_KEY, payer, seller, 1e6, 10_000, "n");
        assertEq(token.balanceOf(seller), 1e6, "the fee that could not be paid went to the seller");
        assertEq(token.balanceOf(feeWallet), 0);
        assertEq(token.balanceOf(sellerVault), 0);
    }

    function test_feeWalletBlacklisted_flushStillPaysTheSeller() public {
        token.mint(sellerVault, 500_000);
        token.setBlacklisted(feeWallet, true);
        vm.expectEmit(address(splitter));
        emit Flushed(seller, 500_000, 0);
        splitter.flush(seller);
        assertEq(token.balanceOf(seller), 500_000);
        assertEq(token.balanceOf(sellerVault), 0);
    }

    /// A seller the issuer froze cannot be paid; the payment is refused whole and stays unspent.
    function test_recipientBlacklisted_revertsAndNothingIsConsumed() public {
        token.setBlacklisted(seller, true);
        token.mint(payer, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(payer, 1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, sellerVault, 1e6, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert();
        splitter.settleWithAuthorization(seller, 10_000, a, sig);

        assertEq(token.balanceOf(payer), 1e6);
        assertFalse(token.authorizationState(payer, "n"), "the authorization is still unused");
        assertFalse(splitter.isPaymentProcessed(address(token), seller, 1e6, splitter.refOf(payer, "n")));
        // Unfrozen, the very same signature settles.
        token.setBlacklisted(seller, false);
        vm.prank(relayer);
        splitter.settleWithAuthorization(seller, 10_000, a, sig);
        assertEq(token.balanceOf(seller), 990_000);
    }

    function test_tokenPaused_everyPathRevertsCleanly() public {
        token.mint(payer, 2e6);
        token.mint(sellerVault, 1_000);
        vm.prank(payer);
        token.approve(address(proxy), 1e6);
        token.setPaused(true);

        P2FluxX402Splitter.Authorization memory a = _auth(payer, 1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, sellerVault, 1e6, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert();
        splitter.settleWithAuthorization(seller, 0, a, sig);
        vm.prank(relayer);
        vm.expectRevert();
        splitter.settleUpto(seller, 0, _permit(1e6, 1), 1e6, payer, _witness(), "");
        vm.expectRevert();
        splitter.flush(seller);

        assertEq(token.balanceOf(payer), 2e6);
        assertEq(token.balanceOf(sellerVault), 1_000);
        token.setPaused(false);
        vm.prank(relayer);
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    // --- C3 and fee bounds ------------------------------------------------------------------------

    /// Whatever the relayer asks, the fee is within max(1%, MIN_FEE) AND the seller gets at least half.
    function testFuzz_relayerCannotTakeMoreThanTheRules(uint256 value, uint256 fee) public {
        value = bound(value, 1, 1e15);
        fee = bound(fee, 0, type(uint128).max);
        token.mint(payer, value);
        P2FluxX402Splitter.Authorization memory a = _auth(payer, value, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, sellerVault, value, a.validBefore, "n");
        vm.prank(relayer);
        try splitter.settleWithAuthorization(seller, fee, a, sig) {
            assertLe(fee, splitter.maxFee(value));
            assertGe(token.balanceOf(seller), value - value / 2);
            assertEq(token.balanceOf(feeWallet), fee);
            assertEq(token.balanceOf(seller) + fee, value);
        } catch {
            assertTrue(fee > splitter.maxFee(value) || fee * 2 > value, "refused only for breaking a rule");
            assertEq(token.balanceOf(payer), value);
        }
    }

    function test_minFeeZeroDeployment_feeIsOnePercentOnly() public {
        P2FluxX402Splitter free = new P2FluxX402Splitter(address(token), feeWallet, relayer, address(proxy), 0);
        assertEq(free.maxFee(99), 0);
        assertEq(free.maxFee(10_000), 100);
        token.mint(payer, 99);
        P2FluxX402Splitter.Authorization memory a = _auth(payer, 99, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, free.vaultOf(seller), 99, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.FeeTooHigh.selector);
        free.settleWithAuthorization(seller, 1, a, sig);
    }

    // --- upto bounds ------------------------------------------------------------------------------

    function test_upto_amountEqualsMax() public {
        token.mint(payer, 1e6);
        vm.prank(payer);
        token.approve(address(proxy), 1e6);
        vm.prank(relayer);
        splitter.settleUpto(seller, 10_000, _permit(1e6, 1), 1e6, payer, _witness(), "");
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(seller), 990_000);
    }

    function testFuzz_upto_neverMoreThanTheSignedMaximum(uint256 max, uint256 amount) public {
        max = bound(max, 10_000, 1e12);
        amount = bound(amount, max + 1, type(uint128).max);
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(proxy), type(uint256).max);
        vm.prank(relayer);
        vm.expectRevert(MockUptoPermit2Proxy.AmountExceedsPermitted.selector);
        splitter.settleUpto(seller, 0, _permit(max, 1), amount, payer, _witness(), "");
        assertEq(token.balanceOf(payer), amount);
    }

    /// The payer's EIP-2612 permit was already submitted by someone else: the settlement still works.
    function test_uptoWithPermit_permitFrontRun_stillSettles() public {
        token.mint(payer, 1e6);
        uint256 deadline = block.timestamp + 300;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PAYER_KEY, payer, address(proxy), 1e6, deadline);
        token.permit(payer, address(proxy), 1e6, deadline, v, r, s); // front-run: nonce consumed
        IX402UptoPermit2Proxy.EIP2612Permit memory p =
            IX402UptoPermit2Proxy.EIP2612Permit({value: 1e6, deadline: deadline, r: r, s: s, v: v});
        vm.prank(relayer);
        splitter.settleUptoWithPermit(seller, 3_000, p, _permit(1e6, 1), 300_000, payer, _witness(), "");
        assertEq(token.balanceOf(seller), 297_000);
    }

    // --- contract-wallet payers -------------------------------------------------------------------

    function _settleFromWallet(address wallet, uint256 gasLimit) internal returns (bool ok) {
        token.mint(wallet, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(wallet, 1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, wallet, sellerVault, 1e6, a.validBefore, "n");
        vm.prank(relayer);
        (ok,) = address(splitter).call{gas: gasLimit}(
            abi.encodeCall(P2FluxX402Splitter.settleWithAuthorization, (seller, 0, a, sig))
        );
    }

    function _nothingHappened(address wallet) internal view {
        assertEq(token.balanceOf(wallet), 1e6, "payer untouched");
        assertEq(token.balanceOf(seller), 0);
        assertFalse(token.authorizationState(wallet, "n"));
        assertFalse(splitter.isPaymentProcessed(address(token), seller, 1e6, splitter.refOf(wallet, "n")));
    }

    function test_1271_walletThatSaysNo_isRefused() public {
        address wallet = address(new WrongMagicWallet());
        assertFalse(_settleFromWallet(wallet, 1_000_000));
        _nothingHappened(wallet);
    }

    function test_1271_walletThatReverts_isRefused() public {
        address wallet = address(new RevertingWallet());
        assertFalse(_settleFromWallet(wallet, 1_000_000));
        _nothingHappened(wallet);
    }

    /// The relayer's gas cap is the bound: a wallet that burns gas makes the settlement fail inside
    /// the cap, and nothing is consumed - it cannot make the relayer pay for more than the cap.
    function test_1271_walletThatBurnsGas_failsInsideTheGasCap() public {
        address wallet = address(new ViewGasBurnerWallet());
        uint256 before = gasleft();
        assertFalse(_settleFromWallet(wallet, 400_000));
        assertLt(before - gasleft(), 600_000, "bounded by the cap, plus this test's own overhead");
        _nothingHappened(wallet);
    }

    /// Signature checks run under STATICCALL: a wallet cannot call back into the splitter from one.
    function test_1271_walletCannotReenter() public {
        token.mint(sellerVault, 5_000);
        address wallet = address(new ReentrantWallet(splitter, seller));
        assertFalse(_settleFromWallet(wallet, 1_000_000));
        _nothingHappened(wallet);
        assertEq(token.balanceOf(sellerVault), 5_000, "flush did not run");
    }

    function test_1271_honestWallet_upto() public {
        Mock1271Wallet wallet = new Mock1271Wallet(payer);
        token.mint(address(wallet), 1e6);
        vm.prank(address(wallet));
        token.approve(address(proxy), 1e6);
        vm.prank(relayer);
        splitter.settleUpto(seller, 3_000, _permit(1e6, 9), 100_000, address(wallet), _witness(), "");
        assertEq(token.balanceOf(seller), 97_000);
    }

    // --- the vault --------------------------------------------------------------------------------

    function testFuzz_vaultOf_isTheDeployedVault(address recipient, uint256 value) public {
        vm.assume(recipient != address(0) && recipient != feeWallet && recipient.code.length == 0);
        vm.assume(recipient != address(token) && recipient != address(splitter));
        value = bound(value, 1, 1e12);
        address vault = splitter.vaultOf(recipient);
        vm.assume(vault != recipient);
        token.mint(vault, value);
        splitter.flush(recipient);
        assertGt(vault.code.length, 0);
        assertEq(P2FluxX402Vault(vault).recipient(), recipient);
        assertEq(P2FluxX402Vault(vault).factory(), address(splitter));
        assertEq(token.balanceOf(recipient) + token.balanceOf(feeWallet), value);
    }

    /// A vault deployed by anyone else, for the same seller, is a different address.
    function test_vaultDeployedByAStranger_isNotTheSellersVault() public {
        vm.prank(makeAddr("stranger"));
        P2FluxX402Vault fake = new P2FluxX402Vault{salt: bytes32(0)}(seller);
        assertTrue(address(fake) != sellerVault);
    }

    /// A token that is not the supported one, sent to a vault, is never touched.
    function test_otherTokenInVault_isUntouchedByFlush() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(sellerVault, 777);
        token.mint(sellerVault, 1_000);
        splitter.flush(seller);
        assertEq(stray.balanceOf(sellerVault), 777);
        assertEq(token.balanceOf(sellerVault), 0);
    }

    /// flush between the relayer's simulation and its settlement changes nothing for the settlement.
    function test_flushBeforeSettlement_settlementUnaffected() public {
        token.mint(sellerVault, 2_000);
        token.mint(payer, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(payer, 1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, sellerVault, 1e6, a.validBefore, "n");
        vm.prank(makeAddr("anyone"));
        splitter.flush(seller);
        vm.prank(relayer);
        splitter.settleWithAuthorization(seller, 10_000, a, sig);
        assertEq(token.balanceOf(seller), 1_980 + 990_000);
        assertEq(token.balanceOf(feeWallet), 20 + 10_000);
    }
}
