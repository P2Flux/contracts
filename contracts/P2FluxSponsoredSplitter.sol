// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The EIP-3009 surface this contract needs. USDC (FiatToken v2) implements it.
interface IERC3009 {
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

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @title P2FluxSponsoredSplitter
/// @notice One-time payments for a buyer who holds the payment token and no native gas currency.
///
/// @dev The buyer signs; the relayer sends. One signature authorizes the token to move exactly
///      `amount + networkFee + GAS_SERVICE_FEE` into this contract, and this contract splits it in
///      the same transaction. Nothing is sponsored on credit: the transfer that pays the relayer
///      back for the gas it is spending happens inside the transaction that spends it, so a
///      transaction that fails costs the relayer its gas and moves no money at all.
///
///      What the buyer signs is the token's own `ReceiveWithAuthorization`. Its EIP-712 domain binds
///      the chain and the token; its `nonce` is derived here from every remaining term - this
///      contract, payer, recipient, amount, reference, quoted network fee, service fee, expiry - so
///      changing any of them makes the signature unusable rather than merely wrong. The token
///      enforces single use of that nonce, and `validBefore` is the quote's expiry.
///
///      Not upgradeable, no owner, no pause, no withdrawal path. The contract's token balance is
///      zero before and after every call: it holds value only between two statements of one
///      transaction, and `MAX_NETWORK_FEE_HARD_CAP` bounds what any signature can ever move beyond
///      the payment itself.
contract P2FluxSponsoredSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice P2Flux's profit fee on a one-time payment, in basis points. Same as P2FluxSplitter.
    uint16 public constant ONE_TIME_BPS = 100;

    /// @dev Must match `PAYMENT_DOMAIN` in P2FluxSplitter: the two contracts compute the same
    ///      payment id for the same terms, so one recovery routine reads both. They never share a
    ///      settlement: an intent names the contract it may be paid through, and each contract has
    ///      its own `processedPayments`.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    /// @dev Domain tag of the buyer's authorization nonce. Distinct from every other P2Flux domain,
    ///      so a signature made for one operation cannot be replayed into another.
    bytes32 public constant SPONSOR_PAY_DOMAIN = keccak256("P2FLUX_SPONSORED_PAYMENT_V1");

    /// @notice The only token this deployment settles.
    address public immutable supportedToken;

    /// @notice Receives the profit fee and the gas-service fee. P2Flux revenue.
    address public immutable feeWallet;

    /// @notice Receives the quoted network fee. Compensates native gas; not revenue.
    address public immutable gasTreasury;

    /// @notice The only address that may execute a sponsored payment.
    address public immutable relayer;

    /// @notice Flat P2Flux fee for the gas service, in token base units. 0.10 USDC at 6 decimals.
    uint256 public immutable GAS_SERVICE_FEE;

    /// @notice Ceiling on the quoted network fee a single payment may carry, in token base units.
    /// @dev Defence in depth beneath the buyer's own signed amount: whatever a quote says and
    ///      whatever the relayer submits, no signature can move more than this on top of the price.
    uint256 public immutable MAX_NETWORK_FEE_HARD_CAP;

    /// @notice Settled intents. The only storage this contract keeps.
    mapping(bytes32 => bool) public processedPayments;

    event SponsoredPaid(
        bytes32 indexed ref,
        address indexed recipient,
        address indexed payer,
        uint256 net,
        uint256 fee,
        uint256 networkFee,
        uint256 serviceFee
    );

    /// @dev Same signature as P2FluxSplitter's, so one log filter locates a settlement in either.
    event PaymentSettled(bytes32 indexed paymentId);

    error ZeroAddress();
    error ZeroAmount();
    error AmountTooSmall();
    error NotRelayer();
    error NetworkFeeTooHigh();
    error PaymentAlreadyProcessed(bytes32 paymentId);
    error ResidualBalance();

    constructor(
        address _supportedToken,
        address _feeWallet,
        address _gasTreasury,
        address _relayer,
        uint256 _gasServiceFee,
        uint256 _maxNetworkFeeHardCap
    ) {
        if (
            _supportedToken == address(0) || _feeWallet == address(0) || _gasTreasury == address(0)
                || _relayer == address(0)
        ) revert ZeroAddress();
        // A token address with no code would make every transfer a silent no-op.
        if (_supportedToken.code.length == 0) revert ZeroAddress();

        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
        gasTreasury = _gasTreasury;
        relayer = _relayer;
        GAS_SERVICE_FEE = _gasServiceFee;
        MAX_NETWORK_FEE_HARD_CAP = _maxNetworkFeeHardCap;
    }

