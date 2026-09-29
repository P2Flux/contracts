// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxX402Splitter, ISignatureTransfer, IX402UptoPermit2Proxy} from "../../contracts/P2FluxX402Splitter.sol";

interface IProxyView {
    function PERMIT2() external view returns (address);
}

interface IFiatToken {
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice The same settlements as X402SplitterTest, against the REAL contracts on a fork: Circle's
///         FiatToken v2.2, Uniswap Permit2 and x402's upto proxy. The unit suite's proxy mock skips
///         Permit2's signature check; this proves the witness P2Flux relies on is exactly what Permit2
///         and the proxy verify, and that USDC's `bytes` overload is live.
///
///         A fork is a local simulation over real chain state: it reads, and sends nothing.
///         Skipped unless the RPC variable is set, so CI stays offline:
///           BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-contract X402SplitterSepoliaFork
///           BASE_MAINNET_RPC_URL=https://mainnet.base.org forge test --match-contract X402SplitterMainnetFork
abstract contract X402SplitterForkBase is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UPTO_PROXY = 0x4020A4f3b7b90ccA423B9fabCc0CE57C6C240002;
    /// @dev keccak256 of the upto proxy's runtime code, identical on Base and Base Sepolia (2026-09-29).
    bytes32 constant UPTO_PROXY_CODEHASH = 0x4662dc27323421a3698be49ac95f7b0dba141c238d31ef543248d1a11f8d8eec;

    address internal USDC;

    function _rpcVariable() internal pure virtual returns (string memory);
    function _usdc() internal pure virtual returns (address);
    function _tokenName() internal pure virtual returns (string memory);

