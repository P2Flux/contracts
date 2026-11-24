// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ReviewBase} from "./ReviewBase.sol";
import {MockFiatToken} from "../../../../contracts/test/MockTokens.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice Adversarial handler: the admin schedules / cancels at random (including out-of-cap
///         values), strangers try to execute at random times, time jumps up to 12 days, and real
///         payments run in between. An INDEPENDENT ghost model of the timelock predicts, for every
///         execute attempt, whether it must succeed; any disagreement is counted.
contract ReviewHandler is Test {
    MockFiatToken token;
    Reg registry;
    Sponsored sponsored;
    Recurring recurring;
    P2FluxSend sender;
    address admin;
    address relayer;
    uint256 constant KEY = 0xA11CE;
    address payer;
    address merchant;

    // ghost timelock model
    struct G {
        uint16 bps;
        uint16 pbps;
        uint64 fixedFee;
    }

    mapping(uint256 => G) public live;
    mapping(uint256 => G) pending;
    mapping(uint256 => uint256) pendingEta;
    bool public ghostPartner;
    bool pendingP;
    uint256 pendingPEta;

    uint256 public mismatches;
    uint256 public capBreaches; // a payment that took more than 2% + 0.20 from a merchant
    uint256 public debitBreaches; // a payer debited anything but the signed / agreed amount
    uint256 public executes;
    uint256 public payments;
    uint256 nonce;

    constructor(
        MockFiatToken _t,
        Reg _r,
        Sponsored _s,
        Recurring _rec,
        P2FluxSend _send,
        address _admin,
        address _relayer,
        address _merchant
    ) {
        token = _t;
        registry = _r;
        sponsored = _s;
        recurring = _rec;
        sender = _send;
        admin = _admin;
        relayer = _relayer;
        merchant = _merchant;
        payer = vm.addr(KEY);
        live[0] = G(100, 75, 50_000);
        live[1] = G(150, 125, 50_000);
        live[2] = G(10, 10, 50_000);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
    }

    function schedule(uint256 kind, uint16 bps, uint16 pbps, uint64 fixedFee) external {
        kind %= 3;
        bps = uint16(bound(bps, 0, 260)); // sometimes above the 200 cap
        pbps = uint16(bound(pbps, 0, 260));
        fixedFee = uint64(bound(fixedFee, 0, 0.25e6));
        bool legal = bps <= 200 && pbps <= bps && fixedFee <= 0.2e6;
        vm.prank(admin);
        try registry.scheduleRate(Reg.Kind(kind), Reg.Rate(bps, pbps, fixedFee)) {
            if (!legal) mismatches++;
            pending[kind] = G(bps, pbps, fixedFee);
            pendingEta[kind] = block.timestamp + 48 hours;
        } catch {
            if (legal) mismatches++;
        }
    }

    function cancel(uint256 kind) external {
        kind %= 3;
        vm.prank(admin);
        try registry.cancelRate(Reg.Kind(kind)) {
            if (pendingEta[kind] == 0) mismatches++;
            delete pendingEta[kind];
        } catch {
            if (pendingEta[kind] != 0) mismatches++;
        }
    }

    function execute(uint256 kind, address who) external {
        kind %= 3;
        uint256 eta = pendingEta[kind];
        bool should = eta != 0 && block.timestamp >= eta && block.timestamp <= eta + 7 days;
        vm.prank(who);
        try registry.executeRate(Reg.Kind(kind)) {
            if (!should) mismatches++;
            live[kind] = pending[kind];
            delete pendingEta[kind];
            executes++;
        } catch {
            if (should) mismatches++;
        }
    }

    function schedulePartner(bool value) external {
        address[] memory l = new address[](1);
        l[0] = merchant;
        vm.prank(admin);
        registry.schedulePartners(l, value);
        pendingP = value;
        pendingPEta = block.timestamp + 48 hours;
    }

    function executePartner(address who) external {
        address[] memory l = new address[](1);
        l[0] = merchant;
        bool should = pendingPEta != 0 && block.timestamp >= pendingPEta && block.timestamp <= pendingPEta + 7 days;
        vm.prank(who);
        try registry.executePartners(l) {
            if (!should) mismatches++;
            ghostPartner = pendingP;
            pendingPEta = 0;
        } catch {
            if (should) mismatches++;
        }
    }

    function warp(uint256 dt) external {
        // Mostly short hops (lands inside the 48 h .. 9 d window often), sometimes past the grace.
        vm.warp(block.timestamp + (dt % 8 == 0 ? bound(dt, 0, 12 days) : bound(dt, 0, 2 days)));
    }

    function paySponsored(uint256 amount, uint256 nf) external {
        amount = bound(amount, 0.3e6, 1e12);
        nf = bound(nf, 0, 0.25e6);
        Sponsored.SponsoredPayment memory p =
            Sponsored.SponsoredPayment(payer, merchant, amount, bytes32(nonce++), nf, block.timestamp + 60);
        (uint8 v, bytes32 r, bytes32 s) =
            _sign(address(sponsored), amount + nf, p.validBefore, sponsored.authorizationNonce(p));
        token.mint(payer, amount + nf);
        uint256 before = token.balanceOf(merchant);
        vm.prank(relayer);
        sponsored.payWithAuthorization(p, v, r, s);
        payments++;
        if (token.balanceOf(payer) != 0) debitBreaches++;
        if (token.balanceOf(merchant) - before < amount - amount * 200 / 10_000 - 0.2e6) capBreaches++;
    }

    function sendRelayed(uint256 amount) external {
        amount = bound(amount, 1e6, 1e12);
        (uint256 fee, uint256 fixedFee) = sender.quote(amount);
        uint256 total = amount + fee + fixedFee;
        if (fee > amount * 200 / 10_000 || fixedFee > 0.2e6) capBreaches++;
        P2FluxSend.RelayedSend memory s =
            P2FluxSend.RelayedSend(payer, merchant, amount, bytes32(nonce++), 0, block.timestamp + 60);
        (uint8 v, bytes32 r, bytes32 sig) = _sign(address(sender), total, s.validBefore, sender.authorizationNonce(s));
        token.mint(payer, total);
        uint256 before = token.balanceOf(merchant);
        vm.prank(relayer);
        sender.sendWithAuthorization(s, v, r, sig);
        payments++;
        if (token.balanceOf(merchant) - before != amount || token.balanceOf(payer) != 0) debitBreaches++;
    }

    function chargeRecurring(uint256 salt) external {
        Recurring.RecurringAuthorization memory a = Recurring.RecurringAuthorization(
            payer, merchant, address(token), 25e6, 30 days, uint48(1_700_000_000), 0, bytes32(salt % 4), 0.05e6
        );
        if (!recurring.isChargeable(a)) return;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, recurring.subscriptionId(a));
        token.mint(payer, 25e6 + 0.05e6);
        uint256 before = token.balanceOf(merchant);
        vm.prank(relayer);
        recurring.charge(a, abi.encodePacked(r, s, v), 0.05e6);
        payments++;
        if (token.balanceOf(payer) != 0) debitBreaches++;
        if (token.balanceOf(merchant) - before < 25e6 - 25e6 * 200 / 10_000 - 0.2e6) capBreaches++;
    }

    function _sign(address to, uint256 value, uint256 validBefore, bytes32 n)
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

