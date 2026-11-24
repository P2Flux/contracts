// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxV2Base
/// @notice What every v2 payment contract shares: the pinned token, the immutable fee wallet, the
///         chain's fee registry, the recipient rule, and the one line of fee math.
abstract contract P2FluxV2Base {
    /// @notice Hard caps re-checked on every read from the registry, so they hold even if the
    ///         registry address were wrong or a registry had a bug. Same values as the registry's.
    uint256 public constant MAX_BPS = 200;
    uint256 public constant MAX_FIXED_FEE = 0.2e6;

    /// @notice The only token this deployment settles: the chain's native USDC.
    address public immutable supportedToken;

    /// @notice Receives the percentage fee and nothing else. Immutable: no key can redirect it.
    address public immutable feeWallet;

    /// @notice Where the current rates and partner list are read from. Immutable.
    P2FluxFeeRegistry public immutable registry;

    error ZeroAddress();
    error NotAContract();
    error WrongDecimals();
    error BadRegistry();
    error RateAboveCap();
    error InvalidRecipient();

    constructor(address _supportedToken, address _feeWallet, address _registry) {
        if (_supportedToken == address(0) || _feeWallet == address(0) || _registry == address(0)) {
            revert ZeroAddress();
        }
        // A token or registry with no code would make transfers and fee reads silent no-ops.
        if (_supportedToken.code.length == 0 || _registry.code.length == 0) revert NotAContract();
        // Fixed fees, caps and the minimum send are 6-decimal USDC quantities.
        if (IERC20Metadata(_supportedToken).decimals() != 6) revert WrongDecimals();
        // Sanity read: the address must be a registry with the caps and delay this code expects.
        P2FluxFeeRegistry reg = P2FluxFeeRegistry(_registry);
        if (reg.MAX_BPS() != MAX_BPS || reg.MAX_FIXED_FEE() != MAX_FIXED_FEE || reg.DELAY() != 48 hours) {
            revert BadRegistry();
        }
        reg.rates(P2FluxFeeRegistry.Kind.OneTime); // reverts unless it answers the read the payments use
        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
        registry = reg;
    }

    /// @dev A payment to the contract itself would be locked forever: no function can move it out.
    function _checkRecipient(address recipient) internal view {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this)) revert InvalidRecipient();
    }

    /// @dev The effective (bps, fixedFee) for `recipient`, with the hard caps re-checked here.
    function _rate(P2FluxFeeRegistry.Kind kind, address recipient)
        internal
        view
        returns (uint256 bps, uint256 fixedFee)
    {
        (uint16 b, uint16 pb, uint64 f) = registry.rates(kind);
        if (b > MAX_BPS || pb > b || f > MAX_FIXED_FEE) revert RateAboveCap();
        bps = pb != b && registry.isPartner(recipient) ? pb : b;
        fixedFee = f;
    }

    /// @dev Percentage fee rounds DOWN: the payer (fees on top) or the merchant (fees out of the
    ///      amount) keeps the sub-unit remainder; P2Flux never takes more than the exact rate.
    ///      The fixed fee applies only when P2Flux's relayer pays the gas (`relayed`); never when the
    ///      payer or anyone else pays their own gas.
    function _fees(P2FluxFeeRegistry.Kind kind, address recipient, uint256 amount, bool relayed)
        internal
        view
        returns (uint256 fee, uint256 fixedFee)
    {
        uint256 bps;
        (bps, fixedFee) = _rate(kind, recipient);
        fee = (amount * bps) / 10_000;
        if (!relayed) fixedFee = 0;
    }
}