    bytes32 constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    // Exactly the x402 client's uptoPermit2WitnessTypes, in EIP-712 canonical form.
    bytes32 constant PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Witness witness)TokenPermissions(address token,uint256 amount)Witness(address to,address facilitator,uint256 validAfter)"
    );
    bytes32 constant WITNESS_TYPEHASH = keccak256("Witness(address to,address facilitator,uint256 validAfter)");

    uint256 constant PAYER_KEY = 0xA11CE;
    address payer;
    address feeWallet = makeAddr("feeWallet");
    address relayer = makeAddr("relayer");
    address seller = makeAddr("seller");
    P2FluxX402Splitter splitter;
    address vault;

    function setUp() public {
        string memory rpc = vm.envOr(_rpcVariable(), string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        USDC = _usdc();
        payer = vm.addr(PAYER_KEY);
        splitter = new P2FluxX402Splitter(USDC, feeWallet, relayer, UPTO_PROXY, 3_000);
        vault = splitter.vaultOf(seller);
        deal(USDC, payer, 10e6);
    }

    /// What the contract is deployed against is what was reviewed.
    function test_fork_environmentIsTheReviewedOne() public view {
        assertEq(UPTO_PROXY.codehash, UPTO_PROXY_CODEHASH, "x402 upto proxy code changed");
        assertEq(address(IProxyView(UPTO_PROXY).PERMIT2()), PERMIT2);
        assertGt(PERMIT2.code.length, 0);
        assertEq(IFiatToken(USDC).name(), _tokenName());
        assertEq(IFiatToken(USDC).version(), "2");
        assertEq(IFiatToken(USDC).decimals(), 6);
    }

    function test_fork_exact() public {
        bytes32 nonce = keccak256("fork exact");
        uint256 validBefore = block.timestamp + 300;
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, vault, 1e6, 0, validBefore, nonce));
        bytes memory sig = _sign(IFiatToken(USDC).DOMAIN_SEPARATOR(), structHash);

        vm.prank(relayer);
        splitter.settleWithAuthorization(
            seller,
            10_000,
            P2FluxX402Splitter.Authorization({
                from: payer, value: 1e6, validAfter: 0, validBefore: validBefore, nonce: nonce
            }),
            sig
        );
        assertEq(IFiatToken(USDC).balanceOf(seller), 990_000);
        assertEq(IFiatToken(USDC).balanceOf(feeWallet), 10_000);
        assertEq(IFiatToken(USDC).balanceOf(payer), 9e6);
        assertEq(IFiatToken(USDC).balanceOf(vault), 0);
    }

    /// The real FiatToken blacklist: a frozen fee wallet locks nothing, the seller receives everything.
    function test_fork_feeWalletBlacklisted_sellerStillPaid() public {
        vm.prank(IFiatToken(USDC).blacklister());
        IFiatToken(USDC).blacklist(feeWallet);

        bytes32 nonce = keccak256("fork blacklist");
        uint256 validBefore = block.timestamp + 300;
        bytes32 structHash =
            keccak256(abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, payer, vault, 1e6, 0, validBefore, nonce));
        bytes memory sig = _sign(IFiatToken(USDC).DOMAIN_SEPARATOR(), structHash);
        vm.prank(relayer);
        splitter.settleWithAuthorization(
            seller,
            10_000,
            P2FluxX402Splitter.Authorization({
                from: payer, value: 1e6, validAfter: 0, validBefore: validBefore, nonce: nonce
            }),
            sig
        );
        assertEq(IFiatToken(USDC).balanceOf(seller), 1e6);
        assertEq(IFiatToken(USDC).balanceOf(feeWallet), 0);

        deal(USDC, vault, 50_000);
        splitter.flush(seller);
        assertEq(IFiatToken(USDC).balanceOf(seller), 1e6 + 50_000);
        assertEq(IFiatToken(USDC).balanceOf(vault), 0);
    }

    function test_fork_upto_withExistingPermit2Allowance() public {
        vm.prank(payer);
        IFiatToken(USDC).approve(PERMIT2, type(uint256).max);
        (
            ISignatureTransfer.PermitTransferFrom memory permit,
            IX402UptoPermit2Proxy.Witness memory witness,
            bytes memory sig
        ) = _uptoSignature(2e6, 777);

        vm.prank(relayer);
        splitter.settleUpto(seller, 2_000, permit, 150_000, payer, witness, sig);
        assertEq(IFiatToken(USDC).balanceOf(payer), 10e6 - 150_000, "debited the amount used");
        assertEq(IFiatToken(USDC).balanceOf(seller), 148_000);
        assertEq(IFiatToken(USDC).balanceOf(feeWallet), 2_000);
        assertEq(IFiatToken(USDC).balanceOf(vault), 0);
    }

    /// x402's eip2612GasSponsoring: a payer who never approved Permit2 signs a USDC permit instead.
    function test_fork_upto_withPermitForFreshWallet() public {
        uint256 deadline = block.timestamp + 300;
        bytes32 permitHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, payer, PERMIT2, uint256(2e6), IFiatToken(USDC).nonces(payer), deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PAYER_KEY, keccak256(abi.encodePacked("\x19\x01", IFiatToken(USDC).DOMAIN_SEPARATOR(), permitHash)));
        IX402UptoPermit2Proxy.EIP2612Permit memory p2612 =
            IX402UptoPermit2Proxy.EIP2612Permit({value: 2e6, deadline: deadline, r: r, s: s, v: v});
        (
            ISignatureTransfer.PermitTransferFrom memory permit,
            IX402UptoPermit2Proxy.Witness memory witness,
            bytes memory sig
        ) = _uptoSignature(2e6, 778);

        vm.prank(relayer);
        splitter.settleUptoWithPermit(seller, 2_000, p2612, permit, 50_000, payer, witness, sig);
        assertEq(IFiatToken(USDC).balanceOf(seller), 48_000);
        assertEq(IFiatToken(USDC).balanceOf(payer), 10e6 - 50_000);
    }

    /// The real proxy refuses any caller but the signed facilitator: nobody can settle our upto
    /// signatures around us, so they can never strand money.
    function test_fork_upto_onlySplitterCanExecute() public {
        vm.prank(payer);
        IFiatToken(USDC).approve(PERMIT2, type(uint256).max);
        (
            ISignatureTransfer.PermitTransferFrom memory permit,
            IX402UptoPermit2Proxy.Witness memory witness,
            bytes memory sig
        ) = _uptoSignature(1e6, 779);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes4(keccak256("UnauthorizedFacilitator()")));
        IX402UptoPermit2Proxy(UPTO_PROXY).settle(permit, 1e6, payer, witness, sig);
    }

    function _uptoSignature(uint256 max, uint256 nonce)
        internal
        view
        returns (
            ISignatureTransfer.PermitTransferFrom memory permit,
            IX402UptoPermit2Proxy.Witness memory witness,
            bytes memory sig
        )
    {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: USDC, amount: max}),
            nonce: nonce,
            deadline: block.timestamp + 300
        });
        witness = IX402UptoPermit2Proxy.Witness({to: vault, facilitator: address(splitter), validAfter: 0});
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_WITNESS_TYPEHASH,
                keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, USDC, max)),
                UPTO_PROXY, // Permit2's spender is its caller: the proxy
                nonce,
                permit.deadline,
                keccak256(abi.encode(WITNESS_TYPEHASH, witness.to, witness.facilitator, witness.validAfter))
            )
        );
        sig = _sign(IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash);
    }

    function _sign(bytes32 domainSeparator, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PAYER_KEY, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }
}

contract X402SplitterSepoliaForkTest is X402SplitterForkBase {
    function _rpcVariable() internal pure override returns (string memory) {
        return "BASE_SEPOLIA_RPC_URL";
    }

    function _usdc() internal pure override returns (address) {
        return 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    }

    function _tokenName() internal pure override returns (string memory) {
        return "USDC";
    }
}

contract X402SplitterMainnetForkTest is X402SplitterForkBase {
    function _rpcVariable() internal pure override returns (string memory) {
        return "BASE_MAINNET_RPC_URL";
    }

    function _usdc() internal pure override returns (address) {
        return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    }

    function _tokenName() internal pure override returns (string memory) {
        return "USD Coin";
    }
}
