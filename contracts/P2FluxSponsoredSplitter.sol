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
///      `amount + networkFee` into this contract, and this contract splits it in the same
///      transaction. Nothing is sponsored on credit: the transfer that pays the relayer back for
///      the gas it is spending happens inside the transaction that spends it, so a transaction that
///      fails costs the relayer its gas and moves no money at all.
///
///      Who funds what is the same rule the recurring contract follows, and it is the whole of the
///      pricing model: P2Flux's fees come OUT of the amount, so the merchant funds them, and the
///      buyer is debited the price plus the network cost of moving it and nothing else. A buyer who
///      pays natively is debited the price and pays their own gas; a buyer who pays in the token is
///      debited the price and a quoted amount for the gas someone else spends. Neither of them ever
///      pays a P2Flux fee on top of the price.
///
///      What the buyer signs is the token's own `ReceiveWithAuthorization`. Its EIP-712 domain binds
///      the chain and the token; its `nonce` is derived here from every remaining term - this
///      contract, payer, recipient, amount, reference, quoted network fee, service fee, expiry - so
///      changing any of them makes the signature unusable rather than merely wrong. The token
///      enforces single use of that nonce, and `validBefore` is the quote's expiry.
///
///      Not upgradeable, no owner, no pause, no withdrawal path. The contract holds value only
///      between two statements of one transaction and leaves no more than it found, so anything sent
///      here by anyone else is inert rather than reachable - and cannot stop the contract working.
///      `MAX_NETWORK_FEE_HARD_CAP` bounds what any signature can ever move beyond the payment itself.
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

    /// @notice Receives the profit fee, and nothing else. P2Flux revenue.
    address public immutable feeWallet;

    /// @notice Receives the fixed network fee and the buyer's quoted network fee. Compensates
    ///         native gas; not revenue, and never mixed with it.
    address public immutable gasTreasury;

    /// @notice The only address that may execute a sponsored payment.
    address public immutable relayer;

    /// @notice The fixed network fee, in token base units. 0.10 USDC at 6 decimals.
    /// @dev Merchant-funded, out of the amount, and paid to `gasTreasury` - the same quantity, the
    ///      same destination and the same reasoning as `NETWORK_FEE` on the recurring contract. It
    ///      is the gas side of the business, so it must not reach `feeWallet`: revenue and network
    ///      costs stay separately accountable, and neither subsidises the other.
    uint256 public immutable FIXED_NETWORK_FEE;

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
        uint256 fixedNetworkFee
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
        uint256 _fixedNetworkFee,
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
        FIXED_NETWORK_FEE = _fixedNetworkFee;
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
                FIXED_NETWORK_FEE,
                p.validBefore
            )
        );
    }

    /// @notice What the buyer's wallet will be debited for these terms: the price, plus the network
    ///         cost of moving it. P2Flux's fees are not here - the merchant funds those.
    function totalDebit(uint256 amount, uint256 networkFee) public pure returns (uint256) {
        return amount + networkFee;
    }

    /// @notice The smallest amount these terms can settle: anything at or below this leaves the
    ///         merchant nothing, and is refused rather than paid.
    /// @dev Derived, never configured. `fee` rounds down, so the true boundary is the first amount
    ///      whose `amount - fee - FIXED_NETWORK_FEE` is positive.
    function minimumAmount() external view returns (uint256) {
        uint256 amount = FIXED_NETWORK_FEE + 1;
        while (amount <= (amount * ONE_TIME_BPS) / 10_000 + FIXED_NETWORK_FEE) {
            amount++;
        }
        return amount;
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

        /* Both fees come out of the amount, so the merchant funds them and the buyer is debited the
         * price plus the network fee and nothing more. Rounding on the profit fee favours the
         * merchant. The seller must be left with something: an amount that cannot cover both fees
         * is refused outright rather than silently paying the merchant zero or reverting inside the
         * token on an underflow. Same rule, same order, as P2FluxRecurring. */
        uint256 fee = (p.amount * ONE_TIME_BPS) / 10_000;
        if (p.amount <= fee + FIXED_NETWORK_FEE) revert AmountTooSmall();

        // Checks, effects, interactions. A revert below rolls this back with everything else, so a
        // failed attempt leaves the intent payable and the buyer's authorization unconsumed.
        bytes32 id = paymentId(supportedToken, p.recipient, p.amount, p.ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        /* What this contract held before it was asked to do anything.
         *
         * Anyone may transfer tokens to any address, so a contract that asserted a zero balance
         * would be one cheap dust transfer away from refusing every payment forever - and with no
         * owner, no pause and no sweep, forever means forever. What must hold is that this call
         * leaves no MORE than it found: donated dust sits inert instead of taking the product down. */
        uint256 heldBefore = IERC20(supportedToken).balanceOf(address(this));

        // The buyer's one signature. The token verifies it against its own EIP-712 domain, checks
        // `to == msg.sender == this`, enforces the deadline, and burns the nonce.
        IERC3009(supportedToken).receiveWithAuthorization(
            p.payer,
            address(this),
            p.amount + p.networkFee,
            0,
            p.validBefore,
            authorizationNonce(p),
            v,
            r,
            s
        );

        IERC20 token = IERC20(supportedToken);
        token.safeTransfer(p.recipient, p.amount - fee - FIXED_NETWORK_FEE);
        // The profit fee is revenue and goes to the fee wallet. The fixed network fee and the
        // buyer's quoted network fee are both the gas side of the business and share a destination,
        // so they travel together - one transfer rather than two identical ones, exactly as the
        // recurring contract sends `NETWORK_FEE + reimbursement`.
        if (fee > 0) token.safeTransfer(feeWallet, fee);
        token.safeTransfer(gasTreasury, p.networkFee + FIXED_NETWORK_FEE);

        // Custody lasted three statements. Anything left OVER would mean the arithmetic above
        // drifted from the amount pulled, and this contract has no way to ever move it out again.
        if (token.balanceOf(address(this)) != heldBefore) revert ResidualBalance();

        emit SponsoredPaid(
            p.ref, p.recipient, p.payer, p.amount - fee - FIXED_NETWORK_FEE, fee, p.networkFee, FIXED_NETWORK_FEE
        );
        emit PaymentSettled(id);
    }
}
