// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The slice of TRC-20 this file uses. Tron's USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`) is not a
///      well-behaved ERC-20: its `transfer` returns `false` even when the transfer happened, so no
///      return value is trusted here - every transfer is judged by the balances it changed.
interface ITRC20 {
    function balanceOf(address who) external view returns (uint256);
}

/// @title P2FluxTronVault
/// @notice One per merchant, at an address anyone can compute in advance: where buyers send USDT with an
///         ordinary transfer (from any wallet, or straight from an exchange withdrawal).
///
/// @dev Deployed as a minimal proxy (EIP-1167) of one implementation: on Tron a full contract per merchant
///      costs ~$15 of energy, a 45-byte proxy a fraction. Initialised in the same transaction that creates
///      it, by the factory and only once; the implementation itself can never be initialised.
///
///      The only thing a vault can ever do with its balance is pay its merchant, and hand the factory the
///      P2Flux fee and the payout cost it RESERVED at each payout (`reservedFee`, `reservedPayoutFee`) -
///      never more. No key, not even the relayer's, can send a merchant's money anywhere else.
///
///      Why reserve instead of paying the factory at every payout: every USDT transfer on Tron costs real
///      money. A payout moves one transfer (to the merchant); P2Flux's share leaves later, in one transfer
///      per vault for many payouts (`collect`).
contract P2FluxTronVault {
    address public factory;
    address public merchant;
    /// @notice The P2Flux fee kept back from past payouts, not yet collected.
    uint256 public reservedFee;
    /// @notice The payout costs kept back from past payouts, not yet collected.
    uint256 public reservedPayoutFee;

    error NotFactory();
    error AlreadyInitialized();
    error TransferFailed();

    constructor() {
        // The implementation: permanently initialised to nobody.
        factory = address(0xdead);
    }

    function initialize(address _merchant) external {
        if (factory != address(0)) revert AlreadyInitialized();
        factory = msg.sender;
        merchant = _merchant;
    }

    /// @notice Pay `net` to the merchant and keep back `fee` and `payoutFee`. The merchant's transfer is
    ///         mandatory: if it does not arrive, nothing changes.
    function release(address token, uint256 net, uint256 fee, uint256 payoutFee) external {
        if (msg.sender != factory) revert NotFactory();
        reservedFee += fee;
        reservedPayoutFee += payoutFee;
        if (!_trySend(token, merchant, net)) revert TransferFailed();
    }

    /// @notice Hand the reserved shares to the factory. A frozen factory leaves them reserved here - they
    ///         are P2Flux's, and the merchant's payouts never touch them.
    function collect(address token) external returns (uint256 fee, uint256 payoutFee) {
        if (msg.sender != factory) revert NotFactory();
        (fee, payoutFee) = (reservedFee, reservedPayoutFee);
        if (fee + payoutFee == 0 || !_trySend(token, factory, fee + payoutFee)) return (0, 0);
        (reservedFee, reservedPayoutFee) = (0, 0);
    }

    /// @dev Judged by what arrived, never by the return value (see ITRC20).
    function _trySend(address token, address to, uint256 value) private returns (bool) {
        if (value == 0) return true;
        uint256 before = ITRC20(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && ITRC20(token).balanceOf(to) == before + value;
    }
}

/// @title P2FluxTronVaults
/// @notice USDT payments on Tron: each merchant receives at its own vault; payouts move the vault's balance
///         to the merchant in batches, with the P2Flux fee split out on chain. One-time payments arrive as
///         plain transfers; subscriptions are pulled into the same vault by `charge`.
///
/// @dev Why vaults and not `approve` + `pay` as on Base: on Tron every token movement costs real money
///      (~65,000 energy, ~$2 for a USDT transfer), and an approve costs as much again. A buyer paying the
///      vault with a plain transfer pays one transfer and needs no contract call, no signature and no
///      particular wallet. P2Flux recognises the payment off chain (a unique amount per payment intent).
///
///      Payouts:
///        - Anyone may pay a vault out at any time with `payoutFee = 0`: the merchant never needs P2Flux to
///          receive its money. The P2Flux fee (1%) is always kept back.
///        - Only the relayer may charge the network cost of a payout (`payoutFee`, merchant-funded), never
///          more than MAX_PAYOUT_FEE, never more than a tenth of the batch, and at most once per
///          PAID_PAYOUT_INTERVAL per vault - so even a stolen relayer key can take little, and slowly.
///        - A payout is ONE transfer (to the merchant). P2Flux's share stays reserved in the vault and is
///          collected later (`collect`, anyone), then leaves to destinations fixed at deployment (`sweep`).
///
///      Subscriptions (`charge`), as `P2FluxRecurring` on Base: the buyer approves this contract once and
///      signs the exact terms once (TIP-712, Tron's EIP-712); each period anyone may charge exactly those
///      terms, once. Unlike Base, a charge is ONE transfer - payer to the merchant's vault - because each
///      transfer costs the buyer ~$2 in reimbursed energy. The subscription fee (2% + NETWORK_FEE) and the
///      reimbursement are recorded as P2Flux's (`pending`) and leave with the vault's next payout, which
///      takes no 1% again from subscription money.
///
///      Not upgradeable, no pause, no withdrawal path besides the ones above. The admin (cold key) can only
///      rotate the relayer: subscription signatures commit to this contract's address, so a stolen relayer
///      key must be replaceable without a redeploy.
contract P2FluxTronVaults {
    /// @notice P2Flux's fee on every payout: 1%, the same as a one-time payment on Base.
    uint16 public constant FEE_BPS = 100;
    /// @notice The most a single payout may be charged for its network cost: 8 USDT (6 decimals). A payout
    ///         costs ~$1-2.5 of TRX today; the cap leaves room for TRX price moves, never for profit.
    uint256 public constant MAX_PAYOUT_FEE = 8e6;
    /// @notice A charged payout of the same vault at most this often.
    uint256 public constant PAID_PAYOUT_INTERVAL = 12 hours;
    /// @notice What a payout leaves in the vault on top of the reserved shares: one unit. On Tron, a transfer
    ///         to an address holding no USDT costs about twice as much energy.
    uint256 public constant VAULT_FLOOR = 1;
    /// @notice Subscriptions: P2Flux's fee (2%) and flat network fee per charge, both out of the signed
    ///         amount, as on Base.
    uint16 public constant RECURRING_FEE_BPS = 200;
    uint256 public constant NETWORK_FEE = 0.10e6;
    /// @notice The most a charge may add for the relayer's energy, whatever was signed: 5 USDT. A charge
    ///         costs ~$2.5 of TRX today.
    uint256 public constant GAS_REIMBURSEMENT_HARD_CAP = 5e6;

    /// @notice The exact recurring terms the buyer signs; the same type as `P2FluxRecurring` on Base.
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
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Subscription money a vault holds that is P2Flux's (fee, network fee + reimbursement), and how
    ///         much of the rest already paid its fee. Settled into the vault at its next payout.
    struct Pending {
        uint256 fee;
        uint256 payoutFee;
        uint256 feePaid;
    }

    address public immutable token;
    address public immutable feeWallet;
    address public immutable gasTreasury;
    address public immutable admin;
    address public relayer;
    /// @notice The vault implementation every merchant's proxy delegates to.
    address public immutable implementation;
    /// @dev CREATE2 address prefix: 0x41 on the Tron VM, 0xff on Ethereum VMs (tests).
    bytes1 public immutable create2Prefix;

    uint256 public accruedFees;
    uint256 public accruedPayoutFees;
    mapping(address merchant => uint256) public lastPaidPayout;
    mapping(address merchant => Pending) public pending;
    /// @dev subscriptionId => index of the last charged period, plus one (0 = never charged).
    mapping(bytes32 => uint256) public lastChargedPeriodPlusOne;
    mapping(bytes32 => bool) public revoked;

    event VaultDeployed(address indexed merchant, address vault);
    event Payout(address indexed merchant, address indexed vault, uint256 amount, uint256 net, uint256 fee, uint256 payoutFee);
    event Collected(address indexed merchant, address indexed vault, uint256 fee, uint256 payoutFee);
    event Swept(uint256 fees, uint256 payoutFees);
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
    error NotRelayer();
    error PayoutFeeTooHigh();
    error PaidPayoutTooSoon();
    error VaultMismatch();
    error NotAdmin();
    error TokenNotSupported();
    error ZeroPeriod();
    error InvalidEnd();
    error NotStarted();
    error Expired();
    error Revoked();
    error AlreadyRevoked();
    error NotPayer();
    error InvalidSignature();
    error AlreadyChargedThisPeriod();
    error GasReimbursementTooHigh();
    error AmountTooSmall();
    error TransferFailed();

    constructor(
        address _admin,
        address _token,
        address _feeWallet,
        address _gasTreasury,
        address _relayer,
        bytes1 _create2Prefix
    ) {
        if (
            _admin == address(0) || _token == address(0) || _feeWallet == address(0) || _gasTreasury == address(0)
                || _relayer == address(0)
        ) revert ZeroAddress();
        admin = _admin;
        token = _token;
        feeWallet = _feeWallet;
        gasTreasury = _gasTreasury;
        relayer = _relayer;
        create2Prefix = _create2Prefix;
        implementation = address(new P2FluxTronVault());
    }

    function setRelayer(address _relayer) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
        emit RelayerChanged(_relayer);
    }

    /// @notice The merchant's vault: where buyers pay. Deterministic; deployed on its first payout.
    function vaultOf(address merchant) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(create2Prefix, address(this), _salt(merchant), keccak256(_proxyCode()))))));
    }

    /// @notice Pay everything the merchant is owed out of its vault, keeping back the P2Flux fee and, when the
    ///         relayer asks, the payout's network cost.
    function payout(address merchant, uint256 payoutFee) external {
        if (merchant == address(0)) revert ZeroAddress();
        P2FluxTronVault vault = P2FluxTronVault(_deploy(merchant));
        Pending memory p = pending[merchant];
        uint256 held = ITRC20(token).balanceOf(address(vault));
        uint256 reserved = vault.reservedFee() + vault.reservedPayoutFee() + p.fee + p.payoutFee;
        if (held <= reserved + VAULT_FLOOR) revert ZeroAmount();
        uint256 amount = held - reserved - VAULT_FLOOR;
        if (payoutFee > 0) {
            if (msg.sender != relayer) revert NotRelayer();
            if (payoutFee > MAX_PAYOUT_FEE || payoutFee * 10 > amount) revert PayoutFeeTooHigh();
            if (block.timestamp < lastPaidPayout[merchant] + PAID_PAYOUT_INTERVAL) revert PaidPayoutTooSoon();
            lastPaidPayout[merchant] = block.timestamp;
        }
        // Subscription money already paid its fee at `charge`.
        uint256 feePaid = p.feePaid < amount ? p.feePaid : amount;
        uint256 fee = ((amount - feePaid) * FEE_BPS) / 10_000;
        uint256 net = amount - fee - payoutFee;
        delete pending[merchant];
        if (p.feePaid > feePaid) pending[merchant].feePaid = p.feePaid - feePaid;
        vault.release(token, net, fee + p.fee, payoutFee + p.payoutFee);
        emit Payout(merchant, address(vault), amount, net, fee, payoutFee);
    }

    /// @notice Move the P2Flux shares reserved in a merchant's vault here. Anyone may call it.
    function collect(address merchant) external {
        address vault = vaultOf(merchant);
        if (vault.code.length == 0) revert ZeroAmount();
        (uint256 fee, uint256 payoutFee) = P2FluxTronVault(vault).collect(token);
        accruedFees += fee;
        accruedPayoutFees += payoutFee;
        emit Collected(merchant, vault, fee, payoutFee);
    }

    /// @notice Send P2Flux's collected shares to their fixed destinations. Anyone may call it. A share whose
    ///         destination cannot receive (frozen) stays accrued; the other still leaves.
    function sweep() external {
        uint256 fees = accruedFees;
        uint256 payoutFees = accruedPayoutFees;
        if (fees > 0 && _trySend(feeWallet, fees)) accruedFees = 0;
        else fees = 0;
        if (payoutFees > 0 && _trySend(gasTreasury, payoutFees)) accruedPayoutFees = 0;
        else payoutFees = 0;
        emit Swept(fees, payoutFees);
    }

    // --- subscriptions ------------------------------------------------------

    /// @notice The TIP-712 digest of the terms; doubles as the subscription id (commits to this chain and
    ///         this contract).
    function subscriptionId(RecurringAuthorization calldata auth) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("P2FluxTronVaults"), keccak256("1"), block.chainid, address(this))
        );
        bytes32 structHash = keccak256(
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
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function isValidAuthorization(RecurringAuthorization calldata auth, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return _recover(subscriptionId(auth), signature) == auth.payer;
    }

    /// @notice Whether `charge` would currently pass its own preconditions (signature not checked).
    function isChargeable(RecurringAuthorization calldata auth) external view returns (bool) {
        if (auth.period == 0 || block.timestamp < auth.start) return false;
        if (auth.end != 0 && block.timestamp >= auth.end) return false;
        bytes32 id = subscriptionId(auth);
        if (revoked[id]) return false;
        return lastChargedPeriodPlusOne[id] < (block.timestamp - auth.start) / auth.period + 1;
    }

    /// @notice Charge the current period of a subscription into the merchant's vault. Callable by anyone;
    ///         only the exact signed payment, once per period. Only the relayer may add `gasReimbursement`.
    function charge(RecurringAuthorization calldata auth, bytes calldata signature, uint256 gasReimbursement)
        external
    {
        if (auth.recipient == address(0) || auth.payer == address(0)) revert ZeroAddress();
        if (auth.token != token) revert TokenNotSupported();
        if (auth.amount == 0) revert ZeroAmount();
        if (auth.period == 0) revert ZeroPeriod();
        if (auth.end != 0 && auth.end <= auth.start) revert InvalidEnd();
        if (block.timestamp < auth.start) revert NotStarted();
        if (auth.end != 0 && block.timestamp >= auth.end) revert Expired();

        bytes32 id = subscriptionId(auth);
        if (revoked[id]) revert Revoked();
        if (_recover(id, signature) != auth.payer) revert InvalidSignature();

        uint256 periodIndex = (block.timestamp - auth.start) / auth.period;
        if (lastChargedPeriodPlusOne[id] >= periodIndex + 1) revert AlreadyChargedThisPeriod();

        uint256 reimbursement = msg.sender == relayer ? gasReimbursement : 0;
        if (reimbursement > auth.maxGasReimbursement || reimbursement > GAS_REIMBURSEMENT_HARD_CAP) {
            revert GasReimbursementTooHigh();
        }

        uint256 fee = (auth.amount * RECURRING_FEE_BPS) / 10_000;
        if (auth.amount <= fee + NETWORK_FEE) revert AmountTooSmall();
        uint256 net = auth.amount - fee - NETWORK_FEE;

        lastChargedPeriodPlusOne[id] = periodIndex + 1;
        Pending storage p = pending[auth.recipient];
        p.fee += fee;
        p.payoutFee += NETWORK_FEE + reimbursement;
        p.feePaid += net;

        // One transfer, payer -> the merchant's vault (deployed or not: its address is fixed). Judged by
        // what arrived (see ITRC20).
        address vault = vaultOf(auth.recipient);
        uint256 total = auth.amount + reimbursement;
        uint256 before = ITRC20(token).balanceOf(vault);
        (bool ok,) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", auth.payer, vault, total)
        );
        if (!ok || ITRC20(token).balanceOf(vault) != before + total) revert TransferFailed();

        emit SubscriptionCharged(id, auth.payer, auth.recipient, periodIndex, net, fee, NETWORK_FEE, reimbursement);
    }

    /// @notice Cancel one subscription for good. Only the payer. Setting the allowance to zero stops all.
    function revoke(RecurringAuthorization calldata auth) external {
        if (msg.sender != auth.payer) revert NotPayer();
        bytes32 id = subscriptionId(auth);
        if (revoked[id]) revert AlreadyRevoked();
        revoked[id] = true;
        emit SubscriptionRevoked(id, auth.payer);
    }

    /// @dev Plain ECDSA (65-byte r,s,v), low-s only. Tron has no EIP-7702 and its wallets are keys.
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _salt(address merchant) private pure returns (bytes32) {
        return bytes32(uint256(uint160(merchant)));
    }

    /// @dev EIP-1167 minimal proxy creation code for `implementation`.
    function _proxyCode() private view returns (bytes memory) {
        return abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
    }

    function _deploy(address merchant) private returns (address vault) {
        vault = vaultOf(merchant);
        if (vault.code.length == 0) {
            bytes memory code = _proxyCode();
            bytes32 salt = _salt(merchant);
            address deployed;
            assembly {
                deployed := create2(0, add(code, 0x20), mload(code), salt)
            }
            // The prediction and the deployment must agree, or buyers would be paying a wrong address.
            if (deployed != vault) revert VaultMismatch();
            P2FluxTronVault(vault).initialize(merchant);
            emit VaultDeployed(merchant, vault);
        }
    }

    function _trySend(address to, uint256 value) private returns (bool) {
        uint256 before = ITRC20(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && ITRC20(token).balanceOf(to) == before + value;
    }
}
