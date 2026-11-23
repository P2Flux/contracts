// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxV2Base
/// @notice What every v2 payment contract shares: the pinned token, the immutable fee wallet, the
///         chain's fee registry, and the one line of fee math.
abstract contract P2FluxV2Base {
    /// @notice The only token this deployment settles: the chain's native USDC.
    address public immutable supportedToken;

    /// @notice Receives the percentage fee and nothing else. Immutable: no key can redirect it.
    address public immutable feeWallet;

    /// @notice Where the current rates and partner list are read from. Immutable.
    P2FluxFeeRegistry public immutable registry;

    error ZeroAddress();
    error NotAContract();
    error WrongDecimals();

    constructor(address _supportedToken, address _feeWallet, address _registry) {
        if (_supportedToken == address(0) || _feeWallet == address(0) || _registry == address(0)) {
            revert ZeroAddress();
        }
        // A token or registry with no code would make transfers and fee reads silent no-ops.
        if (_supportedToken.code.length == 0 || _registry.code.length == 0) revert NotAContract();
        // Fixed fees, caps and the minimum send are 6-decimal USDC quantities.
        if (IERC20Metadata(_supportedToken).decimals() != 6) revert WrongDecimals();
        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
        registry = P2FluxFeeRegistry(_registry);
    }

    /// @dev Percentage fee rounds DOWN: the payer (fees on top) or the merchant (fees out of the
    ///      amount) keeps the sub-unit remainder; P2Flux never takes more than the exact rate.
    function _fees(P2FluxFeeRegistry.Kind kind, address recipient, uint256 amount)
        internal
        view
        returns (uint256 fee, uint256 fixedFee)
    {
        uint256 bps;
        (bps, fixedFee) = registry.feeFor(kind, recipient);
        fee = (amount * bps) / 10_000;
    }
}
