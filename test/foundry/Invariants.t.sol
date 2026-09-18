// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFiatToken} from "../../contracts/test/MockTokens.sol";
import {P2FluxRecurring} from "../../contracts/P2FluxRecurring.sol";
import {P2FluxSponsoredSplitter} from "../../contracts/P2FluxSponsoredSplitter.sol";

/*
 * Stateful invariant suites. A handler drives a contract through random sequences - charges by the
 * relayer and by strangers, time jumps, revocations, replays, dust donations - while keeping its own
 * independent ledger of what SHOULD have happened. The invariants then compare the chain to the
 * ledger after every call. Nothing here knows how the contract computes anything beyond the
 * published fee schedule.
 */

contract RecurringHandler is Test {
    P2FluxRecurring public recurring;
    MockFiatToken public token;
    address public relayer;
    address public merchant = address(0xAE2C4A47);

    uint256 internal constant SUBS = 3;
    uint256[SUBS] internal keys = [uint256(0xA11CE), 0xB0B, 0xCA201];
    P2FluxRecurring.RecurringAuthorization[SUBS] internal auths;
    bytes[SUBS] internal sigs;

    // The independent ledger.
    uint256 public sumNet;
    uint256 public sumFee;
    uint256 public sumTreasury;
    uint256 public sumPayerOut;
    uint256 public totalMinted;
    uint256 public charges;
    bool public doubleCharged;
    bool public chargedAfterRevoke;
    bool public strangerReimbursed;
    mapping(bytes32 => mapping(uint256 => bool)) internal chargedPeriod;
    mapping(bytes32 => bool) internal revokedLocally;

    constructor(P2FluxRecurring _recurring, MockFiatToken _token, address _relayer) {
        recurring = _recurring;
        token = _token;
        relayer = _relayer;
        uint48[SUBS] memory periods = [uint48(1 hours), 7 days, 30 days];
        uint256[SUBS] memory amounts = [uint256(102_041), 9_990_000, 250_000_000];
        for (uint256 i; i < SUBS; i++) {
            address payer = vm.addr(keys[i]);
            auths[i] = P2FluxRecurring.RecurringAuthorization({
                payer: payer,
                recipient: merchant,
                token: address(token),
                amount: amounts[i],
                period: periods[i],
                start: uint48(block.timestamp),
                end: i == 2 ? uint48(block.timestamp + 200 days) : 0,
                salt: bytes32(i + 1),
                maxGasReimbursement: 20_000 * i // 0, 0.02, 0.04 USDC
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], recurring.subscriptionId(auths[i]));
            sigs[i] = abi.encodePacked(r, s, v);
            token.mint(payer, 1e13);
            totalMinted += 1e13;
            vm.prank(payer);
            token.approve(address(recurring), type(uint256).max);
        }
    }

    function payerOf(uint256 i) external view returns (address) {
        return auths[i].payer;
    }

    function charge(uint256 subSeed, bool asRelayer, uint256 reimbursementSeed, address stranger) external {
        uint256 i = subSeed % SUBS;
        P2FluxRecurring.RecurringAuthorization memory a = auths[i];
        uint256 reimbursement = bound(reimbursementSeed, 0, 60_000); // deliberately beyond every cap
        address caller = asRelayer ? relayer : stranger;
        if (!asRelayer && caller == relayer) return;

        bytes32 id = recurring.subscriptionId(a);
        uint256 payerBefore = token.balanceOf(a.payer);
        vm.prank(caller);
        try recurring.charge(a, sigs[i], reimbursement) {
            uint256 period = recurring.lastChargedPeriodPlusOne(id) - 1;
            if (chargedPeriod[id][period]) doubleCharged = true;
            chargedPeriod[id][period] = true;
            if (revokedLocally[id]) chargedAfterRevoke = true;

            uint256 paidOut = payerBefore - token.balanceOf(a.payer);
            if (!asRelayer && paidOut != a.amount) strangerReimbursed = true;
            uint256 fee = (a.amount * 200) / 10_000;
            sumFee += fee;
            sumNet += a.amount - fee - 100_000;
            sumTreasury += paidOut - a.amount + 100_000;
            sumPayerOut += paidOut;
            charges++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 45 days));
    }

    function revoke(uint256 subSeed) external {
        uint256 i = subSeed % SUBS;
        vm.prank(auths[i].payer);
        try recurring.revoke(auths[i]) {
            revokedLocally[recurring.subscriptionId(auths[i])] = true;
        } catch {}
    }
}

