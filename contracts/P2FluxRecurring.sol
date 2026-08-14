// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title P2FluxRecurring
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
contract P2FluxRecurring is EIP712, ReentrancyGuard {
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

    /// @notice P2Flux profit, deducted from the signed amount. Goes to `feeWallet` and nowhere else.
    /// @dev Never funds gas. The gas side of the business is `NETWORK_FEE` plus the reimbursement,
    ///      and both go to `gasTreasury`, so revenue and network costs stay separately accountable.
    uint16 public constant FEE_BPS = 200;

    /// @notice Flat network/infrastructure fee per successful charge, also deducted from the signed
    ///         amount: the merchant funds it out of proceeds, the customer is not debited for it.
    /// @dev Denominated in 6-decimal USDC units, which is safe because `supportedToken` pins the
    ///      token at deployment. Builds the reserve that absorbs USDC->ETH rebalancing spread, gas
    ///      estimation variance and the occasional charge that reverts after a clean simulation.
    uint256 public constant NETWORK_FEE = 0.10e6;

    /// @notice Protocol-level hard ceiling on the per-charge gas reimbursement, in token base units.
    /// @dev Defence in depth against a compromised relayer key combined with an API mistake that
    ///      signs an absurd `maxGasReimbursement`: whatever was signed and whatever the relayer
    ///      asks, no charge can debit more than this on top of the subscription amount.
    ///      Denominated in 6-decimal USDC units (see `supportedToken`): 0.05 USDC, ~20x the worst
    ///      per-charge gas cost measured on Base.
    uint256 public constant GAS_REIMBURSEMENT_HARD_CAP = 0.05e6;

    /// @notice Receives P2Flux profit. Immutable on purpose: no admin can redirect the fee stream,
    ///         and a compromised admin key can never gain a path to customer funds through it.
    address public immutable feeWallet;

    /// @notice Receives the network fee and the gas reimbursement. Separate from `feeWallet` so
    ///         revenue and network costs can be accounted apart, and separate from `relayer` so the
    ///         hot key that signs transactions never accumulates the treasury.
    address public immutable gasTreasury;

    /// @notice The only ERC-20 this deployment charges. Immutable, and enforced in `charge`.
    /// @dev `NETWORK_FEE` and `GAS_REIMBURSEMENT_HARD_CAP` are fixed quantities of a 6-decimal
    ///      token. That is only meaningful if the token cannot vary, so it is pinned here rather
    ///      than left to off-chain policy: on an 18-decimal token a 0.10e6 fee would be dust, on a
    ///      2-decimal one it would be a thousand units. One deployment per chain, bound to that
    ///      chain's official USDC. Multi-token support is future work and needs decimals handling,
    ///      not a wider check here.
    address public immutable supportedToken;

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

    error ZeroAddress();
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

    constructor(address _admin, address _relayer, address _feeWallet, address _gasTreasury, address _supportedToken)
        EIP712("P2FluxRecurring", "1")
    {
        if (
            _admin == address(0) || _relayer == address(0) || _feeWallet == address(0)
                || _gasTreasury == address(0) || _supportedToken == address(0)
        ) revert ZeroAddress();
        admin = _admin;
        relayer = _relayer;
        feeWallet = _feeWallet;
        gasTreasury = _gasTreasury;
        supportedToken = _supportedToken;
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

    /// @notice Current period index for an authorization. Reverts before start and after end.
    function currentPeriod(RecurringAuthorization calldata auth) public view returns (uint256) {
        if (auth.period == 0) revert ZeroPeriod();
        if (block.timestamp < auth.start) revert NotStarted();
        if (auth.end != 0 && block.timestamp >= auth.end) revert Expired();
        return (block.timestamp - auth.start) / auth.period;
    }

    /// @notice Whether `charge` would currently pass its own preconditions (signature not checked).
    function isChargeable(RecurringAuthorization calldata auth) external view returns (bool) {
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
    ///      deliberately low, per the audited gas model); any other caller gets zero regardless of
    ///      what they pass. Always bounded by the customer-signed cap.
    function charge(RecurringAuthorization calldata auth, bytes calldata signature, uint256 gasReimbursement)
        external
        nonReentrant
    {
        if (auth.recipient == address(0)) revert ZeroAddress();
        if (auth.token != supportedToken) revert TokenNotSupported();
        if (auth.amount == 0) revert ZeroAmount();
        if (auth.period == 0) revert ZeroPeriod();
        if (auth.end != 0 && auth.end <= auth.start) revert InvalidEnd();
        if (block.timestamp < auth.start) revert NotStarted();
        if (auth.end != 0 && block.timestamp >= auth.end) revert Expired();

        bytes32 id = subscriptionId(auth);
        if (revoked[id]) revert Revoked();

        // The customer's signature over these exact terms, verified here, every time.
        // SignatureChecker also accepts ERC-1271 signatures from contract wallets.
        if (!SignatureChecker.isValidSignatureNow(auth.payer, id, signature)) revert InvalidSignature();

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
        uint256 fee = (auth.amount * FEE_BPS) / 10_000;
        if (auth.amount <= fee + NETWORK_FEE) revert AmountTooSmall();
        uint256 net = auth.amount - fee - NETWORK_FEE;

        // Effects before interactions. A revert below unwinds this write.
        lastChargedPeriodPlusOne[id] = periodIndex + 1;

        // Straight from payer to each destination: this contract never holds the funds. The network
        // fee and the reimbursement travel together - same destination, so one transfer rather than
        // two identical ones.
        IERC20 token = IERC20(auth.token);
        token.safeTransferFrom(auth.payer, auth.recipient, net);
        if (fee > 0) token.safeTransferFrom(auth.payer, feeWallet, fee);
        token.safeTransferFrom(auth.payer, gasTreasury, NETWORK_FEE + reimbursement);

        emit SubscriptionCharged(id, auth.payer, auth.recipient, periodIndex, net, fee, NETWORK_FEE, reimbursement);
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
