// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice EIP-3009 as FiatToken v2.2 implements it. The `bytes` signature overload is the one that
///         also accepts ERC-1271 signatures, so a smart-account agent pays exactly as an EOA does.
interface IERC3009Transfer {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
}

/// @notice The two Permit2 SignatureTransfer structs x402's `upto` proxy takes. Layout must match
///         Uniswap Permit2 exactly: they are ABI-encoded straight through to it.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
}

/// @notice x402's `upto` settlement proxy (x402-foundation/x402, contracts/evm/src/x402UptoPermit2Proxy.sol).
/// @dev It moves up to the signed maximum from the payer to `witness.to` via Permit2, and only for the
///      caller named in `witness.facilitator` - which is this contract.
interface IX402UptoPermit2Proxy {
    struct Witness {
        address to;
        address facilitator;
        uint256 validAfter;
    }

    struct EIP2612Permit {
        uint256 value;
        uint256 deadline;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    function settle(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        Witness calldata witness,
        bytes calldata signature
    ) external;

    function settleWithPermit(
        EIP2612Permit calldata permit2612,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        Witness calldata witness,
        bytes calldata signature
    ) external;
}

/// @title P2FluxX402Vault
/// @notice One per seller, at an address anyone can compute in advance: the `payTo` an agent signs.
///
/// @dev This is what makes x402 settlement through P2Flux as trustless as paying the seller directly.
///      The x402 clients sign a transfer of the price to `payTo` and nothing else - they cannot sign a
///      recipient, a split or a reference. So `payTo` itself carries the seller: the vault's recipient
///      is fixed at deployment and is part of its CREATE2 address, and the only thing it can ever do
///      with its balance is pay that recipient (and the P2Flux fee, bounded by the factory). No key,
///      not even the relayer's, can send a seller's money anywhere else.
contract P2FluxX402Vault {
    using SafeERC20 for IERC20;

    /// @notice The P2FluxX402Splitter that deployed this vault; the only caller of `release`.
    address public immutable factory;

    /// @notice The seller. Every unit that leaves this vault, except the P2Flux fee, goes here.
    address public immutable recipient;

    error NotFactory();

    constructor(address _recipient) {
        factory = msg.sender;
        recipient = _recipient;
    }

    /// @notice Pay `amount` out: `fee` to the fee wallet, the rest to the seller.
    /// @return feePaid What the fee wallet actually received: `fee`, or zero if it could not be paid.
    ///
    /// @dev `token` and `feeWallet` are the factory's own immutables, passed in to keep this contract
    ///      the smallest thing that can hold the rule above.
    ///
    ///      A fee that cannot be paid goes to the seller instead. The fee wallet is immutable, and a
    ///      token issuer can freeze any address: if paying the fee were mandatory, a frozen fee wallet
    ///      would lock every seller's money in every vault, forever, with nobody able to fix it. The
    ///      seller's own transfer stays mandatory - if THAT fails, nothing moves.
    function release(IERC20 token, address feeWallet, uint256 amount, uint256 fee) external returns (uint256 feePaid) {
        if (msg.sender != factory) revert NotFactory();
        if (fee > 0 && _tryTransfer(token, feeWallet, fee)) feePaid = fee;
        token.safeTransfer(recipient, amount - feePaid);
    }

    function _tryTransfer(IERC20 token, address to, uint256 value) private returns (bool) {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, value)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}

/// @title P2FluxX402Splitter
/// @notice Settles x402 payments - AI agents paying for APIs, content and tools - in USDC, with the
///         P2Flux fee split out on-chain in the same transaction.
///
/// @dev The agent uses an unmodified x402 client. It pays `payTo` = this seller's vault
///      (`vaultOf(recipient)`), signing either
///        - `exact`: an EIP-3009 `TransferWithAuthorization` of the price to the vault, or
///        - `upto`:  a Permit2 witness transfer of at most the signed maximum to the vault, which only
///                   this contract (the witness `facilitator`) may execute, for the amount used.
///      The relayer submits it here; this contract pulls the money into the vault and has the vault
///      pay the seller and the fee wallet. The reference is derived from the payer and the signature's
///      own nonce (`refOf`), so every
///      payment is identifiable on-chain without the client knowing anything about P2Flux, and the
///      events are exactly P2FluxSplitter's - one verifier reads all three settlement contracts.
///
///      The relayer chooses one thing: the fee, never above `maxFee(amount)` and never more than
///      half the amount. It cannot choose the recipient, the amount, or where the money goes.
///
///      Not upgradeable, no owner, no pause, no withdrawal path. Neither this contract nor any vault
///      keeps a balance between transactions except what was sent outside a settlement, and that
///      can only ever go to the vault's seller (`flush`).
contract P2FluxX402Splitter is ReentrancyGuard {
    /// @notice P2Flux's fee in basis points: 1%, the same as every one-time payment...
    uint16 public constant FEE_BPS = 100;

    /// @notice ...but never less than this, in token base units (0.003 USDC at launch). Below a
    ///         certain price a 1% fee would not pay for the settlement transaction itself.
    /// @dev Immutable rather than constant so the deploy manifest pins it, like the sponsored
    ///      splitter's FIXED_NETWORK_FEE: a different floor is a different, reviewed deployment.
    uint256 public immutable MIN_FEE;

    /// @dev Same domain as P2FluxSplitter and P2FluxSponsoredSplitter: identical terms produce an
    ///      identical payment id, so one recovery routine reads every settlement contract.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    /// @dev Domain of an x402 payment reference. Keeps x402 references apart from every reference a
    ///      checkout intent can carry, so a payment made here can never be read as one made there.
    bytes32 public constant X402_REF_DOMAIN = keccak256("P2FLUX_X402_REF_V1");

    /// @notice The only token this deployment settles.
    address public immutable supportedToken;

    /// @notice Receives the P2Flux fee, and nothing else.
    address public immutable feeWallet;

    /// @notice The only address that may submit a settlement.
    address public immutable relayer;

    /// @notice x402's canonical `upto` proxy on this chain.
    IX402UptoPermit2Proxy public immutable uptoProxy;

    /// @notice Settled payments. The only storage this contract keeps.
    mapping(bytes32 => bool) public processedPayments;

    /// @dev Same signatures as P2FluxSplitter's events.
    event Paid(bytes32 indexed ref, address indexed recipient, address indexed token, uint256 net, uint256 fee);
    event PaymentSettled(bytes32 indexed paymentId);

    /// @notice A vault's balance that arrived outside a settlement was paid out to its seller.
    event Flushed(address indexed recipient, uint256 net, uint256 fee);

    /// @notice The EIP-3009 authorization the agent signed, minus `to` (always the vault) and the
    ///         signature (passed separately so its length can vary for ERC-1271 wallets).
    struct Authorization {
        address from;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    error ZeroAddress();
    error ZeroAmount();
    error NotAContract();
    error NotRelayer();
    error TokenNotSupported();
    error FeeTooHigh();
    error AmountTooSmall();
    error WrongDestination();
    error UnexpectedAmount();
    error PaymentAlreadyProcessed(bytes32 paymentId);

    constructor(address _supportedToken, address _feeWallet, address _relayer, address _uptoProxy, uint256 _minFee) {
        if (_supportedToken == address(0) || _feeWallet == address(0) || _relayer == address(0)) {
            revert ZeroAddress();
        }
        // A token or proxy with no code would turn every pull into a silent no-op.
        if (_supportedToken.code.length == 0 || _uptoProxy.code.length == 0) revert NotAContract();
        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
        relayer = _relayer;
        uptoProxy = IX402UptoPermit2Proxy(_uptoProxy);
        MIN_FEE = _minFee;
    }

    // --- views ---------------------------------------------------------------

    /// @notice The settlement id for these terms, identical to P2FluxSplitter's.
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

    /// @notice The reference of an x402 payment: the payer and the nonce of the payer's signature.
    ///
    /// @dev The payer is part of it because nonces are the PAYER's: USDC and Permit2 both keep them
    ///      per owner, so two wallets may use the same nonce. With the nonce alone, anyone who saw a
    ///      payment before it settled could pay the same seller the same amount with the same nonce
    ///      from their own wallet, and the original payment would then be refused as already settled.
    ///      Both schemes share this one function, so an `exact` nonce and an `upto` nonce of different
    ///      payers cannot collide either.
    function refOf(address payer, bytes32 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(X402_REF_DOMAIN, payer, nonce));
    }

    /// @notice The most P2Flux may take from a payment of `amount`: 1%, at least `MIN_FEE`.
    function maxFee(uint256 amount) public view returns (uint256) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        return fee > MIN_FEE ? fee : MIN_FEE;
    }

