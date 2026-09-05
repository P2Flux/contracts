// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The token surface this contract needs: EIP-3009 to collect the fee, EIP-2612 to set the
///         allowance the customer is asking for. USDC (FiatToken v2) implements both.
interface ISponsorToken {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @title P2FluxGasSponsor
/// @notice Lets a customer with no native gas currency change their token allowance - to start a
///         subscription, to restore an allowance that ran short, or to remove it entirely - by
///         signing two messages instead of sending a transaction.
///
/// @dev This contract never settles a merchant payment. It does exactly one thing: collect the
///      quoted network fee the customer signed for, hand it to the gas treasury, and execute the
///      allowance change the customer signed for - in that order, in one transaction. If the
///      allowance change fails, the fee collection reverts with it: the customer is never charged
///      for an operation that did not happen, and P2Flux is never left having spent gas on an
///      operation it was not paid for. Those two facts are the whole point of the contract, and
///      they are why sponsorship lives here rather than inside a payment contract.
///
///      The fee authorization is the token's own `ReceiveWithAuthorization`: its EIP-712 domain
///      binds the chain and the token, and the `nonce` derived below binds this contract, the
///      payer, the operation, the spender, the exact allowance value and deadline, the quoted fee
///      and its expiry. Change any of them and the signature is for a different nonce, which the
///      token has never seen and this contract will not compute.
///
///      No owner, no pause, no upgrade, no withdrawal path, no custody: a call leaves no more than it
///      found, and tokens sent here by anyone else are inert rather than reachable.
contract P2FluxGasSponsor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Domain tag for allowance-sponsorship authorizations. Distinct from the sponsored
    ///      payment domain, so neither kind of signature can be spent as the other.
    bytes32 public constant SPONSOR_DOMAIN = keccak256("P2FLUX_GAS_SPONSOR_V1");

    /// @dev The operation this version performs. Part of the nonce, so a future operation added to
    ///      this contract can never be executed with a signature made for today's one.
    bytes32 public constant OPERATION_PERMIT = keccak256("PERMIT");

    /// @notice The only token this deployment sponsors.
    address public immutable supportedToken;

    /// @notice Receives the quoted network fee. Cost recovery, not revenue.
    address public immutable gasTreasury;

    /// @notice The only address that may execute a sponsorship.
    address public immutable relayer;

    /// @notice Ceiling on the network fee a single sponsorship may collect, in token base units.
    uint256 public immutable MAX_SPONSOR_FEE_HARD_CAP;

    /// @notice Sponsorships settled here, by authorization nonce.
    /// @dev The token's own nonce table already prevents replay. This mirror exists so a verifier
    ///      can ask this contract - one call, one address - whether a specific sponsorship was
    ///      performed, without trusting an event index or reading the token's storage layout.
    mapping(bytes32 => bool) public settledSponsorships;

    event SponsorshipSettled(
        address indexed payer,
        bytes32 indexed operation,
        address indexed spender,
        uint256 allowanceValue,
        uint256 networkFee,
        bytes32 authorizationNonce
    );

    error ZeroAddress();
    error NotRelayer();
    error NetworkFeeTooHigh();
    error SponsorshipAlreadySettled(bytes32 authorizationNonce);
    error ResidualBalance();

    constructor(
        address _supportedToken,
        address _gasTreasury,
        address _relayer,
        uint256 _maxSponsorFeeHardCap
    ) {
        if (_supportedToken == address(0) || _gasTreasury == address(0) || _relayer == address(0)) {
            revert ZeroAddress();
        }
        if (_supportedToken.code.length == 0) revert ZeroAddress();

        supportedToken = _supportedToken;
        gasTreasury = _gasTreasury;
        relayer = _relayer;
        MAX_SPONSOR_FEE_HARD_CAP = _maxSponsorFeeHardCap;
    }

