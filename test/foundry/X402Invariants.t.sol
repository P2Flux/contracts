// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFiatToken} from "../../contracts/test/MockTokens.sol";
import {MockUptoPermit2Proxy} from "../../contracts/test/MockX402.sol";
import {P2FluxX402Splitter, ISignatureTransfer, IX402UptoPermit2Proxy} from "../../contracts/P2FluxX402Splitter.sol";

/*
 * Stateful invariants for x402 settlement. The handler drives the splitter through random sequences -
 * exact and upto settlements with any fee the relayer might ask, authorizations submitted straight
 * to the token, donations, flushes, replays, strangers - and keeps its own ledger of what each party
 * SHOULD hold. It knows the published rules (fee <= max(1%, MIN_FEE), seller >= half, flush = 1%) and
 * nothing about how the contract implements them.
 */
contract X402Handler is Test {
    P2FluxX402Splitter public splitter;
    MockFiatToken public token;
    MockUptoPermit2Proxy public proxy;
    address public relayer;
    address public feeWallet;

    uint256 internal constant N = 3;
    uint256[N] internal keys = [uint256(0xA11CE), 0xB0B, 0xCA201];
    address[N] public sellers = [address(0x5E11E201), address(0x5E11E202), address(0x5E11E203)];

    // The independent ledger.
    mapping(address => uint256) public owedToSeller; // what each seller must hold
    mapping(address => uint256) public stray; // what each vault must hold
    uint256 public owedToFeeWallet;
    uint256 public totalMinted;
    uint256 public settlements;
    uint256 public flushes;

    // Things that must never happen.
    bool public strangerSettled;
    bool public replaySettled;
    bool public ruleBreakingFeeSettled;
    bool public moreThanSignedMaximumSettled;

    uint256 internal nextNonce = 1;

    struct Last {
        address seller;
        uint256 fee;
        P2FluxX402Splitter.Authorization a;
        bytes sig;
    }

    Last internal last;
    bool internal hasLast;

    constructor(
        P2FluxX402Splitter _splitter,
        MockFiatToken _token,
        MockUptoPermit2Proxy _proxy,
        address _relayer,
        address _fee
    ) {
        splitter = _splitter;
        token = _token;
        proxy = _proxy;
        relayer = _relayer;
        feeWallet = _fee;
        for (uint256 i; i < N; i++) {
            vm.prank(vm.addr(keys[i]));
            token.approve(address(proxy), type(uint256).max);
        }
    }

    function payerOf(uint256 i) public view returns (address) {
        return vm.addr(keys[i % N]);
    }

    function _sign(uint256 key, address to, uint256 value, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), vm.addr(key), to, value, uint256(0), validBefore, nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _breaksARule(uint256 amount, uint256 fee) internal view returns (bool) {
        return fee > splitter.maxFee(amount) || fee * 2 > amount;
    }

    function _mint(address to, uint256 amount) internal {
        token.mint(to, amount);
        totalMinted += amount;
    }

    /// The relayer settles an exact payment, asking for ANY fee.
    function settleExact(uint256 payerSeed, uint256 sellerSeed, uint256 amount, uint256 fee) external {
        amount = bound(amount, 1, 1e9);
        fee = bound(fee, 0, amount); // includes every fee the rules refuse
        uint256 key = keys[payerSeed % N];
        address seller = sellers[sellerSeed % N];
        _mint(vm.addr(key), amount);

        P2FluxX402Splitter.Authorization memory a = P2FluxX402Splitter.Authorization({
            from: vm.addr(key),
            value: amount,
            validAfter: 0,
            validBefore: block.timestamp + 300,
            nonce: bytes32(nextNonce++)
        });
        bytes memory sig = _sign(key, splitter.vaultOf(seller), amount, a.validBefore, a.nonce);

        vm.prank(relayer);
        try splitter.settleWithAuthorization(seller, fee, a, sig) {
            if (_breaksARule(amount, fee)) ruleBreakingFeeSettled = true;
            owedToSeller[seller] += amount - fee;
            owedToFeeWallet += fee;
            settlements++;
            last = Last({seller: seller, fee: fee, a: a, sig: sig});
            hasLast = true;
        } catch {}
    }

    /// The relayer settles part of an upto maximum - or tries to settle more than it.
    function settleUpto(uint256 payerSeed, uint256 sellerSeed, uint256 max, uint256 used, uint256 fee) external {
        max = bound(max, 1, 1e9);
        used = bound(used, 1, max + 5); // up to five units over the signed maximum
        fee = bound(fee, 0, used);
        uint256 key = keys[payerSeed % N];
        address seller = sellers[sellerSeed % N];
        _mint(vm.addr(key), used);

        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: max}),
            nonce: nextNonce++,
            deadline: block.timestamp + 300
        });
        IX402UptoPermit2Proxy.Witness memory w = IX402UptoPermit2Proxy.Witness({
            to: splitter.vaultOf(seller), facilitator: address(splitter), validAfter: 0
        });
        vm.prank(relayer);
        try splitter.settleUpto(seller, fee, permit, used, vm.addr(key), w, "") {
            if (used > max) moreThanSignedMaximumSettled = true;
            if (_breaksARule(used, fee)) ruleBreakingFeeSettled = true;
            owedToSeller[seller] += used - fee;
            owedToFeeWallet += fee;
            settlements++;
        } catch {}
    }

    /// Someone submits a payer's authorization straight to the token: it lands in the vault.
    function strand(uint256 payerSeed, uint256 sellerSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e9);
        uint256 key = keys[payerSeed % N];
        address seller = sellers[sellerSeed % N];
        address vault = splitter.vaultOf(seller);
        _mint(vm.addr(key), amount);
        bytes32 nonce = bytes32(nextNonce++);
        bytes memory sig = _sign(key, vault, amount, block.timestamp + 300, nonce);
        token.transferWithAuthorization(vm.addr(key), vault, amount, 0, block.timestamp + 300, nonce, sig);
        stray[seller] += amount;
    }

    function donate(uint256 sellerSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e7);
        address seller = sellers[sellerSeed % N];
        _mint(splitter.vaultOf(seller), amount);
        stray[seller] += amount;
    }

    /// Anyone flushes a vault: the seller gets it, less 1%.
    function flush(uint256 sellerSeed, address caller) external {
        address seller = sellers[sellerSeed % N];
        uint256 held = stray[seller];
        vm.prank(caller);
        try splitter.flush(seller) {
            uint256 fee = held / 100;
            owedToSeller[seller] += held - fee;
            owedToFeeWallet += fee;
            stray[seller] = 0;
            flushes++;
        } catch {
            assertEq(held, 0, "flush may only refuse an empty vault");
        }
    }

    /// The last settled payment, submitted again.
    function replay() external {
        if (!hasLast) return;
        vm.prank(relayer);
        try splitter.settleWithAuthorization(last.seller, last.fee, last.a, last.sig) {
            replaySettled = true;
        } catch {}
    }

    /// Anyone but the relayer tries to settle.
    function strangerSettles(address caller, uint256 sellerSeed, uint256 amount) external {
        vm.assume(caller != relayer);
        amount = bound(amount, 10_000, 1e9);
        address seller = sellers[sellerSeed % N];
        P2FluxX402Splitter.Authorization memory a = P2FluxX402Splitter.Authorization({
            from: vm.addr(keys[0]),
            value: amount,
            validAfter: 0,
            validBefore: block.timestamp + 300,
            nonce: bytes32(nextNonce++)
        });
        bytes memory sig = _sign(keys[0], splitter.vaultOf(seller), amount, a.validBefore, a.nonce);
        vm.prank(caller);
        try splitter.settleWithAuthorization(seller, 0, a, sig) {
            strangerSettled = true;
        } catch {}
    }

    function sumOfBalances() external view returns (uint256 sum) {
        sum = token.balanceOf(feeWallet) + token.balanceOf(address(splitter));
        for (uint256 i; i < N; i++) {
            sum += token.balanceOf(sellers[i]) + token.balanceOf(splitter.vaultOf(sellers[i]))
            + token.balanceOf(vm.addr(keys[i]));
        }
    }
}

