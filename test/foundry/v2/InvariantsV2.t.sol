// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {V2Test} from "./V2Helpers.sol";
import {MockFiatToken} from "../../../contracts/test/MockTokens.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2} from "../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxPaymentsV2 as Sponsored} from "../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../contracts/v2/P2FluxSend.sol";

/// @notice Drives all four v2 contracts and the registry through random sequences, keeping its own
///         ledger from the published fee formula. Rates change mid-run (within caps, via timelock).
contract V2Handler is Test {
    MockFiatToken token;
    P2FluxFeeRegistry registry;
    // Both names point at the ONE payments contract: `splitter` = self-pay entrance, `sponsored` =
    // sponsored entrance.
    P2FluxPaymentsV2 splitter;
    Sponsored sponsored;
    Recurring recurring;
    P2FluxSend sender;
    address admin;
    address relayer;
    uint256 constant KEY = 0xA11CE;
    address payer;
    address[2] recipients;

    uint256 public sumIn; // everything debited from the payer
    uint256 public sumRecipients;
    uint256 public sumFee;
    uint256 public sumTreasury;
    uint256 nonce;
    mapping(uint256 => uint256) lastChargedPeriod; // recipient index => period + 1

    constructor(
        MockFiatToken _token,
        P2FluxFeeRegistry _registry,
        P2FluxPaymentsV2 _splitter,
        Sponsored _sponsored,
        Recurring _recurring,
        P2FluxSend _sender,
        address _admin,
        address _relayer,
        address merchant,
        address partner
    ) {
        token = _token;
        registry = _registry;
        splitter = _splitter;
        sponsored = _sponsored;
        recurring = _recurring;
        sender = _sender;
        admin = _admin;
        relayer = _relayer;
        payer = vm.addr(KEY);
        recipients = [merchant, partner];
        vm.startPrank(payer);
        token.approve(address(splitter), type(uint256).max);
        token.approve(address(recurring), type(uint256).max);
        token.approve(address(sender), type(uint256).max);
        vm.stopPrank();
    }

    function _bps(P2FluxFeeRegistry.Kind kind, address r) internal view returns (uint256 bps, uint256 fixedFee) {
        (uint16 b, uint16 pb, uint64 f) = registry.rates(kind);
        return (registry.isPartner(r) ? pb : b, f);
    }

    function _book(uint256 debit, uint256 toRecipient, uint256 fee, uint256 treasury) internal {
        sumIn += debit;
        sumRecipients += toRecipient;
        sumFee += fee;
        sumTreasury += treasury;
    }

    function payOneTime(uint256 amount, uint256 who) external {
        amount = bound(amount, 1, 1e12);
        address r = recipients[who % 2];
        (uint256 bps,) = _bps(P2FluxFeeRegistry.Kind.OneTime, r);
        uint256 fee = amount * bps / 10_000;
        token.mint(payer, amount);
        vm.prank(payer);
        splitter.pay(address(token), r, amount, bytes32(nonce++));
        _book(amount, amount - fee, fee, 0);
    }

    function paySponsored(uint256 amount, uint256 networkFee, uint256 who) external {
        address r = recipients[who % 2];
        amount = bound(amount, sponsored.minimumAmount(r), 1e12);
        networkFee = bound(networkFee, 0, sponsored.MAX_NETWORK_FEE_HARD_CAP());
        (uint256 bps, uint256 fixedFee) = _bps(P2FluxFeeRegistry.Kind.OneTime, r);
        uint256 fee = amount * bps / 10_000;
        Sponsored.SponsoredPayment memory p =
            Sponsored.SponsoredPayment(payer, r, amount, bytes32(nonce++), networkFee, block.timestamp + 60);
        (uint8 v, bytes32 rr, bytes32 s) =
            _signReceive(address(sponsored), amount + networkFee, p.validBefore, sponsored.authorizationNonce(p));
        token.mint(payer, amount + networkFee);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, rr, s);
        _book(amount + networkFee, amount - fee - fixedFee, fee, fixedFee + networkFee);
    }

    // --- shared orders: a small pool of identical orders, hit through either entrance ---------------
    uint256 constant ORDERS = 5;
    uint256 constant ORDER_AMOUNT = 10e6;
    mapping(uint256 => uint256) public settledCount; // order index => successful settlements
    uint256 public crossAttempts;

    /// Try to settle order `i` (same recipient, amount and ref every time) via self-pay or sponsored.
    function settleSharedOrder(uint256 i, bool viaSponsored, uint256 networkFee) external {
        i %= ORDERS;
        bytes32 ref = keccak256(abi.encode("order", i));
        address r = recipients[0];
        (uint256 bps, uint256 fixedFee) = _bps(P2FluxFeeRegistry.Kind.OneTime, r);
        uint256 fee = ORDER_AMOUNT * bps / 10_000;
        crossAttempts++;
        if (viaSponsored) {
            networkFee = bound(networkFee, 0, sponsored.MAX_NETWORK_FEE_HARD_CAP());
            Sponsored.SponsoredPayment memory p =
                Sponsored.SponsoredPayment(payer, r, ORDER_AMOUNT, ref, networkFee, block.timestamp + 60);
            (uint8 v, bytes32 rr, bytes32 s) = _signReceive(
                address(sponsored), ORDER_AMOUNT + networkFee, p.validBefore, sponsored.authorizationNonce(p)
            );
            token.mint(payer, ORDER_AMOUNT + networkFee);
            vm.prank(relayer);
            try sponsored.payWithAuthorization(p, v, rr, s) {
                settledCount[i]++;
                _book(ORDER_AMOUNT + networkFee, ORDER_AMOUNT - fee - fixedFee, fee, fixedFee + networkFee);
            } catch {
                _burnUnspent(ORDER_AMOUNT + networkFee);
            }
        } else {
            token.mint(payer, ORDER_AMOUNT);
            vm.prank(payer);
            try splitter.pay(address(token), r, ORDER_AMOUNT, ref) {
                settledCount[i]++;
                _book(ORDER_AMOUNT, ORDER_AMOUNT - fee, fee, 0);
            } catch {
                _burnUnspent(ORDER_AMOUNT);
            }
        }
    }

    /// @dev A refused attempt moved nothing; drop the minted test funds so `payer` ends at zero.
    function _burnUnspent(uint256 value) internal {
        vm.prank(payer);
        token.transfer(address(0xdead), value);
    }

    function maxSettled() external view returns (uint256 m) {
        for (uint256 i; i < ORDERS; i++) {
            if (settledCount[i] > m) m = settledCount[i];
        }
    }

    function processedMatches() external view returns (bool) {
        for (uint256 i; i < ORDERS; i++) {
            bytes32 ref = keccak256(abi.encode("order", i));
            if (splitter.isPaymentProcessed(address(token), recipients[0], ORDER_AMOUNT, ref) != (settledCount[i] == 1))
            {
                return false;
            }
        }
        return true;
    }

    function sendDirect(uint256 amount, uint256 who) external {
        amount = bound(amount, 1e6, 1e12);
        (uint256 bps,) = _bps(P2FluxFeeRegistry.Kind.Send, address(0));
        uint256 fee = amount * bps / 10_000;
        token.mint(payer, amount + fee);
        vm.prank(payer);
        sender.send(recipients[who % 2], amount, fee, bytes32(nonce++));
        _book(amount + fee, amount, fee, 0);
    }

    function sendRelayed(uint256 amount, uint256 who) external {
        amount = bound(amount, 1e6, 1e12);
        (uint256 bps, uint256 fixedFee) = _bps(P2FluxFeeRegistry.Kind.Send, address(0));
        uint256 fee = amount * bps / 10_000;
        uint256 total = amount + fee + fixedFee;
        P2FluxSend.RelayedSend memory s =
            P2FluxSend.RelayedSend(payer, recipients[who % 2], amount, bytes32(nonce++), block.timestamp + 60);
        (uint8 v, bytes32 r, bytes32 sig) =
            _signReceive(address(sender), total, s.validBefore, sender.authorizationNonce(s));
        token.mint(payer, total);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        _book(total, amount, fee, fixedFee);
    }

    function chargeRecurring(uint256 who, uint256 reimbursement, uint256 jump) external {
        vm.warp(block.timestamp + bound(jump, 0, 40 days));
        uint256 i = who % 2;
        address r = recipients[i];
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            payer, r, address(token), 25e6, 30 days, uint48(1_700_000_000), 0, bytes32(i), 0.05e6
        );
        uint256 period = (block.timestamp - a.start) / a.period;
        if (lastChargedPeriod[i] == period + 1) return;
        reimbursement = bound(reimbursement, 0, 0.05e6);
        (uint256 bps, uint256 fixedFee) = _bps(P2FluxFeeRegistry.Kind.Recurring, r);
        uint256 fee = a.amount * bps / 10_000;
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(KEY, recurring.subscriptionId(a));
        token.mint(payer, a.amount + reimbursement);
        vm.prank(relayer);
        recurring.charge(a, abi.encodePacked(rr, s, v), reimbursement);
        lastChargedPeriod[i] = period + 1;
        _book(a.amount + reimbursement, a.amount - fee - fixedFee, fee, fixedFee + reimbursement);
    }

    function changeRate(uint256 kind, uint16 bps, uint16 pbps, uint64 fixedFee) external {
        P2FluxFeeRegistry.Kind k = P2FluxFeeRegistry.Kind(kind % 3);
        bps = uint16(bound(bps, 0, 200));
        pbps = uint16(bound(pbps, 0, bps));
        fixedFee = uint64(bound(fixedFee, 0, 200_000));
        vm.prank(admin);
        registry.scheduleRate(k, P2FluxFeeRegistry.Rate(bps, pbps, fixedFee));
        vm.warp(block.timestamp + 48 hours); // effective by itself at the ETA
    }

    function _signReceive(address to, uint256 value, uint256 validBefore, bytes32 n)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), payer, to, value, uint256(0), validBefore, n)
        );
        return vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));
    }
}