    /// @notice The exact terms of one sponsorship. Grouped so the whole set travels as one value:
    ///         it is what the customer signs, what the relayer submits, and what the nonce is
    ///         derived from, and splitting it into loose arguments is how those three drift apart.
    /// @param payer The wallet whose allowance changes, and whose signature pays for the change.
    /// @param spender What the allowance is for - the recurring contract, never a caller's choice.
    /// @param allowanceValue The allowance to set. Zero removes it, which stops collection.
    /// @param allowanceDeadline The permit's deadline; the same instant as the quote's expiry.
    /// @param networkFee The quoted fee the customer accepted. Not a gas measurement.
    /// @param validBefore Quote expiry, enforced by the token.
    struct PermitSponsorship {
        address payer;
        address spender;
        uint256 allowanceValue;
        uint256 allowanceDeadline;
        uint256 networkFee;
        uint256 validBefore;
    }

    /// @notice The fee-authorization nonce these sponsorship terms produce.
    function authorizationNonce(PermitSponsorship calldata sponsorship) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                SPONSOR_DOMAIN,
                block.chainid,
                address(this),
                supportedToken,
                sponsorship.payer,
                OPERATION_PERMIT,
                sponsorship.spender,
                sponsorship.allowanceValue,
                sponsorship.allowanceDeadline,
                sponsorship.networkFee,
                sponsorship.validBefore
            )
        );
    }

    /// @notice Collect the quoted network fee and set the allowance the customer signed for.
    ///
    /// @dev Order matters and is deliberate: the fee is collected first, so a token that refuses the
    ///      fee never reaches the allowance change; and the allowance change is inside the same
    ///      transaction, so a failure there returns the fee. `permit` is called directly rather than
    ///      in a try/catch: a permit that cannot execute must undo the fee, not be shrugged off.
    ///
    ///      An `allowanceValue` of zero is a normal, supported request: it removes the store's
    ///      ability to collect. It does not revoke a recurring authorization - only the payer
    ///      calling P2FluxRecurring.revoke does that.
    function sponsorPermit(
        PermitSponsorship calldata sponsorship,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS,
        uint8 feeV,
        bytes32 feeR,
        bytes32 feeS
    ) external nonReentrant {
        if (msg.sender != relayer) revert NotRelayer();
        if (sponsorship.payer == address(0) || sponsorship.spender == address(0)) revert ZeroAddress();
        if (sponsorship.networkFee > MAX_SPONSOR_FEE_HARD_CAP) revert NetworkFeeTooHigh();

        bytes32 nonce = authorizationNonce(sponsorship);

        // Checks, effects, interactions. The token enforces the same thing independently; this
        // makes the refusal explicit and keeps the mirror honest even under a token that did not.
        if (settledSponsorships[nonce]) revert SponsorshipAlreadySettled(nonce);
        settledSponsorships[nonce] = true;

        /* See P2FluxSponsoredSplitter: the invariant is that this call leaves no more than it found,
         * not that the balance is zero. A contract with no sweep that asserted zero could be
         * disabled permanently by anyone willing to send it one base unit. */
        uint256 heldBefore = IERC20(supportedToken).balanceOf(address(this));

        // 1. The customer pays for the gas this transaction is spending, before it is spent on
        //    their behalf. `to == address(this)` is checked by the token itself.
        if (sponsorship.networkFee > 0) {
            ISponsorToken(supportedToken).receiveWithAuthorization(
                sponsorship.payer,
                address(this),
                sponsorship.networkFee,
                0,
                sponsorship.validBefore,
                nonce,
                feeV,
                feeR,
                feeS
            );
            IERC20(supportedToken).safeTransfer(gasTreasury, sponsorship.networkFee);
        }

        // 2. The operation the customer asked for. A failure here reverts step 1 with it.
        ISponsorToken(supportedToken).permit(
            sponsorship.payer,
            sponsorship.spender,
            sponsorship.allowanceValue,
            sponsorship.allowanceDeadline,
            permitV,
            permitR,
            permitS
        );

        if (IERC20(supportedToken).balanceOf(address(this)) != heldBefore) revert ResidualBalance();

        emit SponsorshipSettled(
            sponsorship.payer,
            OPERATION_PERMIT,
            sponsorship.spender,
            sponsorship.allowanceValue,
            sponsorship.networkFee,
            nonce
        );
    }
}
