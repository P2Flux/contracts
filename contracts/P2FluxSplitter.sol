// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title P2FluxSplitter
/// @notice Splits a one-time USDC payment between a recipient and the P2Flux fee wallet, in a single
///         transaction, funded by the buyer's own allowance. The buyer pays their own gas.
///
/// @dev Holds no balance between calls. No withdrawals, no custody, no upgrade path, and - since V1 -
///      no privileged role of any kind: there is no admin, no relayer, and nothing mutable except the
///      record of which intents have settled. The only function that moves value is `pay`, and it can
///      only ever move the buyer's own tokens to the recipient and the fee wallet.
///
///      One deployment per chain, bound at construction to that chain's official USDC.
contract P2FluxSplitter {
    /// @notice P2Flux's share of a one-time payment, in basis points. 1%.
    uint16 public constant ONE_TIME_BPS = 100;

    /// @notice Domain separator for one-time payment ids.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    /// @notice The only ERC-20 this deployment settles. Immutable, and enforced in `pay`.
    ///
    /// @dev Pinning the token is what makes a settlement mean something. Before this was enforced, a
    ///      caller could pass any address as `token`: a call to an address with no code returns
    ///      success with empty returndata, which the ERC-20 convention reads as "transfer succeeded",
    ///      so `pay(address(0), …)` moved nothing and still emitted a genuine `Paid` from this
    ///      contract. Anything trusting that event as proof of payment could be handed unlimited
    ///      forged settlements. The token is now fixed, and verified to be a contract at deployment.
    address public immutable supportedToken;

    /// @notice Receives the P2Flux fee. Receive-only, and immutable: no key can redirect the fee
    ///         stream, and a payment verified today still verifies tomorrow.
    address public immutable feeWallet;

    /// @notice One-time payment intents that have already been settled.
    /// @dev The only persistent state this contract keeps, and the only thing it stores about a
    ///      payment at all: a bare `true` per settled intent - no amounts, no addresses, no buyer,
    ///      nothing that says what was bought.
    mapping(bytes32 => bool) public processedPayments;

    /// @dev `token` is emitted so a receipt is self-describing and cannot be misread as a settlement
    ///      in some other asset. It is always `supportedToken`; it is in the event because a verifier
    ///      should never have to assume that.
    event Paid(bytes32 indexed ref, address indexed recipient, address indexed token, uint256 net, uint256 fee);
    event PaymentSettled(bytes32 indexed paymentId);

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported();
    error NotAContract();
    error TransferFailed();
    error PaymentAlreadyProcessed(bytes32 paymentId);

    constructor(address _supportedToken, address _feeWallet) {
        if (_supportedToken == address(0) || _feeWallet == address(0)) revert ZeroAddress();
        // A token with no code would make every transfer trivially "succeed" - the exact failure this
        // contract is now built to refuse. Refuse it once, here, rather than on every payment.
        if (_supportedToken.code.length == 0) revert NotAContract();
        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
    }

    // --- one-time ----------------------------------------------------------

    /// @notice Identifier of a one-time payment intent, over its complete immutable terms.
    ///
    /// @dev `token` stays part of the identity even though only one token is accepted. It costs
    ///      nothing, it keeps the id honest about what was agreed, and it means an id computed
    ///      off-chain is only ever satisfied by a settlement in that exact asset. Changing the token,
    ///      the recipient or the amount produces a different id, so an attacker cannot consume a
    ///      payment except by actually making it.
    function paymentId(address token, address recipient, uint256 amount, bytes32 ref)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PAYMENT_DOMAIN, token, recipient, amount, ref));
    }

    /// @notice Whether a one-time payment intent has already been settled.
    function isPaymentProcessed(address token, address recipient, uint256 amount, bytes32 ref)
        external
        view
        returns (bool)
    {
        return processedPayments[paymentId(token, recipient, amount, ref)];
    }

    /// @notice Pay `amount`, split 99/1, funded by msg.sender's existing allowance. Buyer pays gas.
    ///
    /// @dev Each intent settles exactly once. The guard is scoped to the intent, not to the buyer or
    ///      the seller: the same person may buy the same thing from the same seller for the same
    ///      amount as often as they like, because every order gets a fresh reference and therefore a
    ///      fresh id. Only replaying one specific intent fails.
    ///
    /// @param ref Opaque reference. P2Flux never learns what it stands for.
    function pay(address token, address recipient, uint256 amount, bytes32 ref) public {
        if (token != supportedToken) revert TokenNotSupported();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Checks, effects, then interactions. If any transfer below reverts, this write is rolled
        // back with it, so a failed payment leaves the intent payable.
        bytes32 id = paymentId(token, recipient, amount, ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        uint256 fee = (amount * ONE_TIME_BPS) / 10_000;

        // Straight from buyer to each destination: the contract never holds the funds.
        _transferFrom(msg.sender, recipient, amount - fee);
        if (fee > 0) _transferFrom(msg.sender, feeWallet, fee);

        emit Paid(ref, recipient, token, amount - fee, fee);
        emit PaymentSettled(id);
    }

    /// @notice Same as `pay`, but consumes an EIP-2612 permit so the buyer needs only one transaction.
    /// @dev Shares `pay`'s replay guard exactly - there is one settlement path, not two.
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
        // Swallow failure: a griefer can front-run the permit, which would otherwise revert the
        // payment. If the allowance really is missing, `pay` reverts anyway. The permit is sent to
        // the supported token only - `pay` refuses anything else before any value moves.
        if (token != supportedToken) revert TokenNotSupported();
        try IERC20(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        pay(token, recipient, amount, ref);
    }

    // --- internals ---------------------------------------------------------

    /// @dev Always the supported token, so there is no caller-controlled address to call into. USDC
    ///      returns a bool; a token that returns nothing is still accepted, which is the usual ERC-20
    ///      allowance, but only because the constructor already proved this address holds code.
    function _transferFrom(address from, address to, uint256 value) private {
        (bool ok, bytes memory data) =
            supportedToken.call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
