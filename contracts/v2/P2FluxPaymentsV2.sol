// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3009} from "../P2FluxSponsoredSplitter.sol";
import {P2FluxV2Base} from "./P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxPaymentsV2
/// @notice One-time payments, one contract, two entrances, ONE replay table:
///
///   1. self-pay (`pay`, `payWithPermit`): the buyer sends the tx and pays the gas.
///        buyer debit = amount; recipient = amount - fee; feeWallet = fee. No fixed fee.
///   2. sponsored (`payWithAuthorization`, relayer only): the buyer signs EIP-3009, the relayer pays
///      the gas and the buyer reimburses it in USDC on top (signed, capped).
///        buyer debit = amount + networkFee; recipient = amount - fee - fixedFee;
///        feeWallet = fee; gasTreasury = fixedFee + networkFee.
///
///   fee = floor(amount * bps / 10_000), bps = registry one-time rate (partner rate if listed).
///
/// @dev Both entrances settle the same `paymentId(token, recipient, amount, ref)` in the same
///      `processedPayments`, so an order paid through one entrance can never be paid again through the
///      other: checkout can offer "auto" (self-pay if the buyer has gas, else sponsored) with no
///      double-payment window. The id is bound to the full terms, not the bare ref, so nobody can block
///      an order without actually paying it to its recipient.
///
///      No custody, no withdrawal, no upgrade. The only role is the relayer (sponsored entrance).
contract P2FluxPaymentsV2 is P2FluxV2Base, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Same as v1, so one id routine serves every version. v1 contracts keep their own tables.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    /// @dev Domain tag of the sponsored entrance's EIP-3009 nonce (v1 used ..._V1).
    bytes32 public constant SPONSOR_PAY_DOMAIN = keccak256("P2FLUX_SPONSORED_PAYMENT_V2");

    /// @notice Receives the fixed fee and the quoted network fee: the gas side, never revenue.
    address public immutable gasTreasury;

    /// @notice The only address that may use the sponsored entrance.
    address public immutable relayer;

    /// @notice Per-chain ceiling on the quoted network fee, in token base units.
    uint256 public immutable MAX_NETWORK_FEE_HARD_CAP;

    /// @notice Settled orders, shared by both entrances.
    mapping(bytes32 => bool) public processedPayments;

    struct SponsoredPayment {
        address payer;
        address recipient;
        uint256 amount;
        bytes32 ref;
        uint256 networkFee;
        uint256 validBefore;
    }

    /// @notice `entrance` values of `PaymentSettled`.
    uint8 public constant ENTRANCE_SELF_PAY = 0;
    uint8 public constant ENTRANCE_SPONSORED = 1;

    /// @notice The one settlement event, for both entrances. An order is paid only when `id` equals
    ///         the order's stored `paymentId` (a bare `ref` match is NOT proof: see design §13, U-01).
    /// @param payer The real buyer: msg.sender for self-pay, the EIP-3009 authorizer for sponsored.
    /// @param amount The order amount (merchant price). Recipient got `amount - fee - fixedFee`.
    /// @param fixedFee 0 on self-pay.
    /// @param gasReimbursement The buyer's signed network fee to the gas treasury (0 on self-pay).
    event PaymentSettled(
        bytes32 indexed id,
        bytes32 indexed ref,
        address indexed recipient,
        address payer,
        uint256 amount,
        uint256 fee,
        uint256 fixedFee,
        uint256 gasReimbursement,
        uint8 entrance
    );

    error ZeroAmount();
    error AmountTooSmall();
    error TokenNotSupported();
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

    // --- views ---------------------------------------------------------------

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

    /// @notice The EIP-3009 nonce a sponsored payment's terms produce. Binds every term.
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

    /// @notice The smallest SPONSORED amount that leaves `recipient` something at today's rates.
    /// @dev Closed form of: smallest a with a - floor(a*bps/1e4) > fixedFee. `_rate` re-checks the
    ///      caps, so bps <= 200 and the division is always defined. Self-pay has no minimum beyond 1.
    function minimumAmount(address recipient) external view returns (uint256) {
        (uint256 bps, uint256 fixedFee) = _rate(P2FluxFeeRegistry.Kind.OneTime, recipient);
        return (fixedFee * 10_000) / (10_000 - bps) + 1;
    }

    // --- entrance 1: self-pay ------------------------------------------------

    /// @notice Pay `amount` to `recipient` from msg.sender's allowance; msg.sender pays the gas.
    function pay(address token, address recipient, uint256 amount, bytes32 ref) external nonReentrant {
        _pay(token, recipient, amount, ref);
    }

    /// @notice `pay` with an EIP-2612 permit first. A front-run permit is swallowed; if the allowance
    ///         is really missing, the transfer reverts.
    function payWithPermit(
        address token,
        address recipient,
        uint256 amount,
        bytes32 ref,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        if (token != supportedToken) revert TokenNotSupported();
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _pay(token, recipient, amount, ref);
    }

    function _pay(address token, address recipient, uint256 amount, bytes32 ref) private {
        if (token != supportedToken) revert TokenNotSupported();
        (bytes32 id, uint256 fee,) = _open(recipient, amount, ref, false);
        _payOut(msg.sender, recipient, amount - fee, fee, 0);
        emit PaymentSettled(id, ref, recipient, msg.sender, amount, fee, 0, 0, ENTRANCE_SELF_PAY);
    }

    // --- entrance 2: sponsored -----------------------------------------------

    /// @notice Settle a payment the buyer signed (EIP-3009 ReceiveWithAuthorization for exactly
    ///         `amount + networkFee` to this contract, nonce = `authorizationNonce(p)`).
    function payWithAuthorization(SponsoredPayment calldata p, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (msg.sender != relayer) revert NotRelayer();
        if (p.payer == address(0)) revert ZeroAddress();
        if (p.networkFee > MAX_NETWORK_FEE_HARD_CAP) revert NetworkFeeTooHigh();
        (bytes32 id, uint256 fee, uint256 fixedFee) = _open(p.recipient, p.amount, p.ref, true);

        // Leave no more than found; donated dust stays inert instead of bricking the contract.
        uint256 heldBefore = IERC20(supportedToken).balanceOf(address(this));
        IERC3009(supportedToken)
            .receiveWithAuthorization(
                p.payer, address(this), p.amount + p.networkFee, 0, p.validBefore, authorizationNonce(p), v, r, s
            );
        _payOut(address(this), p.recipient, p.amount - fee - fixedFee, fee, fixedFee + p.networkFee);
        if (IERC20(supportedToken).balanceOf(address(this)) != heldBefore) revert ResidualBalance();

        emit PaymentSettled(id, p.ref, p.recipient, p.payer, p.amount, fee, fixedFee, p.networkFee, ENTRANCE_SPONSORED);
    }

    // --- shared --------------------------------------------------------------

    /// @dev Every check both entrances share, then the replay mark (effects before interactions; a
    ///      revert later rolls it back, so a failed attempt leaves the order payable).
    function _open(address recipient, uint256 amount, bytes32 ref, bool sponsored)
        private
        returns (bytes32 id, uint256 fee, uint256 fixedFee)
    {
        _checkRecipient(recipient);
        if (amount == 0) revert ZeroAmount();
        (fee, fixedFee) = _fees(P2FluxFeeRegistry.Kind.OneTime, recipient, amount, sponsored);
        if (amount <= fee + fixedFee) revert AmountTooSmall();
        id = paymentId(supportedToken, recipient, amount, ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;
    }

    /// @dev Pays out from the buyer (self-pay, by allowance) or from this contract (sponsored).
    function _payOut(address from, address recipient, uint256 net, uint256 fee, uint256 gasSide) private {
        _move(from, recipient, net);
        if (fee > 0) _move(from, feeWallet, fee);
        if (gasSide > 0) _move(from, gasTreasury, gasSide);
    }

    function _move(address from, address to, uint256 value) private {
        if (from == address(this)) IERC20(supportedToken).safeTransfer(to, value);
        else IERC20(supportedToken).safeTransferFrom(from, to, value);
    }
}