contract X402InvariantTest is Test {
    X402Handler internal handler;
    P2FluxX402Splitter internal splitter;
    MockFiatToken internal token;
    address internal feeWallet = makeAddr("feeWallet");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockFiatToken();
        MockUptoPermit2Proxy proxy = new MockUptoPermit2Proxy();
        splitter = new P2FluxX402Splitter(address(token), feeWallet, relayer, address(proxy), 3_000);
        handler = new X402Handler(splitter, token, proxy, relayer, feeWallet);
        targetContract(address(handler));
    }

    /// The handler is not vacuous: each of its actions really does what the ledger records.
    function test_handlerActuallyMovesMoney() public {
        handler.settleExact(0, 0, 1e6, 10_000);
        handler.settleUpto(1, 1, 1e6, 400_000, 4_000);
        handler.strand(2, 2, 50_000);
        handler.donate(2, 1_000);
        handler.flush(2, address(this));
        handler.replay();
        handler.strangerSettles(address(this), 0, 1e6);
        assertEq(handler.settlements(), 2);
        assertEq(handler.flushes(), 1);
        assertEq(token.balanceOf(handler.sellers(0)), 990_000);
        assertEq(token.balanceOf(handler.sellers(1)), 396_000);
        assertEq(token.balanceOf(handler.sellers(2)), 50_490);
        assertEq(token.balanceOf(feeWallet), 10_000 + 4_000 + 510);
        invariant_nothingForbiddenEverSettles();
        invariant_supplyIsConserved();
    }

    function invariant_splitterNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function invariant_everySellerHoldsExactlyWhatItIsOwed() public view {
        for (uint256 i; i < 3; i++) {
            address seller = handler.sellers(i);
            assertEq(token.balanceOf(seller), handler.owedToSeller(seller), "seller");
            assertEq(token.balanceOf(splitter.vaultOf(seller)), handler.stray(seller), "vault holds only stray money");
        }
    }

    function invariant_feeWalletHoldsExactlyTheFees() public view {
        assertEq(token.balanceOf(feeWallet), handler.owedToFeeWallet());
    }

    function invariant_supplyIsConserved() public view {
        assertEq(handler.sumOfBalances(), handler.totalMinted());
    }

    function invariant_nothingForbiddenEverSettles() public view {
        assertFalse(handler.strangerSettled(), "a stranger settled");
        assertFalse(handler.replaySettled(), "a replay settled");
        assertFalse(handler.ruleBreakingFeeSettled(), "a fee above the rules settled");
        assertFalse(handler.moreThanSignedMaximumSettled(), "more than the signed maximum settled");
    }
}