contract V2InvariantTest is V2Test {
    V2Handler internal handler;
    P2FluxPaymentsV2 internal payments;
    Recurring internal recurring;
    P2FluxSend internal sender;
    address internal merchant = address(0xAE2C4A47);

    function setUp() public {
        _v2SetUp();
        payments = new P2FluxPaymentsV2(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        recurring = new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), 50_000);
        sender = new P2FluxSend(address(token), feeWallet, gasTreasury, relayer, address(registry));
        handler =
            new V2Handler(token, registry, payments, payments, recurring, sender, admin, relayer, merchant, partner);
        targetContract(address(handler));
    }

    /// Sum out == sum in: every unit debited from the payer landed at a recipient, the fee wallet or
    /// the gas treasury; the payer holds nothing extra (all mints were spent).
    function invariant_conservation() public view {
        assertEq(handler.sumIn(), handler.sumRecipients() + handler.sumFee() + handler.sumTreasury());
        assertEq(token.balanceOf(payer), 0);
        assertEq(token.balanceOf(merchant) + token.balanceOf(partner), handler.sumRecipients());
    }

    /// The fee wallet only ever receives the percentage fee, exactly as the formula says.
    function invariant_feeWalletOnlyFees() public view {
        assertEq(token.balanceOf(feeWallet), handler.sumFee());
        assertEq(token.balanceOf(gasTreasury), handler.sumTreasury());
    }

    /// No contract ever keeps a balance.
    function invariant_noCustody() public view {
        assertEq(token.balanceOf(address(payments)), 0);
        assertEq(token.balanceOf(address(recurring)), 0);
        assertEq(token.balanceOf(address(sender)), 0);
    }

    /// Rates never exceed the hard caps, whatever sequence ran.
    function invariant_ratesWithinCaps() public view {
        for (uint256 k; k < 3; k++) {
            (uint16 b, uint16 pb, uint64 f) = registry.rates(P2FluxFeeRegistry.Kind(k));
            assertLe(b, registry.MAX_BPS());
            assertLe(pb, b);
            assertLe(f, registry.MAX_FIXED_FEE());
        }
    }

    /// An order settles at most once across BOTH entrances, and the shared table says exactly which.
    function invariant_orderSettlesAtMostOnceAcrossEntrances() public view {
        assertLe(handler.maxSettled(), 1);
        assertTrue(handler.processedMatches());
    }
}