contract RecurringInvariantTest is Test {
    MockFiatToken internal token;
    P2FluxRecurring internal recurring;
    RecurringHandler internal handler;
    address internal feeWallet = makeAddr("feeWallet");
    address internal gasTreasury = makeAddr("gasTreasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockFiatToken();
        recurring = new P2FluxRecurring(makeAddr("admin"), makeAddr("relayer"), feeWallet, gasTreasury, address(token));
        handler = new RecurringHandler(recurring, token, makeAddr("relayer"));
        targetContract(address(handler));
    }

    /// Invariants over a handler that never succeeds would prove nothing: it must really charge.
    function test_handlerIsAlive() public {
        handler.charge(1, true, 10_000, address(0xBAD));
        handler.charge(1, false, 10_000, address(0xBAD)); // same period: refused
        handler.warp(8 days);
        handler.charge(1, false, 10_000, address(0xBAD));
        assertEq(handler.charges(), 2);
        assertGt(token.balanceOf(handler.merchant()), 0);
    }

    function invariant_contractNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(recurring)), 0);
    }

    function invariant_everyUnitIsAccountedFor() public view {
        assertEq(token.balanceOf(handler.merchant()), handler.sumNet(), "merchant");
        assertEq(token.balanceOf(feeWallet), handler.sumFee(), "fee wallet");
        assertEq(token.balanceOf(gasTreasury), handler.sumTreasury(), "gas treasury");
        assertEq(handler.sumNet() + handler.sumFee() + handler.sumTreasury(), handler.sumPayerOut(), "in == out");
    }

    function invariant_supplyIsConserved() public view {
        uint256 held = token.balanceOf(handler.merchant()) + token.balanceOf(feeWallet) + token.balanceOf(gasTreasury);
        for (uint256 i; i < 3; i++) {
            held += token.balanceOf(handler.payerOf(i));
        }
        assertEq(held, handler.totalMinted());
    }

    function invariant_noPeriodIsChargedTwice() public view {
        assertFalse(handler.doubleCharged());
    }

    function invariant_revokedIsNeverCharged() public view {
        assertFalse(handler.chargedAfterRevoke());
    }

    function invariant_onlyTheRelayerIsReimbursed() public view {
        assertFalse(handler.strangerReimbursed());
    }

    function invariant_gasSideIsBounded() public view {
        // fixed fee + at most the hard cap, per charge
        assertLe(handler.sumTreasury(), handler.charges() * (100_000 + 50_000));
    }
}

