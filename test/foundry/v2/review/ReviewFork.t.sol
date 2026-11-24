// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSplitterV2} from "../../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function blacklister() external view returns (address);
    function configureMinter(address, uint256) external returns (bool);
    function mint(address, uint256) external returns (bool);
    function blacklist(address) external;
    function unBlacklist(address) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function version() external view returns (string memory);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address, bytes32) external view returns (bool);
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external;
    function receiveWithAuthorization(address, address, uint256, uint256, uint256, bytes32, uint8, bytes32, bytes32)
        external;
}

/// @notice Review fork tests against the REAL Base USDC (FiatToken) on a local anvil fork.
///         Run:  anvil --fork-url https://mainnet.base.org --fork-block-number 61552000 --port 8547
///               forge test --fork-url http://127.0.0.1:8547 --match-path 'test/foundry/v2/review/ReviewFork.t.sol'
///         Skipped automatically when not on a Base (8453) fork. Only local-fork impersonation of the
///         USDC master minter / blacklister is used; no keys other than test-only ones.
contract ReviewForkTest is Test {
    IFiatToken constant USDC = IFiatToken(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 constant KEY = uint256(keccak256("p2flux-review-2026-11-24-test-only"));
    address payer;
    address merchant = makeAddr("fork-merchant");
    address feeWallet = makeAddr("fork-feeWallet");
    address gasTreasury = makeAddr("fork-gasTreasury");
    address relayer = makeAddr("fork-relayer");
    address admin = makeAddr("fork-admin");
    address attacker = makeAddr("fork-attacker");

    Reg registry;
    P2FluxSplitterV2 splitter;
    Sponsored sponsored;
    Recurring recurring;
    P2FluxSend sender;

    modifier onlyFork() {
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 8453) return;
        payer = vm.addr(KEY);
        registry = new Reg(admin, Reg.Rate(100, 75, 50_000), Reg.Rate(150, 125, 50_000), Reg.Rate(10, 10, 50_000));
        splitter = new P2FluxSplitterV2(address(USDC), feeWallet, address(registry));
        sponsored = new Sponsored(address(USDC), feeWallet, gasTreasury, relayer, address(registry), 0.25e6);
        recurring = new Recurring(admin, relayer, feeWallet, gasTreasury, address(USDC), address(registry), 0.05e6);
        sender = new P2FluxSend(address(USDC), feeWallet, gasTreasury, relayer, address(registry));
        // Local fork only: become a minter and mint test USDC to the test payer.
        vm.prank(USDC.masterMinter());
        USDC.configureMinter(address(this), 1_000_000e6);
        USDC.mint(payer, 10_000e6);
    }

    function _signReceive(address to, uint256 value, uint256 validBefore, bytes32 nonce)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 h = keccak256(abi.encode(RECEIVE_TYPEHASH, payer, to, value, uint256(0), validBefore, nonce));
        return vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), h)));
    }

    function _sp(uint256 amount, bytes32 ref, uint256 nf) internal view returns (Sponsored.SponsoredPayment memory) {
        return Sponsored.SponsoredPayment(payer, merchant, amount, ref, nf, block.timestamp + 600);
    }

    function _paySponsored(Sponsored.SponsoredPayment memory p) internal {
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(address(sponsored), p.amount + p.networkFee, p.validBefore, sponsored.authorizationNonce(p));
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
    }

    function test_fork_tokenShape() public onlyFork {
        assertEq(USDC.decimals(), 6);
        emit log_named_string("USDC version", USDC.version());
    }

    function test_fork_sponsoredEndToEnd() public onlyFork {
        uint256 b0 = USDC.balanceOf(payer);
        _paySponsored(_sp(10e6, bytes32("f1"), 0.02e6));
        assertEq(b0 - USDC.balanceOf(payer), 10.02e6);
        assertEq(USDC.balanceOf(merchant), 9.85e6);
        assertEq(USDC.balanceOf(feeWallet), 0.1e6);
        assertEq(USDC.balanceOf(gasTreasury), 0.07e6);
        assertEq(USDC.balanceOf(address(sponsored)), 0);
    }

    /// Real FiatToken: receiveWithAuthorization refuses any caller but the payee.
    function test_fork_strangerCannotRedeemAuthorization() public onlyFork {
        Sponsored.SponsoredPayment memory p = _sp(10e6, bytes32("f2"), 0);
        bytes32 n = sponsored.authorizationNonce(p);
        (uint8 v, bytes32 r, bytes32 s) = _signReceive(address(sponsored), 10e6, p.validBefore, n);
        vm.prank(attacker);
        vm.expectRevert();
        USDC.receiveWithAuthorization(payer, address(sponsored), 10e6, 0, p.validBefore, n, v, r, s);
        // And another P2Flux contract cannot spend it either.
        P2FluxSend.RelayedSend memory rs = P2FluxSend.RelayedSend(payer, merchant, 10e6, p.ref, p.validBefore);
        vm.prank(relayer);
        vm.expectRevert();
        sender.sendWithAuthorization(rs, v, r, s);
        assertFalse(USDC.authorizationState(payer, n));
    }

    function test_fork_relayedSendAndRateChange() public onlyFork {
        P2FluxSend.RelayedSend memory s =
            P2FluxSend.RelayedSend(payer, merchant, 100e6, bytes32("f3"), block.timestamp + 3 days);
        (uint256 fee, uint256 fixedFee) = sender.quote(s.amount);
        uint256 total = s.amount + fee + fixedFee;
        (uint8 v, bytes32 r, bytes32 sig) =
            _signReceive(address(sender), total, s.validBefore, sender.authorizationNonce(s));

        vm.prank(admin);
        registry.scheduleRate(Reg.Kind.Send, Reg.Rate(20, 20, 50_000));
        vm.warp(block.timestamp + 48 hours); // effective at the ETA, no call

        vm.prank(relayer);
        vm.expectRevert(); // real FiatToken signature check rejects the old total
        sender.sendWithAuthorization(s, v, r, sig);
        assertEq(USDC.balanceOf(merchant), 0);
    }

    function test_fork_recurringEndToEnd() public onlyFork {
        vm.prank(payer);
        USDC.approve(address(recurring), type(uint256).max);
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            payer, merchant, address(USDC), 10e6, 30 days, uint48(block.timestamp), 0, bytes32(0), 0.05e6
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, recurring.subscriptionId(a));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(relayer);
        recurring.charge(a, sig, 0.01e6);
        assertEq(USDC.balanceOf(merchant), 9.8e6);
        assertEq(USDC.balanceOf(gasTreasury), 0.06e6);
        vm.prank(relayer);
        vm.expectRevert(Recurring.AlreadyChargedThisPeriod.selector);
        recurring.charge(a, sig, 0);
    }

    /// Permit front-run on the real token: swallowed, payment still settles.
    function test_fork_permitFrontRun() public onlyFork {
        uint256 deadline = block.timestamp + 600;
        bytes32 h = keccak256(abi.encode(PERMIT_TYPEHASH, payer, address(splitter), 50e6, USDC.nonces(payer), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(), h)));
        vm.prank(attacker);
        USDC.permit(payer, address(splitter), 50e6, deadline, v, r, s);
        vm.prank(payer);
        splitter.payWithPermit(address(USDC), merchant, 50e6, bytes32("f5"), deadline, v, r, s);
        assertEq(USDC.balanceOf(merchant), 49.5e6);
    }

    /// Blacklisted merchant: payment reverts, the buyer's authorization is NOT consumed and stays
    /// redeemable by the relayer until validBefore (e.g. right after an unblacklist).
    function test_fork_blacklistedRecipientAuthStaysLive() public onlyFork {
        address bl = USDC.blacklister();
        vm.prank(bl);
        USDC.blacklist(merchant);
        Sponsored.SponsoredPayment memory p = _sp(10e6, bytes32("f6"), 0);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(address(sponsored), 10e6, p.validBefore, sponsored.authorizationNonce(p));
        vm.prank(relayer);
        vm.expectRevert();
        sponsored.payWithAuthorization(p, v, r, s);
        assertFalse(USDC.authorizationState(payer, sponsored.authorizationNonce(p)), "not consumed");

        vm.prank(bl);
        USDC.unBlacklist(merchant);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
        assertEq(USDC.balanceOf(merchant), 9.85e6);
    }

    /// R-10: a blacklisted gas treasury (immutable) stops every sponsored payment and relayed send.
    function test_fork_R10_blacklistedTreasuryBricksRelayedPaths() public onlyFork {
        vm.prank(USDC.blacklister());
        USDC.blacklist(gasTreasury);
        Sponsored.SponsoredPayment memory p = _sp(10e6, bytes32("f7"), 0);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(address(sponsored), 10e6, p.validBefore, sponsored.authorizationNonce(p));
        vm.prank(relayer);
        vm.expectRevert();
        sponsored.payWithAuthorization(p, v, r, s);

        // Direct paths that never touch the treasury keep working.
        vm.startPrank(payer);
        USDC.approve(address(splitter), 10e6);
        splitter.pay(address(USDC), merchant, 10e6, bytes32("f7b"));
        vm.stopPrank();
        assertEq(USDC.balanceOf(merchant), 9.9e6);
    }
}
