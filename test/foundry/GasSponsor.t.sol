// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {P2FluxGasSponsor} from "../../contracts/P2FluxGasSponsor.sol";
import {PermitRevertingToken} from "../../contracts/test/MockTokens.sol";

/// @notice Fuzz suite for sponsored allowance changes: the fee goes to the treasury and nowhere
///         else, the permit lands exactly as signed, and nothing settles twice or half-way.
contract GasSponsorFuzzTest is P2FluxTest {
    P2FluxGasSponsor internal sponsor;
    address internal spender = makeAddr("recurringContract");

    function setUp() public {
        _baseSetUp();
        sponsor = new P2FluxGasSponsor(address(token), gasTreasury, relayer, SPONSORED_FEE_CAP);
        token.mint(payer, 1e12);
    }

    function _terms(uint256 allowanceValue, uint256 networkFee)
        internal
        view
        returns (P2FluxGasSponsor.PermitSponsorship memory sp)
    {
        sp = P2FluxGasSponsor.PermitSponsorship({
            payer: payer,
            spender: spender,
            allowanceValue: allowanceValue,
            allowanceDeadline: block.timestamp + 600,
            networkFee: networkFee,
            validBefore: block.timestamp + 600
        });
    }

    function _submit(P2FluxGasSponsor.PermitSponsorship memory sp, address caller) internal {
        (uint8 pv, bytes32 pr, bytes32 ps) =
            _signPermit(PAYER_KEY, sp.payer, sp.spender, sp.allowanceValue, sp.allowanceDeadline);
        (uint8 fv, bytes32 fr, bytes32 fs) = _signReceive(
            PAYER_KEY, sp.payer, address(sponsor), sp.networkFee, sp.validBefore, sponsor.authorizationNonce(sp)
        );
        vm.prank(caller);
        sponsor.sponsorPermit(sp, pv, pr, ps, fv, fr, fs);
    }

    function testFuzz_feeGoesOnlyToTreasury_permitLandsAsSigned(uint256 allowanceValue, uint256 networkFee) public {
        networkFee = bound(networkFee, 0, SPONSORED_FEE_CAP);
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(allowanceValue, networkFee);
        uint256 before = token.balanceOf(payer);
        _submit(sp, relayer);

        assertEq(before - token.balanceOf(payer), networkFee, "payer debited exactly the quoted fee");
        assertEq(token.balanceOf(gasTreasury), networkFee, "treasury receives exactly the fee");
        assertEq(token.balanceOf(address(sponsor)), 0, "sponsor holds nothing");
        assertEq(token.balanceOf(relayer), 0, "relayer is never paid directly");
        assertEq(token.allowance(payer, spender), allowanceValue, "allowance is what the payer signed");
    }

    function testFuzz_onlyRelayer(address caller) public {
        vm.assume(caller != relayer);
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(1e9, 1_000);
        (uint8 pv, bytes32 pr, bytes32 ps) = _signPermit(PAYER_KEY, payer, spender, 1e9, sp.allowanceDeadline);
        (uint8 fv, bytes32 fr, bytes32 fs) =
            _signReceive(PAYER_KEY, payer, address(sponsor), 1_000, sp.validBefore, sponsor.authorizationNonce(sp));
        vm.prank(caller);
        vm.expectRevert(P2FluxGasSponsor.NotRelayer.selector);
        sponsor.sponsorPermit(sp, pv, pr, ps, fv, fr, fs);
    }

    function testFuzz_feeAboveCapRefused(uint256 networkFee) public {
        networkFee = bound(networkFee, SPONSORED_FEE_CAP + 1, type(uint128).max);
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(1e9, networkFee);
        (uint8 pv, bytes32 pr, bytes32 ps) = _signPermit(PAYER_KEY, payer, spender, 1e9, sp.allowanceDeadline);
        vm.prank(relayer);
        vm.expectRevert(P2FluxGasSponsor.NetworkFeeTooHigh.selector);
        sponsor.sponsorPermit(sp, pv, pr, ps, 27, bytes32(0), bytes32(0));
    }

    /// The fee authorization commits to the spender and the allowance: swap either and it is void.
    function testFuzz_tamperedSponsorshipRefused(uint8 field, uint256 delta) public {
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(1e9, 2_000);
        (uint8 pv, bytes32 pr, bytes32 ps) = _signPermit(PAYER_KEY, payer, spender, 1e9, sp.allowanceDeadline);
        (uint8 fv, bytes32 fr, bytes32 fs) =
            _signReceive(PAYER_KEY, payer, address(sponsor), 2_000, sp.validBefore, sponsor.authorizationNonce(sp));
        delta = bound(delta, 1, 1e6);
        field = uint8(bound(field, 0, 3));
        if (field == 0) sp.spender = makeAddr("attackerSpender");
        if (field == 1) sp.allowanceValue += delta;
        if (field == 2) sp.networkFee = 2_000 + (delta % (SPONSORED_FEE_CAP - 2_000)) + 1;
        if (field == 3) sp.allowanceDeadline += delta;

        vm.prank(relayer);
        vm.expectRevert();
        sponsor.sponsorPermit(sp, pv, pr, ps, fv, fr, fs);
        assertEq(token.allowance(payer, makeAddr("attackerSpender")), 0, "no allowance for a substituted spender");
        assertEq(token.balanceOf(gasTreasury), 0, "no fee taken for a refused sponsorship");
    }

    function test_replayRefused() public {
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(1e9, 1_000);
        (uint8 pv, bytes32 pr, bytes32 ps) = _signPermit(PAYER_KEY, payer, spender, 1e9, sp.allowanceDeadline);
        bytes32 nonce = sponsor.authorizationNonce(sp);
        (uint8 fv, bytes32 fr, bytes32 fs) =
            _signReceive(PAYER_KEY, payer, address(sponsor), 1_000, sp.validBefore, nonce);
        vm.startPrank(relayer);
        sponsor.sponsorPermit(sp, pv, pr, ps, fv, fr, fs);
        vm.expectRevert(abi.encodeWithSelector(P2FluxGasSponsor.SponsorshipAlreadySettled.selector, nonce));
        sponsor.sponsorPermit(sp, pv, pr, ps, fv, fr, fs);
        vm.stopPrank();
    }

    /// All-or-nothing: if the permit fails, the fee that was already pulled is rolled back with it.
    function test_failedPermitTakesNoFee() public {
        PermitRevertingToken bad = new PermitRevertingToken();
        P2FluxGasSponsor s2 = new P2FluxGasSponsor(address(bad), gasTreasury, relayer, SPONSORED_FEE_CAP);
        bad.mint(payer, 1e9);
        P2FluxGasSponsor.PermitSponsorship memory sp = _terms(1e9, 1_000);
        bytes32 structHash = keccak256(
            abi.encode(
                bad.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                address(s2),
                uint256(1_000),
                uint256(0),
                sp.validBefore,
                s2.authorizationNonce(sp)
            )
        );
        (uint8 fv, bytes32 fr, bytes32 fs) =
            vm.sign(PAYER_KEY, keccak256(abi.encodePacked("\x19\x01", bad.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(relayer);
        vm.expectRevert();
        s2.sponsorPermit(sp, 27, bytes32(0), bytes32(0), fv, fr, fs);
        assertEq(bad.balanceOf(payer), 1e9, "fee rolled back with the failed permit");
        assertFalse(s2.settledSponsorships(s2.authorizationNonce(sp)), "and the sponsorship stays open");
    }

    function testFuzz_donatedDustIsInert(uint256 dust) public {
        dust = bound(dust, 1, 1e12);
        token.mint(address(sponsor), dust);
        _submit(_terms(1e9, 1_000), relayer);
        assertEq(token.balanceOf(address(sponsor)), dust);
    }
}