    /// @notice The seller's vault: the `payTo` an agent signs. Deterministic, deployed on first use.
    function vaultOf(address recipient) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(P2FluxX402Vault).creationCode, abi.encode(recipient)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initCodeHash))))
            );
    }

    // --- settlement ----------------------------------------------------------

    /// @notice x402 `exact`: settle an EIP-3009 authorization of `a.value` to `vaultOf(recipient)`.
    /// @dev The token verifies the signature (EOA or ERC-1271), the time window and single use of the
    ///      nonce. The signature names the vault, so submitting it for any other recipient fails there.
    function settleWithAuthorization(address recipient, uint256 fee, Authorization calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (msg.sender != relayer) revert NotRelayer();
        // `a.from` is proven by the token: it verifies the signature against exactly this address.
        Settlement memory s = _open(recipient, a.value, fee, refOf(a.from, a.nonce));
        IERC3009Transfer(supportedToken)
            .transferWithAuthorization(a.from, s.vault, a.value, a.validAfter, a.validBefore, a.nonce, signature);
        _close(s);
    }

    /// @notice x402 `upto`: settle `amount` (at most the signed maximum) through x402's upto proxy.
    function settleUpto(
        address recipient,
        uint256 fee,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        IX402UptoPermit2Proxy.Witness calldata witness,
        bytes calldata signature
    ) external nonReentrant {
        Settlement memory s = _openUpto(recipient, fee, permit, amount, owner, witness);
        uptoProxy.settle(permit, amount, owner, witness, signature);
        _close(s);
    }

    /// @notice As `settleUpto`, for a payer who has not yet approved Permit2: the proxy first applies
    ///         the payer's EIP-2612 permit to Permit2 (x402's eip2612GasSponsoring extension).
    function settleUptoWithPermit(
        address recipient,
        uint256 fee,
        IX402UptoPermit2Proxy.EIP2612Permit calldata permit2612,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        IX402UptoPermit2Proxy.Witness calldata witness,
        bytes calldata signature
    ) external nonReentrant {
        Settlement memory s = _openUpto(recipient, fee, permit, amount, owner, witness);
        uptoProxy.settleWithPermit(permit2612, permit, amount, owner, witness, signature);
        _close(s);
    }

    /// @notice Pay out whatever reached a vault outside a settlement - an authorization someone
    ///         submitted straight to the token, or a plain transfer - to that vault's seller, less 1%.
    /// @dev Anyone may call it: the money can only go to the seller, and nobody - P2Flux included -
    ///      is needed for a seller to receive it.
    function flush(address recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        address vault = _deploy(recipient);
        uint256 balance = IERC20(supportedToken).balanceOf(vault);
        if (balance == 0) revert ZeroAmount();
        uint256 fee = (balance * FEE_BPS) / 10_000;
        uint256 feePaid = P2FluxX402Vault(vault).release(IERC20(supportedToken), feeWallet, balance, fee);
        emit Flushed(recipient, balance - feePaid, feePaid);
    }

    // --- internals -----------------------------------------------------------

    /// @dev One settlement between `_open` and `_close`.
    struct Settlement {
        address vault;
        address recipient;
        uint256 amount;
        uint256 fee;
        bytes32 ref;
        bytes32 id;
        /// What the vault held before the pull: a donation or a stranded payment, left for `flush`.
        uint256 held;
    }

    function _openUpto(
        address recipient,
        uint256 fee,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        IX402UptoPermit2Proxy.Witness calldata witness
    ) private returns (Settlement memory) {
        if (msg.sender != relayer) revert NotRelayer();
        if (permit.permitted.token != supportedToken) revert TokenNotSupported();
        // The proxy pays `witness.to`, and it must be this seller's vault - otherwise the release
        // below would be paid from money that is not this payment's.
        if (witness.to != vaultOf(recipient)) revert WrongDestination();
        // `owner` is proven by Permit2, which verifies the signature against exactly this address.
        return _open(recipient, amount, fee, refOf(owner, bytes32(permit.nonce)));
    }

    /// @dev Checks and effects. A revert anywhere later rolls this back, so a failed settlement
    ///      leaves the payment settleable.
    function _open(address recipient, uint256 amount, uint256 fee, bytes32 ref) private returns (Settlement memory s) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (fee > maxFee(amount)) revert FeeTooHigh();
        /* The seller always receives at least half. `maxFee` has a floor, and a floor alone would let
         * the fee be nearly all of a very small payment; a payment too small to carry its fee is
         * refused outright rather than settled mostly to P2Flux. */
        if (fee * 2 > amount) revert AmountTooSmall();
        bytes32 id = paymentId(supportedToken, recipient, amount, ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;
        address vault = _deploy(recipient);
        s = Settlement({
            vault: vault,
            recipient: recipient,
            amount: amount,
            fee: fee,
            ref: ref,
            id: id,
            held: IERC20(supportedToken).balanceOf(vault)
        });
    }

    /// @dev The pull must have added exactly `amount` to the vault. Anything already there (a
    ///      donation, a stranded payment) is left alone for `flush`.
    function _close(Settlement memory s) private {
        if (IERC20(supportedToken).balanceOf(s.vault) != s.held + s.amount) revert UnexpectedAmount();
        uint256 feePaid = P2FluxX402Vault(s.vault).release(IERC20(supportedToken), feeWallet, s.amount, s.fee);
        // What was paid, not what was asked: a fee the fee wallet could not receive went to the seller.
        emit Paid(s.ref, s.recipient, supportedToken, s.amount - feePaid, feePaid);
        emit PaymentSettled(s.id);
    }

    function _deploy(address recipient) private returns (address vault) {
        vault = vaultOf(recipient);
        if (vault.code.length == 0) new P2FluxX402Vault{salt: bytes32(0)}(recipient);
    }
}
