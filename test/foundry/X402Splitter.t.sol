// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {
    P2FluxX402Splitter,
    P2FluxX402Vault,
    ISignatureTransfer,
    IX402UptoPermit2Proxy
} from "../../contracts/P2FluxX402Splitter.sol";
import {MockUptoPermit2Proxy} from "../../contracts/test/MockX402.sol";
import {Mock1271Wallet} from "../../contracts/test/MockTokens.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice x402 settlement: an agent pays a seller's vault with an unmodified x402 client; P2Flux
///         settles it and takes a bounded fee. The properties that matter: the payer is debited the
///         signed amount and nothing else, the seller receives everything but the fee, the fee never
///         exceeds max(1%, 0.002), no key can send a seller's money anywhere but to that seller, and
///         nothing is left behind in any contract.
contract X402SplitterTest is P2FluxTest {
    P2FluxX402Splitter internal splitter;
    MockUptoPermit2Proxy internal proxy;

    address internal seller = makeAddr("seller");
    /// @dev Resolved once: `vaultOf` is an external call, and one inside an argument list would
    ///      consume the `vm.prank` / `vm.expectRevert` meant for the settlement call itself.
    address internal sellerVault;

    /// @dev The launch floor recorded in the deploy manifest: 0.003 USDC.
    uint256 internal constant MIN_FEE = 3_000;

    event Paid(bytes32 indexed ref, address indexed recipient, address indexed token, uint256 net, uint256 fee);
    event PaymentSettled(bytes32 indexed paymentId);
    event Flushed(address indexed recipient, uint256 net, uint256 fee);

    function setUp() public {
        _baseSetUp();
        proxy = new MockUptoPermit2Proxy();
        splitter = new P2FluxX402Splitter(address(token), feeWallet, relayer, address(proxy), MIN_FEE);
        sellerVault = splitter.vaultOf(seller);
    }

    // --- exact --------------------------------------------------------------

    function _auth(uint256 value, bytes32 nonce) internal view returns (P2FluxX402Splitter.Authorization memory) {
        return P2FluxX402Splitter.Authorization({
            from: payer, value: value, validAfter: 0, validBefore: block.timestamp + 300, nonce: nonce
        });
    }

    function _settleExact(address recipient, uint256 value, uint256 fee, bytes32 nonce) internal {
        P2FluxX402Splitter.Authorization memory a = _auth(value, nonce);
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(recipient), value, a.validBefore, nonce);
        vm.prank(relayer);
        splitter.settleWithAuthorization(recipient, fee, a, sig);
    }

    /// payer outflow == seller net + P2Flux fee, exactly; nothing stays in the splitter or the vault.
    function testFuzz_exact_conservation(uint256 value, uint256 fee, bytes32 nonce, uint256 recipientSeed) public {
        value = bound(value, 2, 1e15);
        uint256 cap = splitter.maxFee(value);
        fee = bound(fee, 0, cap < value ? cap : value - 1);
        address recipient = _cleanAddress(recipientSeed, address(splitter));
        vm.assume(recipient != splitter.vaultOf(recipient));
        token.mint(payer, value);

        _settleExact(recipient, value, fee, nonce);

        assertEq(token.balanceOf(payer), 0, "payer debited exactly the signed amount");
        assertEq(token.balanceOf(recipient), value - fee, "seller receives everything but the fee");
        assertEq(token.balanceOf(feeWallet), fee, "fee wallet receives the fee only");
        assertEq(token.balanceOf(splitter.vaultOf(recipient)), 0, "vault keeps nothing");
        assertEq(token.balanceOf(address(splitter)), 0, "splitter keeps nothing");
        assertTrue(splitter.isPaymentProcessed(address(token), recipient, value, nonce));
    }

    /// The events are P2FluxSplitter's, with the signature's nonce as the reference.
    function test_exact_eventsCarryTheNonceAsReference() public {
        token.mint(payer, 50_000);
        bytes32 nonce = keccak256("agent-nonce");
        bytes32 id = splitter.paymentId(address(token), seller, 50_000, nonce);
        vm.expectEmit(address(splitter));
        emit Paid(nonce, seller, address(token), 48_000, 2_000);
        vm.expectEmit(address(splitter));
        emit PaymentSettled(id);
        _settleExact(seller, 50_000, 2_000, nonce);
    }

    /// payTo is the vault: deterministic, deployed on first use, bound to exactly one seller.
    function test_vaultIsDeterministicAndBoundToTheSeller() public {
        address vault = splitter.vaultOf(seller);
        assertEq(vault.code.length, 0, "not deployed before first use");
        token.mint(payer, 1e6);
        _settleExact(seller, 1e6, 10_000, "n1");
        assertGt(vault.code.length, 0, "deployed by the first settlement");
        assertEq(P2FluxX402Vault(vault).recipient(), seller);
        assertEq(P2FluxX402Vault(vault).factory(), address(splitter));
        assertTrue(splitter.vaultOf(makeAddr("other seller")) != vault, "one vault per seller");
        // Second payment reuses the vault.
        token.mint(payer, 1e6);
        _settleExact(seller, 1e6, 10_000, "n2");
        assertEq(token.balanceOf(seller), 2 * (1e6 - 10_000));
    }

    /// The relayer cannot redirect: a signature for seller A's vault does not settle to seller B.
    function testFuzz_exact_relayerCannotRedirect(uint256 seed) public {
        address thief = _cleanAddress(seed, seller);
        token.mint(payer, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert("invalid authorization signature");
        splitter.settleWithAuthorization(thief, 0, a, sig);
        assertEq(token.balanceOf(payer), 1e6, "nothing moved");
    }

    /// Nor can it inflate the amount: the token checks the signed value.
    function test_exact_amountIsTheSignedAmount() public {
        token.mint(payer, 2e6);
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        a.value = 2e6;
        vm.prank(relayer);
        vm.expectRevert("invalid authorization signature");
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    function testFuzz_exact_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        token.mint(payer, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        vm.prank(caller);
        vm.expectRevert(P2FluxX402Splitter.NotRelayer.selector);
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    /// The fee never exceeds max(1%, MIN_FEE).
    function testFuzz_feeAboveMaxRefused(uint256 value, uint256 fee) public {
        value = bound(value, 1, 1e15);
        fee = bound(fee, splitter.maxFee(value) + 1, type(uint128).max);
        token.mint(payer, value);
        P2FluxX402Splitter.Authorization memory a = _auth(value, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), value, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.FeeTooHigh.selector);
        splitter.settleWithAuthorization(seller, fee, a, sig);
    }

    /// A fee that would leave the seller nothing is refused, even when it is within maxFee.
    function test_feeConsumingTheWholeAmountRefused() public {
        token.mint(payer, 2_000);
        P2FluxX402Splitter.Authorization memory a = _auth(2_000, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 2_000, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.AmountTooSmall.selector);
        splitter.settleWithAuthorization(seller, 2_000, a, sig);
    }

    function test_maxFee_isOnePercentWithAFloor() public view {
        assertEq(splitter.maxFee(0), 3_000);
        assertEq(splitter.maxFee(10_000), 3_000, "$0.01 pays the floor");
        assertEq(splitter.maxFee(300_000), 3_000, "$0.30 is where 1% meets the floor");
        assertEq(splitter.maxFee(400_000), 4_000, "$0.40 pays 1%");
        assertEq(splitter.maxFee(100e6), 1e6, "$100 pays $1");
    }

    /// The same payment settles once.
    function test_exact_replayRefused() public {
        token.mint(payer, 2e6);
        _settleExact(seller, 1e6, 0, "n");
        bytes32 id = splitter.paymentId(address(token), seller, 1e6, "n");
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(P2FluxX402Splitter.PaymentAlreadyProcessed.selector, id));
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    function test_exact_expiredRefused() public {
        token.mint(payer, 1e6);
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        vm.warp(a.validBefore);
        vm.prank(relayer);
        vm.expectRevert("authorization is expired");
        splitter.settleWithAuthorization(seller, 0, a, sig);
    }

    /// A smart-account agent (ERC-1271) pays exactly as an EOA does.
    function test_exact_smartWalletPayer() public {
        Mock1271Wallet wallet = new Mock1271Wallet(payer);
        token.mint(address(wallet), 1e6);
        P2FluxX402Splitter.Authorization memory a = P2FluxX402Splitter.Authorization({
            from: address(wallet), value: 1e6, validAfter: 0, validBefore: block.timestamp + 300, nonce: "n"
        });
        bytes memory sig = _signTransfer(PAYER_KEY, address(wallet), splitter.vaultOf(seller), 1e6, a.validBefore, "n");
        vm.prank(relayer);
        splitter.settleWithAuthorization(seller, 10_000, a, sig);
        assertEq(token.balanceOf(seller), 1e6 - 10_000);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    // --- stranded money and flush ---------------------------------------------

    /// Someone submits the agent's authorization straight to the token: the money lands in the
    /// seller's vault, the relayer's settlement fails harmlessly, and anyone can pay it out - only
    /// ever to that seller.
    function test_strandedAuthorizationIsFlushedToTheSeller() public {
        token.mint(payer, 1e6);
        address vault = splitter.vaultOf(seller);
        P2FluxX402Splitter.Authorization memory a = _auth(1e6, "n");
        bytes memory sig = _signTransfer(PAYER_KEY, payer, vault, 1e6, a.validBefore, "n");

        vm.prank(makeAddr("stranger"));
        token.transferWithAuthorization(payer, vault, 1e6, 0, a.validBefore, "n", sig);
        assertEq(token.balanceOf(vault), 1e6);

        vm.prank(relayer);
        vm.expectRevert("authorization is used or canceled");
        splitter.settleWithAuthorization(seller, 0, a, sig);

        vm.expectEmit(address(splitter));
        emit Flushed(seller, 990_000, 10_000);
        vm.prank(makeAddr("anyone"));
        splitter.flush(seller);
        assertEq(token.balanceOf(seller), 990_000);
        assertEq(token.balanceOf(feeWallet), 10_000);
        assertEq(token.balanceOf(vault), 0);
    }

    /// Money sent to a vault outside a settlement is never used to pay a settlement.
    function test_donationIsLeftForFlush() public {
        address vault = splitter.vaultOf(seller);
        token.mint(vault, 777);
        token.mint(payer, 1e6);
        _settleExact(seller, 1e6, 10_000, "n");
        assertEq(token.balanceOf(vault), 777, "donation untouched");
        assertEq(token.balanceOf(seller), 1e6 - 10_000);
        splitter.flush(seller);
        assertEq(token.balanceOf(vault), 0);
        assertEq(token.balanceOf(seller), 1e6 - 10_000 + 777 - 7);
    }

    function test_flushEmptyVaultRefused() public {
        vm.expectRevert(P2FluxX402Splitter.ZeroAmount.selector);
        splitter.flush(seller);
    }

    function testFuzz_vaultReleaseOnlyByFactory(address caller) public {
        token.mint(payer, 1e6);
        _settleExact(seller, 1e6, 0, "n");
        vm.assume(caller != address(splitter));
        P2FluxX402Vault vault = P2FluxX402Vault(splitter.vaultOf(seller));
        vm.prank(caller);
        vm.expectRevert(P2FluxX402Vault.NotFactory.selector);
        vault.release(IERC20(address(token)), caller, 0, 0);
    }

    // --- upto ---------------------------------------------------------------

    function _permit(uint256 max, uint256 nonce) internal view returns (ISignatureTransfer.PermitTransferFrom memory) {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: max}),
            nonce: nonce,
            deadline: block.timestamp + 300
        });
    }

    function _witness(address to) internal view returns (IX402UptoPermit2Proxy.Witness memory) {
        return IX402UptoPermit2Proxy.Witness({to: to, facilitator: address(splitter), validAfter: 0});
    }

    /// payer outflow == the amount actually used (<= signed max) == seller net + fee.
    function testFuzz_upto_conservation(uint256 max, uint256 used, uint256 fee, uint256 nonce) public {
        max = bound(max, 2, 1e15);
        used = bound(used, 2, max);
        uint256 cap = splitter.maxFee(used);
        fee = bound(fee, 0, cap < used ? cap : used - 1);
        token.mint(payer, max);
        vm.prank(payer);
        token.approve(address(proxy), max);

        vm.prank(relayer);
        splitter.settleUpto(seller, fee, _permit(max, nonce), used, payer, _witness(sellerVault), "");

        assertEq(token.balanceOf(payer), max - used, "debited the amount used, not the maximum");
        assertEq(token.balanceOf(seller), used - fee);
        assertEq(token.balanceOf(feeWallet), fee);
        assertEq(token.balanceOf(splitter.vaultOf(seller)), 0);
        assertTrue(splitter.isPaymentProcessed(address(token), seller, used, bytes32(nonce)));
    }

    function test_upto_withPermitForAPayerWhoNeverApproved() public {
        token.mint(payer, 1e6);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PAYER_KEY, payer, address(proxy), 1e6, block.timestamp + 300);
        IX402UptoPermit2Proxy.EIP2612Permit memory p2612 =
            IX402UptoPermit2Proxy.EIP2612Permit({value: 1e6, deadline: block.timestamp + 300, r: r, s: s, v: v});
        vm.prank(relayer);
        splitter.settleUptoWithPermit(seller, 2_000, p2612, _permit(1e6, 1), 400_000, payer, _witness(sellerVault), "");
        assertEq(token.balanceOf(seller), 398_000);
        assertEq(token.balanceOf(payer), 600_000);
    }

    /// The upto proxy pays `witness.to`; it must be this seller's vault.
    function test_upto_witnessMustBeTheSellersVault() public {
        token.mint(payer, 1e6);
        vm.prank(payer);
        token.approve(address(proxy), 1e6);
        address otherVault = splitter.vaultOf(makeAddr("other"));
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.WrongDestination.selector);
        splitter.settleUpto(seller, 0, _permit(1e6, 1), 1e6, payer, _witness(otherVault), "");
    }

    function test_upto_otherTokenRefused() public {
        ISignatureTransfer.PermitTransferFrom memory p = _permit(1e6, 1);
        p.permitted.token = makeAddr("not usdc");
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.TokenNotSupported.selector);
        splitter.settleUpto(seller, 0, p, 1e6, payer, _witness(sellerVault), "");
    }

    function testFuzz_upto_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        vm.prank(caller);
        vm.expectRevert(P2FluxX402Splitter.NotRelayer.selector);
        splitter.settleUpto(seller, 0, _permit(1e6, 1), 1e6, payer, _witness(sellerVault), "");
    }

    /// A proxy that moved anything but the amount asked for is caught before any release.
    function test_upto_shortchangedPullRefused() public {
        token.mint(payer, 1e6);
        vm.prank(payer);
        token.approve(address(proxy), 1e6);
        proxy.setShortchange(true);
        vm.prank(relayer);
        vm.expectRevert(P2FluxX402Splitter.UnexpectedAmount.selector);
        splitter.settleUpto(seller, 0, _permit(1e6, 1), 1e6, payer, _witness(sellerVault), "");
    }

    function test_upto_replayRefused() public {
        token.mint(payer, 2e6);
        vm.prank(payer);
        token.approve(address(proxy), 2e6);
        vm.prank(relayer);
        splitter.settleUpto(seller, 0, _permit(1e6, 7), 1e6, payer, _witness(sellerVault), "");
        bytes32 id = splitter.paymentId(address(token), seller, 1e6, bytes32(uint256(7)));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(P2FluxX402Splitter.PaymentAlreadyProcessed.selector, id));
        splitter.settleUpto(seller, 0, _permit(1e6, 7), 1e6, payer, _witness(sellerVault), "");
    }

    // --- construction ---------------------------------------------------------

    function test_constructorRefusesMissingCode() public {
        vm.expectRevert(P2FluxX402Splitter.NotAContract.selector);
        new P2FluxX402Splitter(makeAddr("no code"), feeWallet, relayer, address(proxy), MIN_FEE);
        vm.expectRevert(P2FluxX402Splitter.NotAContract.selector);
        new P2FluxX402Splitter(address(token), feeWallet, relayer, makeAddr("no proxy"), MIN_FEE);
        vm.expectRevert(P2FluxX402Splitter.ZeroAddress.selector);
        new P2FluxX402Splitter(address(token), address(0), relayer, address(proxy), MIN_FEE);
    }
}
