// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {P2FluxV2Base} from "./P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxSplitterV2
/// @notice One-time payment, buyer pays their own gas. The buyer is debited exactly `amount`; the
///         recipient gets `amount - fee`; the fee (registry one-time rate, partner rate if the
///         recipient is listed) goes to the fee wallet. No fixed fee on this path, as in v1.
///
/// @dev Same shape as P2FluxSplitter: no custody, no withdrawal, no role. The only change is that the
///      rate comes from the registry instead of a constant. The recipient's tier is looked up on
///      chain, so a merchant calling this directly cannot pick a lower fee.
contract P2FluxSplitterV2 is P2FluxV2Base {
    using SafeERC20 for IERC20;

    /// @dev Same as v1, so one id routine serves both. Each contract has its own replay table.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    mapping(bytes32 => bool) public processedPayments;

    event Paid(bytes32 indexed ref, address indexed recipient, address indexed token, uint256 net, uint256 fee);
    event PaymentSettled(bytes32 indexed paymentId);

    error ZeroAmount();
    error TokenNotSupported();
    error PaymentAlreadyProcessed(bytes32 paymentId);

    constructor(address _supportedToken, address _feeWallet, address _registry)
        P2FluxV2Base(_supportedToken, _feeWallet, _registry)
    {}

    function paymentId(address token, address recipient, uint256 amount, bytes32 ref) public pure returns (bytes32) {
        return keccak256(abi.encode(PAYMENT_DOMAIN, token, recipient, amount, ref));
    }

    function isPaymentProcessed(address token, address recipient, uint256 amount, bytes32 ref)
        external
        view
        returns (bool)
    {
        return processedPayments[paymentId(token, recipient, amount, ref)];
    }

    /// @notice Pay `amount` to `recipient`, fee out of the amount, from msg.sender's allowance.
    function pay(address token, address recipient, uint256 amount, bytes32 ref) public {
        if (token != supportedToken) revert TokenNotSupported();
        _checkRecipient(recipient);
        if (amount == 0) revert ZeroAmount();

        bytes32 id = paymentId(token, recipient, amount, ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        (uint256 fee,) = _fees(P2FluxFeeRegistry.Kind.OneTime, recipient, amount, false); // buyer pays gas: no fixed fee

        IERC20(token).safeTransferFrom(msg.sender, recipient, amount - fee);
        if (fee > 0) IERC20(token).safeTransferFrom(msg.sender, feeWallet, fee);

        emit Paid(ref, recipient, token, amount - fee, fee);
        emit PaymentSettled(id);
    }

    /// @notice `pay` with an EIP-2612 permit first, so the buyer needs one transaction.
    /// @dev A front-run permit is swallowed; if the allowance is really missing, `pay` reverts.
    function payWithPermit(
        address token,
        address recipient,
        uint256 amount,
        bytes32 ref,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (token != supportedToken) revert TokenNotSupported();
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        pay(token, recipient, amount, ref);
    }
}
