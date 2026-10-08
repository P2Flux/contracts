// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "./Helpers.sol";
import {P2FluxRecurring} from "../../contracts/P2FluxRecurring.sol";

/// @dev An ERC-1271 wallet whose owner can be rotated: the wallet is the authority on its signatures.
contract RotatingWallet {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function rotate(address next) external {
        owner = next;
    }

    function approve(address token, address spender) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok);
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(sig[:64], (bytes32, bytes32));
        uint8 v = uint8(sig[64]);
        return ecrecover(digest, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Code an EOA delegates to under EIP-7702. It answers ERC-1271 with "no": only the EOA's own
///      key can authorise, which is what the contract honours for a delegated EOA.
contract RefusingDelegate {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

/// @notice The read-only answers the P2Flux API relies on - `isChargeable`, `currentPeriod`,
///         `isValidAuthorization` - must agree with what `charge` actually does, for any timing,
///         revocation, prior charge, signature and wallet type. If they disagreed, the API would tell a
///         merchant a subscription is due when it is not, or the reverse.
contract RecurringViewsTest is P2FluxTest {
    P2FluxRecurring internal recurring;

    function setUp() public {
        _baseSetUp();
        recurring = new P2FluxRecurring(admin, relayer, feeWallet, gasTreasury, address(token));
        token.mint(payer, 1e18);
        vm.prank(payer);
        token.approve(address(recurring), type(uint256).max);
    }

    function _auth(address who, uint48 period, uint48 start, uint48 end)
        internal
        view
        returns (P2FluxRecurring.RecurringAuthorization memory)
    {
        return P2FluxRecurring.RecurringAuthorization({
            payer: who,
            recipient: address(0xBEEF),
            token: address(token),
            amount: 10e6,
            period: period,
            start: start,
            end: end,
            salt: bytes32(uint256(7)),
            maxGasReimbursement: 0
        });
    }

    function _try(P2FluxRecurring.RecurringAuthorization memory a, bytes memory sig) internal returns (bool ok) {
        vm.prank(relayer);
        try recurring.charge(a, sig, 0) {
            ok = true;
        } catch {}
    }

    /// isChargeable(auth) is true exactly when a validly signed charge succeeds; after a successful
    /// charge, the period it recorded is currentPeriod.
    function testFuzz_isChargeable_agreesWithCharge(
        uint32 period,
        uint32 startIn,
        uint32 length,
        uint32 warp,
        bool hasEnd,
        bool revokeIt,
        bool chargeFirst
    ) public {
        period = uint32(bound(period, 1, 365 days));
        startIn = uint32(bound(startIn, 0, 30 days));
        length = uint32(bound(length, 1, 400 days));
        warp = uint32(bound(warp, 0, 800 days));
        uint48 start = uint48(block.timestamp + startIn);
        uint48 end = hasEnd ? uint48(start + length) : 0;
        P2FluxRecurring.RecurringAuthorization memory a = _auth(payer, uint48(period), start, end);
        bytes memory sig = _signDigest(PAYER_KEY, recurring.subscriptionId(a));

        if (chargeFirst) {
            vm.warp(start);
            _try(a, sig);
        }
        if (revokeIt) {
            vm.prank(payer);
            recurring.revoke(a);
        }
        vm.warp(block.timestamp + warp);

        bool predicted = recurring.isChargeable(a);
        bool ok = _try(a, sig);
        assertEq(ok, predicted, "isChargeable must predict charge");
        if (ok) {
            assertEq(recurring.lastChargedPeriodPlusOne(recurring.subscriptionId(a)), recurring.currentPeriod(a) + 1);
            assertFalse(recurring.isChargeable(a), "never chargeable twice in a period");
        }
    }

    /// isValidAuthorization agrees with charge for any single-byte change to the signature.
    function testFuzz_isValidAuthorization_agreesWithCharge(uint8 index, uint8 flip, bool tamper) public {
        P2FluxRecurring.RecurringAuthorization memory a =
            _auth(payer, uint48(30 days), uint48(block.timestamp), 0);
        bytes memory sig = _signDigest(PAYER_KEY, recurring.subscriptionId(a));
        if (tamper && flip != 0) sig[index % sig.length] = bytes1(uint8(sig[index % sig.length]) ^ flip);

        bool predicted = recurring.isValidAuthorization(a, sig);
        assertEq(_try(a, sig), predicted, "isValidAuthorization must predict charge");
        if (tamper && flip != 0) assertFalse(predicted, "a changed signature is never valid");
    }

    /// A contract wallet (ERC-1271) is charged while it vouches for the signature, and never again
    /// once its owner rotates: the wallet withdrawing consent stops the subscription.
    function test_contractWallet_rotationStopsCharges() public {
        uint256 ownerKey = 0xB0B;
        RotatingWallet wallet = new RotatingWallet(vm.addr(ownerKey));
        token.mint(address(wallet), 1e12);
        wallet.approve(address(token), address(recurring));

        P2FluxRecurring.RecurringAuthorization memory a =
            _auth(address(wallet), uint48(1 days), uint48(block.timestamp), 0);
        bytes memory sig = _signDigest(ownerKey, recurring.subscriptionId(a));

        assertTrue(recurring.isValidAuthorization(a, sig));
        assertTrue(_try(a, sig), "charged while the wallet vouches");

        wallet.rotate(address(0xDEAD));
        vm.warp(block.timestamp + 1 days);
        assertTrue(recurring.isChargeable(a), "due by time");
        assertFalse(recurring.isValidAuthorization(a, sig), "no longer vouched for");
        assertFalse(_try(a, sig), "never charged after rotation");
    }

    /// An EIP-7702 delegated EOA: its own key's signature is honoured (the key controls the account
    /// anyway); a delegate that refuses ERC-1271 does not make a stranger's signature acceptable.
    function test_7702DelegatedEoa_ownKeyOnly() public {
        RefusingDelegate delegate = new RefusingDelegate();
        vm.signAndAttachDelegation(address(delegate), PAYER_KEY);
        assertGt(payer.code.length, 0, "payer is delegated");

        P2FluxRecurring.RecurringAuthorization memory a = _auth(payer, uint48(1 days), uint48(block.timestamp), 0);
        bytes memory stranger = _signDigest(0x5757, recurring.subscriptionId(a));
        assertFalse(recurring.isValidAuthorization(a, stranger));
        assertFalse(_try(a, stranger), "a stranger's signature is refused");

        bytes memory own = _signDigest(PAYER_KEY, recurring.subscriptionId(a));
        assertTrue(recurring.isValidAuthorization(a, own));
        assertTrue(_try(a, own), "the account's own key is honoured");
    }

    /// The constructor refuses every zero address: a deployment can never route money to nowhere.
    function test_constructor_refusesZeroAddresses() public {
        address t = address(token);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        new P2FluxRecurring(address(0), relayer, feeWallet, gasTreasury, t);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        new P2FluxRecurring(admin, address(0), feeWallet, gasTreasury, t);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        new P2FluxRecurring(admin, relayer, address(0), gasTreasury, t);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        new P2FluxRecurring(admin, relayer, feeWallet, address(0), t);
        vm.expectRevert(P2FluxRecurring.ZeroAddress.selector);
        new P2FluxRecurring(admin, relayer, feeWallet, gasTreasury, address(0));
    }
}
