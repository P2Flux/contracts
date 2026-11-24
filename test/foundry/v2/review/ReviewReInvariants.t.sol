// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReviewBase} from "./ReviewBase.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2 as Sponsored} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice Re-review ghost for the auto-effective timelock. The model is an EVENT LOG, not a slot:
///         the effective value is the last schedule whose 48 h passed with no later schedule or
///         cancel inside its window. It shares no code or structure with the registry's
///         current / next / eta slot, so a slot bug cannot hide in the model.
contract EventLogHandler is Test {
    Reg registry;
    Sponsored sponsored;
    P2FluxSend sender;
    address admin;
    address merchant;

    struct Ev {
        uint256 t;
        bool cancel;
        uint16 b;
        uint16 pb;
        uint64 f;
    }

    struct PEv {
        uint256 t;
        bool cancel;
        bool v;
    }

    mapping(uint256 => Ev[]) evs;
    PEv[] pevs;
    uint16[3] initB = [100, 150, 10];
    uint16[3] initPb = [75, 125, 10];
    uint64[3] initF = [50_000, 50_000, 50_000];

    uint256 public mismatches;
    uint256 public edgeHits;

    constructor(Reg r, Sponsored s, P2FluxSend snd, address a, address m) {
        registry = r;
        sponsored = s;
        sender = snd;
        admin = a;
        merchant = m;
    }

    // --- model -----------------------------------------------------------------------------------

    function modelRate(uint256 k) public view returns (uint16 b, uint16 pb, uint64 f) {
        (b, pb, f) = (initB[k], initPb[k], initF[k]);
        Ev[] storage e = evs[k];
        uint256 bestAt;
        for (uint256 i; i < e.length; i++) {
            if (e[i].cancel || e[i].t + 48 hours > block.timestamp) continue;
            bool superseded;
            for (uint256 j = i + 1; j < e.length; j++) {
                if (e[j].t < e[i].t + 48 hours) superseded = true;
            }
            if (!superseded && e[i].t + 48 hours >= bestAt) {
                bestAt = e[i].t + 48 hours;
                (b, pb, f) = (e[i].b, e[i].pb, e[i].f);
            }
        }
    }

    function modelPartner() public view returns (bool v) {
        uint256 bestAt;
        for (uint256 i; i < pevs.length; i++) {
            if (pevs[i].cancel || pevs[i].t + 48 hours > block.timestamp) continue;
            bool superseded;
            for (uint256 j = i + 1; j < pevs.length; j++) {
                if (pevs[j].t < pevs[i].t + 48 hours) superseded = true;
            }
            if (!superseded && pevs[i].t + 48 hours >= bestAt) {
                bestAt = pevs[i].t + 48 hours;
                v = pevs[i].v;
            }
        }
    }

    function _pendingExists(uint256 k) internal view returns (bool) {
        Ev[] storage e = evs[k];
        if (e.length == 0) return false;
        Ev storage last = e[e.length - 1];
        return !last.cancel && block.timestamp < last.t + 48 hours;
    }

    function _pPendingExists() internal view returns (bool) {
        if (pevs.length == 0) return false;
        PEv storage last = pevs[pevs.length - 1];
        return !last.cancel && block.timestamp < last.t + 48 hours;
    }

    // --- actions ---------------------------------------------------------------------------------

    function schedule(uint256 k, uint16 b, uint16 pb, uint64 f) external {
        k %= 3;
        b = uint16(bound(b, 0, 200));
        pb = uint16(bound(pb, 0, b));
        f = uint64(bound(f, 0, 0.2e6));
        vm.prank(admin);
        registry.scheduleRate(Reg.Kind(k), Reg.Rate(b, pb, f));
        evs[k].push(Ev(block.timestamp, false, b, pb, f));
    }

    function cancel(uint256 k) external {
        k %= 3;
        bool should = _pendingExists(k);
        vm.prank(admin);
        try registry.cancelRate(Reg.Kind(k)) {
            if (!should) mismatches++;
            evs[k].push(Ev(block.timestamp, true, 0, 0, 0));
        } catch {
            if (should) mismatches++;
        }
    }

    function schedulePartner(bool v) external {
        address[] memory l = new address[](1);
        l[0] = merchant;
        vm.prank(admin);
        registry.schedulePartners(l, v);
        pevs.push(PEv(block.timestamp, false, v));
    }

    function cancelPartner() external {
        bool should = _pPendingExists();
        vm.prank(admin);
        try registry.cancelPartner(merchant) {
            if (!should) mismatches++;
            pevs.push(PEv(block.timestamp, true, false));
        } catch {
            if (should) mismatches++;
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }

    /// Land exactly on, or one second before, the last scheduled ETA of a kind.
    function warpToEdge(uint256 k, bool before) external {
        Ev[] storage e = evs[k % 3];
        if (e.length == 0) return;
        uint256 eta = e[e.length - 1].t + 48 hours - (before ? 1 : 0);
        if (eta <= block.timestamp) return;
        vm.warp(eta);
        edgeHits++;
    }

    /// Every contract must read the same numbers as the model in the same block.
    function checkContracts() external {
        (uint16 b, uint16 pb, uint64 f) = modelRate(2);
        (uint256 fee, uint256 fx) = sender.quote(1_000e6);
        if (fee != 1_000e6 * uint256(b) / 10_000 || fx != f) mismatches++;
        (b, pb, f) = modelRate(0);
        uint256 bps = modelPartner() ? pb : b;
        if (sponsored.minimumAmount(merchant) != uint256(f) * 10_000 / (10_000 - bps) + 1) mismatches++;
    }
}

contract ReviewReInvariantTest is ReviewBase {
    EventLogHandler internal h;

    function setUp() public {
        _reviewSetUp();
        h = new EventLogHandler(registry, sponsored, sender, admin, merchant);
        targetContract(address(h));
    }

    function invariant_RR_registryMatchesEventLogModel() public view {
        assertEq(h.mismatches(), 0, "registry or a contract disagreed with the event-log model");
        for (uint256 k; k < 3; k++) {
            (uint16 b, uint16 pb, uint64 f) = registry.rates(Reg.Kind(k));
            (uint16 mb, uint16 mpb, uint64 mf) = h.modelRate(k);
            assertEq(b, mb, "bps");
            assertEq(pb, mpb, "partner bps");
            assertEq(f, mf, "fixed");
        }
        assertEq(registry.isPartner(merchant), h.modelPartner(), "partner flag");
    }
}
