// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC3009} from "../P2FluxSponsoredSplitter.sol";
import {P2FluxV2Base} from "./P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxSend
/// @notice Send USDC to anyone. The receiver gets EXACTLY `amount`; fees are paid ON TOP by the sender.
///
///         direct  (sender pays gas):  sender debit = amount + fee
///         relayed (sender has no gas): sender debit = amount + fee + fixedFee + networkFee
///
///         fee = floor(amount * bps / 10_000), bps = registry Send rate (no partner tier).
///         fee -> feeWallet; fixedFee + networkFee -> gasTreasury. Minimum send 1 USDC; no maximum.
///
/// @dev No custody, no role beyond the relayer, no withdrawal. Direct sends take a `maxFee` so a
///      rate change landing in the same block can never take more than the sender agreed to. Relayed
///      sends need no such guard: the sender signs the exact total, so any other fee fails the token's
///      signature check.
contract P2FluxSend is P2FluxV2Base, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Smallest send: 1 USDC (6 decimals).
    uint256 public constant MIN_SEND = 1e6;

    bytes32 public constant SEND_DOMAIN = keccak256("P2FLUX_SEND_V1");

    /// @notice Receives the fixed fee and the quoted network fee of relayed sends.
    address public immutable gasTreasury;

    /// @notice The only address that may submit a relayed send.
    address public immutable relayer;

    /// @notice Per-chain ceiling on the quoted network fee, in token base units.
    uint256 public immutable MAX_NETWORK_FEE_HARD_CAP;

    /// @param from Sender, the signer.
    /// @param to Receiver; gets exactly `amount`.
    /// @param amount What the receiver gets.
    /// @param ref Opaque reference.
    /// @param networkFee Quoted gas the sender accepted. Capped.
    /// @param validBefore Quote expiry, enforced by the token.
    struct RelayedSend {
        address from;
        address to;
        uint256 amount;
        bytes32 ref;
        uint256 networkFee;
        uint256 validBefore;
    }

    event Sent(
        bytes32 indexed ref,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 fixedFee,
        uint256 networkFee
    );

    error AmountTooSmall();
    error FeeAboveMax();
    error NotRelayer();
    error NetworkFeeTooHigh();
    error CapTooHigh();
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

    /// @notice Fees for sending `amount` right now. `fixedFee` applies to relayed sends only.
    function quote(uint256 amount) public view returns (uint256 fee, uint256 fixedFee) {
        // Sends have no partner tier: address(0) can never be listed, so this is always `bps`.
        return _fees(P2FluxFeeRegistry.Kind.Send, address(0), amount);
    }

    /// @notice The EIP-3009 nonce a relayed send's terms produce. Binds every term.
    function authorizationNonce(RelayedSend calldata s) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                SEND_DOMAIN,
                block.chainid,
                address(this),
                supportedToken,
                s.from,
                s.to,
                s.amount,
                s.ref,
                s.networkFee,
                s.validBefore
            )
        );
    }

    /// @notice Send from msg.sender's allowance. Reverts if the fee would exceed `maxFee`.
    function send(address to, uint256 amount, uint256 maxFee, bytes32 ref) public {
        if (to == address(0)) revert ZeroAddress();
        if (amount < MIN_SEND) revert AmountTooSmall();
        (uint256 fee,) = quote(amount);
        if (fee > maxFee) revert FeeAboveMax();

        IERC20(supportedToken).safeTransferFrom(msg.sender, to, amount);
        if (fee > 0) IERC20(supportedToken).safeTransferFrom(msg.sender, feeWallet, fee);

        emit Sent(ref, msg.sender, to, amount, fee, 0, 0);
    }

    /// @notice `send` after an EIP-2612 permit for `amount + maxFee`. A front-run permit is swallowed.
    function sendWithPermit(
        address to,
        uint256 amount,
        uint256 maxFee,
        bytes32 ref,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        try IERC20Permit(supportedToken).permit(msg.sender, address(this), amount + maxFee, deadline, v, r, s) {}
            catch {}
        send(to, amount, maxFee, ref);
    }

    /// @notice Relayed send: the sender signed ReceiveWithAuthorization for exactly
    ///         `amount + fee + fixedFee + networkFee` to this contract, with `authorizationNonce(s)`.
    function sendWithAuthorization(RelayedSend calldata s, uint8 v, bytes32 r, bytes32 sig) external nonReentrant {
        if (msg.sender != relayer) revert NotRelayer();
        if (s.to == address(0) || s.from == address(0)) revert ZeroAddress();
        if (s.amount < MIN_SEND) revert AmountTooSmall();
        if (s.networkFee > MAX_NETWORK_FEE_HARD_CAP) revert NetworkFeeTooHigh();

        (uint256 fee, uint256 fixedFee) = quote(s.amount);
        IERC20 token = IERC20(supportedToken);
        uint256 heldBefore = token.balanceOf(address(this));

        // The token checks the signature over this exact value and burns the nonce (replay guard).
        IERC3009(supportedToken)
            .receiveWithAuthorization(
                s.from,
                address(this),
                s.amount + fee + fixedFee + s.networkFee,
                0,
                s.validBefore,
                authorizationNonce(s),
                v,
                r,
                sig
            );

        token.safeTransfer(s.to, s.amount);
        if (fee > 0) token.safeTransfer(feeWallet, fee);
        if (fixedFee + s.networkFee > 0) token.safeTransfer(gasTreasury, fixedFee + s.networkFee);

        if (token.balanceOf(address(this)) != heldBefore) revert ResidualBalance();

        emit Sent(s.ref, s.from, s.to, s.amount, fee, fixedFee, s.networkFee);
    }
}
