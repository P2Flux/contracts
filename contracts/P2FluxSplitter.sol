// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal subset of the SpendPermissionManager interface.
/// @dev Full source: https://github.com/coinbase/spend-permissions
struct SpendPermission {
    address account;
    address spender;
    address token;
    uint160 allowance;
    uint48 period;
    uint48 start;
    uint48 end;
    uint256 salt;
    bytes extraData;
}

struct PeriodSpend {
    uint48 start;
    uint48 end;
    uint160 spend;
}

interface ISpendPermissionManager {
    function spend(SpendPermission memory permission, uint160 value) external;
    function getCurrentPeriod(SpendPermission memory permission) external view returns (PeriodSpend memory);
    function getHash(SpendPermission memory permission) external view returns (bytes32);
    function isValid(SpendPermission memory permission) external view returns (bool);
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title P2FluxSplitter
/// @notice Splits a USDC payment between a recipient and the P2Flux fee wallet in a single transaction.
/// @dev Holds no balance between calls. No withdrawals, no custody, no upgrade path.
///      For recurring charges this contract is the `spender` of the buyer's Spend Permission, because
///      SpendPermissionManager.spend() can only pay the spender - splitting requires a contract there.
contract P2FluxSplitter {
    ISpendPermissionManager public constant MANAGER =
        ISpendPermissionManager(0xf85210B21cC50302F477BA56686d2019dC9b67Ad);

    uint16 public constant ONE_TIME_BPS = 100; // 1%
    uint16 public constant RECURRING_BPS = 200; // 2%

    /// @notice Upper bound on the USDC the relayer may reimburse itself per charge (6 decimals).
    uint256 public constant MAX_GAS_FEE = 0.05e6;

    /// @notice Domain separator for one-time payment ids.
    bytes32 public constant PAYMENT_DOMAIN = keccak256("P2FLUX_PAYMENT_V1");

    /// @notice One-time payment intents that have already been settled.
    /// @dev The only persistent state this contract keeps, and the only place P2Flux stores anything
    ///      about a payment at all. A bare `true` per settled intent - no amounts, no addresses,
    ///      no buyer, nothing that says what was bought.
    mapping(bytes32 => bool) public processedPayments;

    /// @notice Cold key. Rotates `relayer`/`feeWallet`. Never moves funds.
    /// @dev The splitter address is baked into every Spend Permission, so redeploying would break every
    ///      live subscription. Rotation has to happen in place.
    address public immutable admin;

    /// @notice Hot key allowed to execute recurring charges.
    address public relayer;

    /// @notice Receives the P2Flux fee. Receive-only.
    address public feeWallet;

    event Paid(bytes32 indexed ref, address indexed recipient, uint256 net, uint256 fee);
    event PaymentSettled(bytes32 indexed paymentId);
    event Charged(
        bytes32 indexed permissionHash, address indexed recipient, uint256 net, uint256 fee, uint256 gasFee
    );
    event RelayerChanged(address relayer);
    event FeeWalletChanged(address feeWallet);

    error NotAdmin();
    error NotRelayer();
    error ZeroAddress();
    error ZeroAmount();
    error GasFeeTooHigh();
    error AlreadyChargedThisPeriod();
    error TransferFailed();
    error PaymentAlreadyProcessed(bytes32 paymentId);

    constructor(address _admin, address _relayer, address _feeWallet) {
        if (_admin == address(0) || _relayer == address(0) || _feeWallet == address(0)) revert ZeroAddress();
        admin = _admin;
        relayer = _relayer;
        feeWallet = _feeWallet;
    }

    // --- admin -------------------------------------------------------------

    function setRelayer(address _relayer) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
        emit RelayerChanged(_relayer);
    }

    function setFeeWallet(address _feeWallet) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_feeWallet == address(0)) revert ZeroAddress();
        feeWallet = _feeWallet;
        emit FeeWalletChanged(_feeWallet);
    }

    // --- one-time ----------------------------------------------------------

    /// @notice Identifier of a one-time payment intent, over its complete immutable terms.
    ///
    /// @dev `token` is part of the identity even though the intent is USDC-only today. Without it,
    ///      anyone who saw a reference could settle the intent with a worthless token, burning the
    ///      buyer's ability to pay while the recipient received nothing of value. Changing the
    ///      token, the recipient or the amount produces a different id, so an attacker cannot
    ///      consume a payment except by actually making it.
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
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Checks, effects, then interactions. If any transfer below reverts, this write is rolled
        // back with it, so a failed payment leaves the intent payable.
        bytes32 id = paymentId(token, recipient, amount, ref);
        if (processedPayments[id]) revert PaymentAlreadyProcessed(id);
        processedPayments[id] = true;

        uint256 fee = (amount * ONE_TIME_BPS) / 10_000;

        // Straight from buyer to each destination: the contract never holds the funds.
        _transferFrom(token, msg.sender, recipient, amount - fee);
        if (fee > 0) _transferFrom(token, msg.sender, feeWallet, fee);

        emit Paid(ref, recipient, amount - fee, fee);
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
        // Swallow failure: a griefer can front-run the permit, which would otherwise revert the payment.
        // If the allowance really is missing, `pay` reverts anyway.
        try IERC20(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        pay(token, recipient, amount, ref);
    }

    // --- recurring ---------------------------------------------------------

    /// @notice Execute one recurring charge against a buyer-signed Spend Permission.
    /// @dev Recipient and amount come from `permission.extraData`, which is inside the EIP-712 hash the
    ///      buyer signed - neither P2Flux nor the seller can alter them.
    /// @param gasFee USDC reimbursed to the relayer for the network cost of this transaction.
    function charge(SpendPermission calldata permission, uint256 gasFee) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (gasFee > MAX_GAS_FEE) revert GasFeeTooHigh();

        // Hard one-charge-per-period, independent of allowance arithmetic. A reverted charge leaves
        // `spend` at 0, so a failed attempt is still retryable inside the same period.
        if (MANAGER.getCurrentPeriod(permission).spend != 0) revert AlreadyChargedThisPeriod();

        (address recipient, uint256 amount) = abi.decode(permission.extraData, (address, uint256));
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Pulls amount + gasFee from the buyer's account to this contract.
        MANAGER.spend(permission, uint160(amount + gasFee));

        // Fee is charged on the subscription amount only - P2Flux takes no cut of the gas reimbursement.
        uint256 fee = (amount * RECURRING_BPS) / 10_000;

        _transfer(permission.token, recipient, amount - fee);
        if (fee > 0) _transfer(permission.token, feeWallet, fee);
        if (gasFee > 0) _transfer(permission.token, msg.sender, gasFee);

        emit Charged(MANAGER.getHash(permission), recipient, amount - fee, fee, gasFee);
    }

    // --- internals ---------------------------------------------------------

    function _transfer(address token, address to, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _transferFrom(address token, address from, address to, uint256 value) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