    /// @notice The settlement id for these terms, identical to P2FluxSplitter's.
    function paymentId(address token, address recipient, uint256 amount, bytes32 ref)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PAYMENT_DOMAIN, token, recipient, amount, ref));
    }

    /// @notice Has this intent already settled here?
    function isPaymentProcessed(address token, address recipient, uint256 amount, bytes32 ref)
        external
        view
        returns (bool)
    {
        return processedPayments[paymentId(token, recipient, amount, ref)];
    }

    /// @notice The exact terms one sponsored payment settles. Grouped so the whole set travels as
    ///         one value: it is what the buyer signs, what the relayer submits, and what the nonce
    ///         is derived from, and splitting it into loose arguments is how those three drift apart.
    /// @param payer The wallet the token is pulled from. Must be the signer.
    /// @param recipient Seller wallet. Receives the amount minus the profit fee.
    /// @param amount The price, in token base units, before fees.
    /// @param ref Opaque merchant reference. P2Flux never learns what it stands for.
    /// @param networkFee The quoted network fee the buyer accepted. Not a gas measurement.
    /// @param validBefore Quote expiry, enforced by the token.
    struct SponsoredPayment {
        address payer;
        address recipient;
        uint256 amount;
        bytes32 ref;
        uint256 networkFee;
        uint256 validBefore;
    }

    /// @notice The token authorization nonce these payment terms produce.
    /// @dev Public so the API and the checkout derive the same value the contract will, and so a
    ///      wallet can be shown exactly what it is signing. Every financially relevant term is in
    ///      here; the token's own domain adds the chain and the token itself.
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
                GAS_SERVICE_FEE,
                p.validBefore
            )
        );
    }

    /// @notice What the buyer's wallet will be debited for these terms.
    function totalDebit(uint256 amount, uint256 networkFee) public view returns (uint256) {
        return amount + networkFee + GAS_SERVICE_FEE;
    }

    /// @notice Settle a one-time payment funded entirely by the buyer's signature.
    ///
    /// @dev The relayer is the only caller. Not because anyone else could steal anything - the
    ///      signature fixes every destination - but because a stranger front-running our own
    ///      transaction would make it revert with `PaymentAlreadyProcessed` and waste the gas we
    ///      just spent, which is exactly the loss this design exists to prevent.
    ///
    function payWithAuthorization(SponsoredPayment calldata p, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        if (msg.sender != relayer) revert NotRelayer();
        if (p.recipient == address(0) || p.payer == address(0)) revert ZeroAddress();
        if (p.amount == 0) revert ZeroAmount();
        if (p.networkFee > MAX_NETWORK_FEE_HARD_CAP) revert NetworkFeeTooHigh();

        uint256 fee = (p.amount * ONE_TIME_BPS) / 10_000;
        // The seller must be left with something; a price that cannot cover its own fee is refused
        // before anything moves rather than paying the merchant zero.
        if (p.amount <= fee) revert AmountTooSmall();

        // Checks, effects, interactions. A revert below rolls this back with everything else, so a
        // failed attempt leaves the intent payable and the buyer's authorization unconsumed.
        bytes32 id = paymentId(supportedToken, p.recipient, p.amount, p.ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        // The buyer's one signature. The token verifies it against its own EIP-712 domain, checks
        // `to == msg.sender == this`, enforces the deadline, and burns the nonce.
        IERC3009(supportedToken).receiveWithAuthorization(
            p.payer,
            address(this),
            p.amount + p.networkFee + GAS_SERVICE_FEE,
            0,
            p.validBefore,
            authorizationNonce(p),
            v,
            r,
            s
        );

        IERC20 token = IERC20(supportedToken);
        token.safeTransfer(p.recipient, p.amount - fee);
        // Profit fee and service fee are both P2Flux revenue and share a destination; the network
        // fee is a cost recovery and goes somewhere else, so the two are never merged.
        uint256 revenue = fee + GAS_SERVICE_FEE;
        if (revenue > 0) token.safeTransfer(feeWallet, revenue);
        if (p.networkFee > 0) token.safeTransfer(gasTreasury, p.networkFee);

        // Custody lasted three statements. Anything left would mean the arithmetic above drifted
        // from the amount pulled, and this contract has no way to ever move it out again.
        if (token.balanceOf(address(this)) != 0) revert ResidualBalance();

        emit SponsoredPaid(p.ref, p.recipient, p.payer, p.amount - fee, fee, p.networkFee, GAS_SERVICE_FEE);
        emit PaymentSettled(id);
    }
}