contract ReviewInvariantTest is ReviewBase {
    ReviewHandler internal h;

    function setUp() public {
        _reviewSetUp();
        h = new ReviewHandler(token, registry, sponsored, recurring, sender, admin, relayer, merchant);
        targetContract(address(h));
    }

    /// Registry state always equals the independent ghost model of the timelock.
    function invariant_R_registryMatchesTimelockModel() public view {
        assertEq(h.mismatches(), 0, "a schedule/cancel/execute outcome disagreed with the model");
        for (uint256 k; k < 3; k++) {
            (uint16 b, uint16 pb, uint64 f) = registry.rates(Reg.Kind(k));
            (uint16 gb, uint16 gpb, uint64 gf) = h.live(k);
            assertEq(b, gb);
            assertEq(pb, gpb);
            assertEq(f, gf);
            assertLe(b, 200);
            assertLe(pb, b);
            assertLe(f, 0.2e6);
        }
        assertEq(registry.isPartner(merchant), h.ghostPartner());
    }

    /// Payers are never debited more than agreed and merchants never lose more than the caps.
    function invariant_R_payerAndMerchantBounds() public view {
        assertEq(h.debitBreaches(), 0);
        assertEq(h.capBreaches(), 0);
    }

    /// Coverage evidence: successful rate executions and payments in each run.
    function afterInvariant() public view {
        console2.log("executes", h.executes(), "payments", h.payments());
    }

    function invariant_R_noCustody() public view {
        assertEq(token.balanceOf(address(sponsored)), 0);
        assertEq(token.balanceOf(address(sender)), 0);
        assertEq(token.balanceOf(address(recurring)), 0);
    }
}
