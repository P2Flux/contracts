// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP7702Utils} from "@openzeppelin/contracts/account/utils/EIP7702Utils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P2FluxV2Base} from "./P2FluxV2Base.sol";
import {P2FluxFeeRegistry} from "./P2FluxFeeRegistry.sol";

/// @title P2FluxRecurringV2
/// @notice v2 of P2FluxRecurring. Identical authorization, signature and period logic; only the
///         fee terms changed: the percentage and fixed fee come from the registry (recurring rate,
///         partner rate if the recipient is listed), and the gas cap is a per-chain constructor value.
///         The EIP-712 domain version is "2", so a v1 signature can never charge here.
///
/// @notice Wallet-independent recurring USDC payments. The customer grants this contract a normal
///         ERC-20 allowance once and signs the exact recurring terms once (EIP-712); afterwards a
///         relayer executes each period's charge with no customer interaction, until revoked.
///
/// @dev Two independent authorization layers, by design:
///        1. the ERC-20 allowance - lets this contract move the token at all;
///        2. the signed RecurringAuthorization - the ONLY thing that decides where funds may go,
///           how much, and how often.
///      The allowance may be unlimited; the authorization never is. There is deliberately no
///      function in this contract that can move tokens except `charge`, and `charge` can only
///      produce exactly the payment the customer signed.
///
///      Not upgradeable, not proxied. No delegatecall, no arbitrary external calls, no owner
///      withdrawal path, no custody: the contract's own token balance stays zero.
contract P2FluxRecurringV2 is P2FluxV2Base, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The exact recurring terms the customer signs. Nothing else is ever charged.
    /// @param payer   The customer wallet tokens are pulled from. Must be the signer.
    /// @param recipient Seller wallet. Receives amount minus the profit fee and the network fee.
    /// @param token   ERC-20 being charged. Must equal `supportedToken`.
    /// @param amount  The commercial price, charged per period, before fees. Token base units.
    /// @param period  Billing period in seconds.
    /// @param start   First period begins here (unix seconds).
    /// @param end     0 = no expiration; otherwise charging stops at this timestamp.
    /// @param salt    Distinguishes otherwise-identical subscriptions.
    /// @param maxGasReimbursement Cap on the extra debit that may reimburse relayer gas, per charge.
    struct RecurringAuthorization {
        address payer;
        address recipient;
        address token;
        uint256 amount;
        uint48 period;
        uint48 start;
        uint48 end;
        bytes32 salt;
        uint256 maxGasReimbursement;
    }

    bytes32 public constant AUTHORIZATION_TYPEHASH = keccak256(
        "RecurringAuthorization(address payer,address recipient,address token,uint256 amount,uint48 period,uint48 start,uint48 end,bytes32 salt,uint256 maxGasReimbursement)"
    );

    /// @notice Per-chain ceiling on the per-charge gas reimbursement, in token base units. Whatever
    ///         was signed and whatever the relayer asks, no charge debits more than this on top.
    uint256 public immutable GAS_REIMBURSEMENT_HARD_CAP;

    /// @dev Trailing magic that marks an ERC-6492 wrapped signature. Refused, never executed.
    bytes32 private constant ERC6492_MAGIC = 0x6492649264926492649264926492649264926492649264926492649264926492;

    /// @notice Receives the fixed fee and the gas reimbursement. Never the percentage fee.
    address public immutable gasTreasury;

    /// @notice Cold key. Rotates the relayer, nothing else. Touches no funds.
    address public immutable admin;

    /// @notice The only caller that may take a gas reimbursement. Anyone may still call `charge`
    ///         with reimbursement zero - execution is public, extracting value is not.
    /// @dev Rotatable because this contract's address is embedded in every customer signature and
    ///      allowance: redeploying would invalidate all of them, so a hot-key compromise must be
    ///      recoverable in place.
    address public relayer;

    /// @dev subscriptionId => index of the last successfully charged period, PLUS ONE.
    ///      Zero means "never charged", distinct from "charged period 0" (stored as 1).
    mapping(bytes32 => uint256) public lastChargedPeriodPlusOne;

    /// @dev subscriptionId => permanently revoked by the payer.
    mapping(bytes32 => bool) public revoked;

    /// @dev Every economic component of a charge, so a receipt is self-describing:
    ///      `net + fee + networkFee == amount`, and the payer was debited
    ///      `amount + gasReimbursement`. Three indexed fields is the EVM maximum, so the money
    ///      fields stay unindexed.
    event SubscriptionCharged(
        bytes32 indexed subscriptionId,
        address indexed payer,
        address indexed recipient,
        uint256 periodIndex,
        uint256 net,
        uint256 fee,
        uint256 networkFee,
        uint256 gasReimbursement
    );
    event SubscriptionRevoked(bytes32 indexed subscriptionId, address indexed payer);
    event RelayerChanged(address relayer);

    error ZeroAmount();
    error ZeroPeriod();
    error InvalidEnd();
    error NotAdmin();
    error NotStarted();
    error Expired();
    error Revoked();
    error AlreadyRevoked();
    error NotPayer();
    error InvalidSignature();
    error AlreadyChargedThisPeriod();
    error GasReimbursementTooHigh();
    error TokenNotSupported();
    error AmountTooSmall();

    error CapTooHigh();

    constructor(
        address _admin,
        address _relayer,
        address _feeWallet,
        address _gasTreasury,
        address _supportedToken,
        address _registry,
        uint256 _gasReimbursementHardCap
    ) P2FluxV2Base(_supportedToken, _feeWallet, _registry) EIP712("P2FluxRecurring", "2") {
        if (_admin == address(0) || _relayer == address(0) || _gasTreasury == address(0)) revert ZeroAddress();
        if (_gasReimbursementHardCap > 1e6) revert CapTooHigh(); // never more than 1 USDC of gas
        admin = _admin;
        relayer = _relayer;
        gasTreasury = _gasTreasury;
        GAS_REIMBURSEMENT_HARD_CAP = _gasReimbursementHardCap;
    }

    // --- admin (rotation only; no funds) ------------------------------------

    function setRelayer(address _relayer) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
        emit RelayerChanged(_relayer);
    }

    // --- identity -----------------------------------------------------------

    /// @notice The EIP-712 digest of the authorization. Doubles as the subscription id: it commits
    ///         to every term plus this chain and this contract, so a signature can never be replayed
    ///         elsewhere, and different salts yield different subscriptions.
    function subscriptionId(RecurringAuthorization calldata auth) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    AUTHORIZATION_TYPEHASH,
                    auth.payer,
                    auth.recipient,
                    auth.token,
                    auth.amount,
                    auth.period,
                    auth.start,
                    auth.end,
                    auth.salt,
                    auth.maxGasReimbursement
                )
            )
        );
    }

    /// @notice Whether `signature` authorizes `auth` right now, by the exact rule `charge` applies.
    /// @dev Exposed so off-chain setup validates through this contract rather than a reimplementation
    ///      of it. A gate that is more permissive than the chain accepts subscriptions that can never
    ///      be charged, which is precisely the failure this function exists to prevent.
    ///
    ///      "Right now" is deliberate: for a contract wallet the answer can change - see `_isAuthorized`.
    function isValidAuthorization(RecurringAuthorization calldata auth, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return _isAuthorized(auth.payer, subscriptionId(auth), signature);
    }

    /// @notice Current period index for an authorization. Reverts before start and after end.
    function currentPeriod(RecurringAuthorization calldata auth) public view returns (uint256) {
        if (auth.period == 0) revert ZeroPeriod();
        if (block.timestamp < auth.start) revert NotStarted();
        if (auth.end != 0 && block.timestamp >= auth.end) revert Expired();
        return (block.timestamp - auth.start) / auth.period;
    }

    /// @notice Whether `charge` would currently pass its own preconditions (signature not checked).
    /// @dev Also false when the amount no longer covers the fees at the CURRENT rates, counted as a
    ///      relayer charge (with the fixed fee): a fee increase can make a small subscription
    ///      unchargeable, and the relayer's scheduler must see that rather than waste gas on reverts.
    function isChargeable(RecurringAuthorization calldata auth) external view returns (bool) {
        if (auth.recipient == address(0) || auth.recipient == address(this)) return false;
        if (auth.token != supportedToken || auth.amount == 0) return false;
        (uint256 fee, uint256 fixedFee) = _fees(P2FluxFeeRegistry.Kind.Recurring, auth.recipient, auth.amount, true);
        if (auth.amount <= fee + fixedFee) return false;
        if (auth.period == 0 || block.timestamp < auth.start) return false;
        if (auth.end != 0 && block.timestamp >= auth.end) return false;
        bytes32 id = subscriptionId(auth);
        if (revoked[id]) return false;
        uint256 periodIndex = (block.timestamp - auth.start) / auth.period;
        return lastChargedPeriodPlusOne[id] < periodIndex + 1;
    }

    // --- charge -------------------------------------------------------------

    /// @notice Execute the current period's charge. Callable by anyone; only the exact signed
    ///         payment can result, and only once per period.
    ///
    /// @dev The period index derives from block.timestamp alone - no caller input selects it.
    ///      Checks-effects-interactions: the period marker is written before any transfer, and a
    ///      failed transfer reverts the marker with it, so a failed charge stays retryable within
    ///      its period. Signature is verified on every charge; the chain is the authority.
    ///
    /// @param gasReimbursement Extra debit, in the charged token, reimbursing the relayer's gas.
    ///      Only honoured when the caller is the authorized relayer (who quotes it off-chain,
    ///      deliberately low, per the reviewed gas model); any other caller gets zero regardless of
    ///      what they pass. Always bounded by the customer-signed cap.
    function charge(RecurringAuthorization calldata auth, bytes calldata signature, uint256 gasReimbursement)
        external
        nonReentrant
    {
        _checkRecipient(auth.recipient);
        if (auth.token != supportedToken) revert TokenNotSupported();
        if (auth.amount == 0) revert ZeroAmount();
        if (auth.period == 0) revert ZeroPeriod();
        if (auth.end != 0 && auth.end <= auth.start) revert InvalidEnd();
        if (block.timestamp < auth.start) revert NotStarted();
        if (auth.end != 0 && block.timestamp >= auth.end) revert Expired();

        bytes32 id = subscriptionId(auth);
        if (revoked[id]) revert Revoked();

        // The customer's authorization over these exact terms, verified here, every time.
        if (!_isAuthorized(auth.payer, id, signature)) revert InvalidSignature();

        uint256 periodIndex = (block.timestamp - auth.start) / auth.period;
        if (lastChargedPeriodPlusOne[id] >= periodIndex + 1) revert AlreadyChargedThisPeriod();

        // Reimbursement: relayer-only, never above what the customer signed, and never above the
        // protocol hard cap regardless of what was signed.
        uint256 reimbursement = msg.sender == relayer ? gasReimbursement : 0;
        if (reimbursement > auth.maxGasReimbursement || reimbursement > GAS_REIMBURSEMENT_HARD_CAP) {
            revert GasReimbursementTooHigh();
        }

        // Both fees come out of the signed amount, so the merchant funds them and the customer is
        // debited `amount + reimbursement` and nothing more. Rounding on the profit fee favours the
        // merchant. The seller must be left with something: an amount that cannot cover both fees
        // is refused outright rather than silently paying the merchant zero.
        // The fixed fee only when P2Flux's relayer runs (and pays the gas for) the charge.
        (uint256 fee, uint256 fixedFee) =
            _fees(P2FluxFeeRegistry.Kind.Recurring, auth.recipient, auth.amount, msg.sender == relayer);
        if (auth.amount <= fee + fixedFee) revert AmountTooSmall();
        uint256 net = auth.amount - fee - fixedFee;

        // Effects before interactions. A revert below unwinds this write.
        lastChargedPeriodPlusOne[id] = periodIndex + 1;

        // Straight from payer to each destination: this contract never holds the funds. The network
        // fee and the reimbursement travel together - same destination, so one transfer rather than
        // two identical ones.
        IERC20 token = IERC20(auth.token);
        token.safeTransferFrom(auth.payer, auth.recipient, net);
        if (fee > 0) token.safeTransferFrom(auth.payer, feeWallet, fee);
        if (fixedFee + reimbursement > 0) token.safeTransferFrom(auth.payer, gasTreasury, fixedFee + reimbursement);

        emit SubscriptionCharged(id, auth.payer, auth.recipient, periodIndex, net, fee, fixedFee, reimbursement);
    }

    // --- signature validation -----------------------------------------------

    /// @dev Who may authorize a charge, by account type. Three cases, deliberately explicit rather
    ///      than one library call, because the library's own rule is wrong for one of them.
    ///
    ///      OpenZeppelin's `SignatureChecker.isValidSignatureNow` branches on `code.length`: any
    ///      account with code is sent to ERC-1271 and its ECDSA signature is never tried. Under
    ///      EIP-7702 an ordinary EOA HAS code - the `0xef0100 || delegate` designator - so a customer
    ///      who upgrades their wallet after subscribing would have every later charge rejected,
    ///      silently killing a working subscription. That is the one case this function fixes.
    ///
    ///      It is fixed narrowly. A genuinely deployed contract wallet is still validated by ERC-1271
    ///      and nothing else: the standard is the authority for those accounts, and an ECDSA
    ///      shortcut around it would be a different, weaker rule than the one they opted into.
    function _isAuthorized(address payer, bytes32 digest, bytes calldata signature) private view returns (bool) {
        // ERC-6492 wrappers are refused before any path. They carry deploy calldata for an account
        // that does not exist yet; this contract will not run it, and an authorization replayed
        // monthly must belong to an account that is already deployed. Rejecting here is clearer than
        // failing later inside a validator that cannot make sense of the wrapper.
        if (_isERC6492(signature)) return false;

        if (payer.code.length == 0) {
            // Plain EOA.
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
            return err == ECDSA.RecoverError.NoError && recovered == payer;
        }

        if (EIP7702Utils.fetchDelegate(payer) != address(0)) {
            /* EIP-7702 delegated EOA. The underlying key still controls this account outright - it
             * can move the funds directly - so honouring its ECDSA signature grants nothing it does
             * not already have. The delegate may also answer ERC-1271, so both are accepted.
             *
             * `fetchDelegate` matches the 0xef0100 designator exactly, and EIP-3541 forbids deployed
             * contract code from beginning with 0xEF, so no contract wallet can land here. */
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
            if (err == ECDSA.RecoverError.NoError && recovered == payer) return true;
            return SignatureChecker.isValidERC1271SignatureNow(payer, digest, signature);
        }

        /* A deployed contract wallet: ERC-1271 only, and re-asked on every charge. The account is
         * the authority on its own signatures, so if it rotates owners, raises a threshold or
         * upgrades such that this authorization no longer validates, charging stops. That is the
         * wallet withdrawing consent, and stopping is the safe reading of it. */
        return SignatureChecker.isValidERC1271SignatureNow(payer, digest, signature);
    }

    /// @dev ERC-6492 marks a wrapped signature with a 32-byte trailing magic value.
    function _isERC6492(bytes calldata signature) private pure returns (bool) {
        return signature.length >= 32 && bytes32(signature[signature.length - 32:]) == ERC6492_MAGIC;
    }

    // --- revocation ---------------------------------------------------------

    /// @notice Permanently cancel one subscription. Only the payer can do this, no P2Flux or seller
    ///         involvement required, and it never touches the token allowance - other subscriptions
    ///         sharing the allowance keep working. For a global stop, the customer sets the token
    ///         allowance for this contract to zero instead.
    function revoke(RecurringAuthorization calldata auth) external {
        if (msg.sender != auth.payer) revert NotPayer();
        bytes32 id = subscriptionId(auth);
        if (revoked[id]) revert AlreadyRevoked();
        revoked[id] = true;
        emit SubscriptionRevoked(id, auth.payer);
    }
}
