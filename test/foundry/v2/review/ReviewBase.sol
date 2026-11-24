// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V2Test} from "../V2Helpers.sol";
import {P2FluxFeeRegistry} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxSplitterV2} from "../../../../contracts/v2/P2FluxSplitterV2.sol";
import {P2FluxSponsoredSplitterV2 as Sponsored} from "../../../../contracts/v2/P2FluxSponsoredSplitterV2.sol";
import {P2FluxRecurringV2 as Recurring} from "../../../../contracts/v2/P2FluxRecurringV2.sol";
import {P2FluxSend} from "../../../../contracts/v2/P2FluxSend.sol";

/// @notice Review fixture (internal review 2026-11-24): the full v2 set on the mock FiatToken, at
///         the owner-agreed prices, plus signing helpers for every relayed path.
abstract contract ReviewBase is V2Test {
    P2FluxSplitterV2 internal splitter;
    Sponsored internal sponsored;
    Recurring internal recurring;
    P2FluxSend internal sender;
    address internal merchant = makeAddr("merchant");
    address internal attacker = makeAddr("attacker");
    uint256 internal constant GAS_CAP = 50_000;

    function _reviewSetUp() internal {
        _v2SetUp();
        splitter = new P2FluxSplitterV2(address(token), feeWallet, address(registry));
        sponsored = new Sponsored(address(token), feeWallet, gasTreasury, relayer, address(registry), NETWORK_CAP);
        recurring = new Recurring(admin, relayer, feeWallet, gasTreasury, address(token), address(registry), GAS_CAP);
        sender = new P2FluxSend(address(token), feeWallet, gasTreasury, relayer, address(registry));
    }

    function _sp(address recipient, uint256 amount, bytes32 ref, uint256 networkFee)
        internal
        view
        returns (Sponsored.SponsoredPayment memory)
    {
        return Sponsored.SponsoredPayment(payer, recipient, amount, ref, networkFee, block.timestamp + 600);
    }

    function _signSp(Sponsored.SponsoredPayment memory p) internal view returns (uint8, bytes32, bytes32) {
        return _signReceive(
            PAYER_KEY,
            p.payer,
            address(sponsored),
            p.amount + p.networkFee,
            p.validBefore,
            sponsored.authorizationNonce(p)
        );
    }

    function _rs(address to, uint256 amount, bytes32 ref) internal view returns (P2FluxSend.RelayedSend memory) {
        return P2FluxSend.RelayedSend(payer, to, amount, ref, block.timestamp + 600);
    }

    function _signRs(P2FluxSend.RelayedSend memory s, uint256 total) internal view returns (uint8, bytes32, bytes32) {
        return _signReceive(PAYER_KEY, s.from, address(sender), total, s.validBefore, sender.authorizationNonce(s));
    }

    function _relayedTotal(P2FluxSend.RelayedSend memory s) internal view returns (uint256) {
        (uint256 fee, uint256 fixedFee) = sender.quote(s.amount);
        return s.amount + fee + fixedFee;
    }

    function _auth(address recipient, uint256 amount, uint256 maxGas)
        internal
        view
        returns (Recurring.RecurringAuthorization memory)
    {
        return Recurring.RecurringAuthorization(
            payer, recipient, address(token), amount, 30 days, uint48(block.timestamp), 0, bytes32(uint256(7)), maxGas
        );
    }

    function _sigRec(Recurring.RecurringAuthorization memory a) internal view returns (bytes memory) {
        return _signDigest(PAYER_KEY, recurring.subscriptionId(a));
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }
}