contract SponsoredHandler is Test {
    P2FluxSponsoredSplitter public splitter;
    MockFiatToken public token;
    address public relayer;
    address public merchant = address(0xAE2C4A47);
    uint256 internal constant KEY = 0xA11CE;
    address public payer;

    uint256 public donated;
    uint256 public sumNet;
    uint256 public sumFee;
    uint256 public sumTreasury;
    uint256 public sumPayerOut;
    uint256 public totalMinted;
    bool public replaySucceeded;

    P2FluxSponsoredSplitter.SponsoredPayment internal last;
    uint8 internal lv;
    bytes32 internal lr;
    bytes32 internal ls;
    bool internal hasLast;

    constructor(P2FluxSponsoredSplitter _splitter, MockFiatToken _token, address _relayer) {
        splitter = _splitter;
        token = _token;
        relayer = _relayer;
        payer = vm.addr(KEY);
    }

    function pay(uint256 amountSeed, uint256 feeSeed, bytes32 ref) external {
        P2FluxSponsoredSplitter.SponsoredPayment memory p = P2FluxSponsoredSplitter.SponsoredPayment({
            payer: payer,
            recipient: merchant,
            amount: bound(amountSeed, 1, 1e12), // includes amounts below the minimum
            ref: ref,
            networkFee: bound(feeSeed, 0, 300_000), // includes quotes above the cap
            validBefore: block.timestamp + 600
        });
        token.mint(payer, p.amount + p.networkFee);
        totalMinted += p.amount + p.networkFee;

        bytes32 structHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                p.payer,
                address(splitter),
                p.amount + p.networkFee,
                uint256(0),
                p.validBefore,
                splitter.authorizationNonce(p)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(KEY, keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)));

        uint256 before = token.balanceOf(payer);
        vm.prank(relayer);
        try splitter.payWithAuthorization(p, v, r, s) {
            uint256 fee = (p.amount * 100) / 10_000;
            sumFee += fee;
            sumNet += p.amount - fee - 100_000;
            sumTreasury += p.networkFee + 100_000;
            sumPayerOut += before - token.balanceOf(payer);
            last = p;
            (lv, lr, ls, hasLast) = (v, r, s, true);
        } catch {}
    }

    function replayLast() external {
        if (!hasLast) return;
        token.mint(payer, last.amount + last.networkFee);
        totalMinted += last.amount + last.networkFee;
        vm.prank(relayer);
        try splitter.payWithAuthorization(last, lv, lr, ls) {
            replaySucceeded = true;
        } catch {}
    }

    function donate(uint256 dust) external {
        dust = bound(dust, 1, 1e9);
        token.mint(address(splitter), dust);
        donated += dust;
        totalMinted += dust;
    }
}

contract SponsoredInvariantTest is Test {
    MockFiatToken internal token;
    P2FluxSponsoredSplitter internal splitter;
    SponsoredHandler internal handler;
    address internal feeWallet = makeAddr("feeWallet");
    address internal gasTreasury = makeAddr("gasTreasury");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockFiatToken();
        splitter =
            new P2FluxSponsoredSplitter(address(token), feeWallet, gasTreasury, makeAddr("relayer"), 100_000, 250_000);
        handler = new SponsoredHandler(splitter, token, makeAddr("relayer"));
        targetContract(address(handler));
    }

    function test_handlerIsAlive() public {
        handler.pay(5e6, 4_000, "order-1");
        handler.replayLast();
        handler.pay(50, 0, "too-small");
        assertEq(token.balanceOf(handler.merchant()), 5e6 - 5e4 - 100_000);
        assertFalse(handler.replaySucceeded());
    }

    /// The contract ends every call holding exactly what strangers donated - never a unit of a payment.
    function invariant_holdsOnlyDonations() public view {
        assertEq(token.balanceOf(address(splitter)), handler.donated());
    }

    function invariant_everyUnitIsAccountedFor() public view {
        assertEq(token.balanceOf(handler.merchant()), handler.sumNet(), "merchant");
        assertEq(token.balanceOf(feeWallet), handler.sumFee(), "fee wallet");
        assertEq(token.balanceOf(gasTreasury), handler.sumTreasury(), "gas treasury");
        assertEq(handler.sumNet() + handler.sumFee() + handler.sumTreasury(), handler.sumPayerOut(), "in == out");
    }

    function invariant_supplyIsConserved() public view {
        assertEq(
            token.balanceOf(handler.payer()) + token.balanceOf(handler.merchant()) + token.balanceOf(feeWallet)
                + token.balanceOf(gasTreasury) + token.balanceOf(address(splitter)),
            handler.totalMinted()
        );
    }

    function invariant_noReplayEverSettles() public view {
        assertFalse(handler.replaySucceeded());
    }
}
