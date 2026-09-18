// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFiatToken} from "../../contracts/test/MockTokens.sol";

/// @notice Shared fixtures for the fuzz and invariant suites: a FiatToken-shaped USDC mock and the
///         three signatures the contracts rely on (EIP-3009 receive, EIP-2612 permit, and whatever
///         digest a contract hands us).
abstract contract P2FluxTest is Test {
    MockFiatToken internal token;

    address internal feeWallet = makeAddr("feeWallet");
    address internal gasTreasury = makeAddr("gasTreasury");
    address internal relayer = makeAddr("relayer");
    address internal admin = makeAddr("admin");

    uint256 internal constant PAYER_KEY = 0xA11CE;
    address internal payer;

    /// @dev Matches the production constructor arguments recorded in the mainnet manifest.
    uint256 internal constant FIXED_NETWORK_FEE = 100_000; // 0.10 USDC
    uint256 internal constant SPONSORED_FEE_CAP = 250_000; // 0.25 USDC

    function _baseSetUp() internal {
        vm.warp(1_700_000_000);
        token = new MockFiatToken();
        payer = vm.addr(PAYER_KEY);
    }

    /// @dev A fuzzed address that cannot collide with any account whose balance a test measures.
    function _cleanAddress(uint256 seed, address extra) internal view returns (address a) {
        a = address(uint160(bound(seed, 0x10000, type(uint160).max)));
        vm.assume(a != payer && a != feeWallet && a != gasTreasury && a != relayer && a != admin);
        vm.assume(a != address(token) && a != extra && a != address(this));
        vm.assume(a.code.length == 0);
    }

    function _signReceive(uint256 key, address from, address to, uint256 value, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, uint256(0), validBefore, nonce)
        );
        (v, r, s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), owner, spender, value, token.nonces(owner), deadline));
        (v, r, s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
