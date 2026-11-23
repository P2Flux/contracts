// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3009} from "../P2FluxSponsoredSplitter.sol";
import {P2FluxV2Base} from "./P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxSponsoredSplitterV2
/// @notice One-time payment for a buyer with no native gas. The buyer signs one EIP-3009
///         ReceiveWithAuthorization for `amount + networkFee`; the relayer submits it.
///
///         buyer debit  = amount + networkFee          (networkFee = quoted gas, signed, capped)
///         recipient    = amount - fee - fixedFee      (merchant funds both P2Flux fees)
///         feeWallet    = fee = floor(amount * bps / 10_000), bps from the registry (partner aware)
///         gasTreasury  = fixedFee + networkFee
///
/// @dev Same design as P2FluxSponsoredSplitter. Differences: rates come from the registry, and the
///      authorization nonce no longer binds the fixed fee - the buyer's debit never depends on P2Flux
///      fees, and fee changes are timelocked and public (see docs/v2-design.md).
contract P2FluxSponsoredSplitterV2 is P2FluxV2Base, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");
    bytes32 public constant SPONSOR_PAY_DOMAIN = keccak256("P2FLUX_SPONSORED_PAYMENT_V2");

    /// @notice Receives the fixed fee and the quoted network fee: the gas side, never revenue.
    address public immutable gasTreasury;

    /// @notice The only address that may execute a sponsored payment.
    address public immutable relayer;

    /// @notice Per-chain ceiling on the quoted network fee, in token base units.
    uint256 public immutable MAX_NETWORK_FEE_HARD_CAP;

    mapping(bytes32 => bool) public processedPayments;

    struct SponsoredPayment {
        address payer;
        address recipient;
        uint256 amount;
        bytes32 ref;
        uint256 networkFee;
        uint256 validBefore;
    }

    event SponsoredPaid(
        bytes32 indexed ref,
        address indexed recipient,
        address indexed payer,
        uint256 net,
        uint256 fee,
        uint256 networkFee,
        uint256 fixedNetworkFee
    );
    event PaymentSettled(bytes32 indexed paymentId);

    error ZeroAmount();
    error AmountTooSmall();
    error NotRelayer();
    error NetworkFeeTooHigh();
    error CapTooHigh();
    error PaymentAlreadyProcessed(bytes32 paymentId);
    error ResidualBalance();

    constructor(
        address _supportedToken,
        address _feeWallet,
        address _gasTreasury,
        address _relayer,
        address _registry,
        uint256 _maxNetworkFeeHardCap
    ) P2FluxV2Base(_supportedToken, _feeWallet, _registry) {
        if (_gasTreasury == address(0) || _relayer == address(0)) revert ZeroAddress();
        if (_maxNetworkFeeHardCap > 1e6) revert CapTooHigh(); // never more than 1 USDC of gas
        gasTreasury = _gasTreasury;
        relayer = _relayer;
        MAX_NETWORK_FEE_HARD_CAP = _maxNetworkFeeHardCap;
    }

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

    /// @notice The EIP-3009 nonce these terms produce. Binds every term the buyer agreed to.
    function authorizationNonce(SponsoredPayment calldata p) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                SPONSOR_PAY_DOMAIN,
                block.chainid,
                address(this),
                supportedToken,
                p.payer,
                p.recipient,
                p.amount,
                p.ref,
                p.networkFee,
                p.validBefore
            )
        );
    }

    /// @notice The smallest amount that leaves `recipient` something at today's rates.
    /// @dev Closed form of: smallest a with a - floor(a*bps/1e4) > fixedFee.
    function minimumAmount(address recipient) external view returns (uint256) {
        (uint256 bps, uint256 fixedFee) = registry.feeFor(P2FluxFeeRegistry.Kind.OneTime, recipient);
        return (fixedFee * 10_000) / (10_000 - bps) + 1;
    }

    function payWithAuthorization(SponsoredPayment calldata p, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (msg.sender != relayer) revert NotRelayer();
        if (p.recipient == address(0) || p.payer == address(0)) revert ZeroAddress();
        if (p.amount == 0) revert ZeroAmount();
        if (p.networkFee > MAX_NETWORK_FEE_HARD_CAP) revert NetworkFeeTooHigh();

        (uint256 fee, uint256 fixedFee) = _fees(P2FluxFeeRegistry.Kind.OneTime, p.recipient, p.amount);
        if (p.amount <= fee + fixedFee) revert AmountTooSmall();

        bytes32 id = paymentId(supportedToken, p.recipient, p.amount, p.ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        // Leave no more than found; donated dust stays inert instead of bricking the contract.
        uint256 heldBefore = IERC20(supportedToken).balanceOf(address(this));

        IERC3009(supportedToken)
            .receiveWithAuthorization(
                p.payer, address(this), p.amount + p.networkFee, 0, p.validBefore, authorizationNonce(p), v, r, s
            );
        _payOut(p.recipient, p.amount - fee - fixedFee, fee, fixedFee + p.networkFee);

        if (IERC20(supportedToken).balanceOf(address(this)) != heldBefore) revert ResidualBalance();

        emit SponsoredPaid(p.ref, p.recipient, p.payer, p.amount - fee - fixedFee, fee, p.networkFee, fixedFee);
        emit PaymentSettled(id);
    }

    function _payOut(address recipient, uint256 net, uint256 fee, uint256 gasSide) private {
        IERC20 token = IERC20(supportedToken);
        token.safeTransfer(recipient, net);
        if (fee > 0) token.safeTransfer(feeWallet, fee);
        if (gasSide > 0) token.safeTransfer(gasTreasury, gasSide);
    }
}
