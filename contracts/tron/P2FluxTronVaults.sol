// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev The slice of TRC-20 this file uses. Tron's USDT (`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`) is not a
///      well-behaved ERC-20: its `transfer` returns `false` even when the transfer happened, so no
///      return value is trusted here - every transfer is judged by the balances it changed.
interface ITRC20 {
    function balanceOf(address who) external view returns (uint256);
}

/// @title P2FluxTronVault
/// @notice One per merchant, at an address anyone can compute in advance: where buyers send USDT with
///         an ordinary transfer (from any wallet, or straight from an exchange withdrawal).
///
/// @dev The merchant is fixed at deployment and is part of the CREATE2 address, and the only thing the
///      vault can ever do with its balance is pay that merchant, less what the factory keeps: the P2Flux
///      fee and the network cost of the payout, both bounded by the factory. No key - not even the
///      relayer's - can send a merchant's money anywhere else.
contract P2FluxTronVault {
    /// @notice The P2FluxTronVaults that deployed this vault; the only caller of `release`.
    address public immutable factory;
    /// @notice The merchant. Every unit that leaves this vault, except what the factory keeps, goes here.
    address public immutable merchant;

    error NotFactory();
    error TransferFailed();

    constructor(address _merchant) {
        factory = msg.sender;
        merchant = _merchant;
    }

    /// @notice Pay out `amount`: `keep` to the factory, the rest to the merchant.
    /// @return kept What the factory actually received: `keep`, or zero if it could not be paid.
    /// @dev The merchant's leg is mandatory: if it does not arrive, nothing moves. The factory's leg is
    ///      not: a token issuer can freeze any address, and a frozen factory must not lock every
    ///      merchant's money forever - the merchant then receives everything.
    function release(address token, uint256 amount, uint256 keep) external returns (uint256 kept) {
        if (msg.sender != factory) revert NotFactory();
        if (keep > 0 && _trySend(token, factory, keep)) kept = keep;
        if (!_trySend(token, merchant, amount - kept)) revert TransferFailed();
    }

    /// @dev Judged by what arrived, never by the return value (see ITRC20).
    function _trySend(address token, address to, uint256 value) private returns (bool) {
        uint256 before = ITRC20(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && ITRC20(token).balanceOf(to) == before + value;
    }
}

/// @title P2FluxTronVaults
/// @notice One-time USDT payments on Tron: each merchant receives at its own vault; payouts move the
///         vault's balance to the merchant in batches, with the P2Flux fee split out on chain.
///
/// @dev Why vaults and not `approve` + `pay` as on Base: on Tron every token movement costs real money
///      (~65,000 energy, ~$2 for a USDT transfer), and an approve costs as much again. A buyer paying the
///      vault with a plain transfer pays one transfer and needs no contract call, no signature and no
///      particular wallet. P2Flux recognises the payment off chain (a unique amount per payment intent).
///
///      Payouts:
///        - Anyone may pay a vault out at any time with `payoutFee = 0`: the merchant never needs P2Flux
///          to receive its money. The P2Flux fee (1%) is always taken.
///        - Only the relayer may charge the network cost of a payout (`payoutFee`, merchant-funded),
///          never more than MAX_PAYOUT_FEE, never more than a tenth of the batch, and at most once per
///          PAID_PAYOUT_INTERVAL per vault - so even a stolen relayer key can take little, and slowly.
///        - P2Flux's shares accrue here and leave in one transfer each (`sweep`), to destinations fixed
///          at deployment. That saves a token transfer per payout.
///
///      Not upgradeable, no owner, no pause, no withdrawal path besides the two above.
contract P2FluxTronVaults {
    /// @notice P2Flux's fee on every payout: 1%, the same as a one-time payment on Base.
    uint16 public constant FEE_BPS = 100;
    /// @notice The most a single payout may be charged for its network cost: 8 USDT (6 decimals). A payout
    ///         costs ~$5 of TRX today; the cap leaves room for TRX price moves, never for profit.
    uint256 public constant MAX_PAYOUT_FEE = 8e6;
    /// @notice What a payout leaves in the vault: one unit. On Tron, a transfer to an address holding no
    ///         USDT costs about twice as much energy, so an emptied vault would double the next buyer's cost.
    uint256 public constant VAULT_FLOOR = 1;
    /// @notice A charged payout of the same vault at most this often.
    uint256 public constant PAID_PAYOUT_INTERVAL = 12 hours;

    address public immutable token;
    address public immutable feeWallet;
    address public immutable gasTreasury;
    address public immutable relayer;
    /// @dev CREATE2 address prefix: 0x41 on the Tron VM, 0xff on Ethereum VMs (tests).
    bytes1 public immutable create2Prefix;

    uint256 public accruedFees;
    uint256 public accruedPayoutFees;
    mapping(address merchant => uint256) public lastPaidPayout;

    event VaultDeployed(address indexed merchant, address vault);
    event Payout(address indexed merchant, address indexed vault, uint256 amount, uint256 net, uint256 fee, uint256 payoutFee);
    event Swept(uint256 fees, uint256 payoutFees);

    error ZeroAddress();
    error ZeroAmount();
    error NotRelayer();
    error PayoutFeeTooHigh();
    error PaidPayoutTooSoon();
    error VaultMismatch();
    constructor(address _token, address _feeWallet, address _gasTreasury, address _relayer, bytes1 _create2Prefix) {
        if (_token == address(0) || _feeWallet == address(0) || _gasTreasury == address(0) || _relayer == address(0)) {
            revert ZeroAddress();
        }
        token = _token;
        feeWallet = _feeWallet;
        gasTreasury = _gasTreasury;
        relayer = _relayer;
        create2Prefix = _create2Prefix;
    }

    /// @notice The merchant's vault: where buyers pay. Deterministic; deployed on its first payout.
    function vaultOf(address merchant) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(P2FluxTronVault).creationCode, abi.encode(merchant)));
        return address(uint160(uint256(keccak256(abi.encodePacked(create2Prefix, address(this), bytes32(0), initCodeHash)))));
    }

    /// @notice Pay everything in the merchant's vault out to the merchant, less the P2Flux fee and, when the
    ///         relayer asks, the payout's network cost.
    function payout(address merchant, uint256 payoutFee) external {
        if (merchant == address(0)) revert ZeroAddress();
        address vault = _deploy(merchant);
        uint256 held = ITRC20(token).balanceOf(vault);
        if (held <= VAULT_FLOOR) revert ZeroAmount();
        uint256 amount = held - VAULT_FLOOR;
        if (payoutFee > 0) {
            if (msg.sender != relayer) revert NotRelayer();
            if (payoutFee > MAX_PAYOUT_FEE || payoutFee * 10 > amount) revert PayoutFeeTooHigh();
            if (block.timestamp < lastPaidPayout[merchant] + PAID_PAYOUT_INTERVAL) revert PaidPayoutTooSoon();
            lastPaidPayout[merchant] = block.timestamp;
        }
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 kept = P2FluxTronVault(vault).release(token, amount, fee + payoutFee);
        // Nothing kept (a frozen factory): the merchant got everything, and nothing accrues.
        if (kept == 0) (fee, payoutFee) = (0, 0);
        accruedFees += fee;
        accruedPayoutFees += payoutFee;
        emit Payout(merchant, vault, amount, amount - fee - payoutFee, fee, payoutFee);
    }

    /// @notice Send P2Flux's accrued shares to their fixed destinations. Anyone may call it. A share whose
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

    function _deploy(address merchant) private returns (address vault) {
        vault = vaultOf(merchant);
        if (vault.code.length == 0) {
            address deployed = address(new P2FluxTronVault{salt: bytes32(0)}(merchant));
            // The prediction and the deployment must agree, or buyers would be paying a wrong address.
            if (deployed != vault) revert VaultMismatch();
            emit VaultDeployed(merchant, vault);
        }
    }

    function _trySend(address to, uint256 value) private returns (bool) {
        uint256 before = ITRC20(token).balanceOf(to);
        (bool ok, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        return ok && ITRC20(token).balanceOf(to) == before + value;
    }
}
