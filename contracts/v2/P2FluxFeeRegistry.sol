// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title P2FluxFeeRegistry
/// @notice The one place P2Flux fees live on a chain. Every v2 payment contract on that chain reads
///         its rate from here, so a price change or a partner listing is one admin action per chain,
///         not one per contract.
///
/// @dev What the admin can and cannot do, and nothing else exists:
///        - schedule a rate change, only within the HARD CAPS below. It takes effect by itself
///          exactly DELAY after scheduling: no execute call, so nobody chooses the moment;
///        - schedule listing or unlisting a recipient as a partner, under the same rule;
///        - cancel a scheduled change before it takes effect;
///        - nothing that moves funds, redirects them, or touches a payer's signed terms.
///      Every read returns the value effective at `block.timestamp`: a slot keeps the current value,
///      the next value and its effective time, and the next value wins once that time is reached.
///
///      Not upgradeable, no proxy, no admin rotation. The admin should be a multisig (or a cold key):
///      signer rotation then happens inside the multisig, and this contract stays this simple.
contract P2FluxFeeRegistry {
    /// @notice What is being paid. Each v2 payment contract reads exactly one kind.
    enum Kind {
        OneTime,
        Recurring,
        Send
    }

    /// @param bps Standard profit fee, in basis points of the amount.
    /// @param partnerBps Profit fee for a listed partner recipient. Never above `bps`.
    /// @param fixedFee Flat fee in token base units (6-decimal USDC), charged on relayed paths only.
    ///        Goes to the gas treasury, as the v1 fixed fee does.
    struct Rate {
        uint16 bps;
        uint16 partnerBps;
        uint64 fixedFee;
    }

    /// @dev One storage slot. `next` is effective from `eta` on; `eta == 0` means nothing scheduled.
    struct RateSlot {
        Rate current;
        Rate next;
        uint64 eta;
    }

    struct PartnerSlot {
        bool current;
        bool next;
        uint64 eta;
    }

    /// @notice Hard ceiling on any percentage fee: 2%, today's recurring rate. Code, not config.
    uint16 public constant MAX_BPS = 200;

    /// @notice Hard ceiling on any fixed fee: 0.20 USDC (6 decimals). Code, not config.
    uint64 public constant MAX_FIXED_FEE = 0.2e6;

    /// @notice How long a scheduled change is visible before it takes effect.
    uint256 public constant DELAY = 48 hours;

    /// @notice Schedules and cancels changes. Cannot move funds. Immutable.
    address public immutable admin;

    mapping(Kind => RateSlot) private _rates;
    mapping(address => PartnerSlot) private _partners;

    event RateScheduled(Kind indexed kind, uint16 bps, uint16 partnerBps, uint64 fixedFee, uint256 effectiveAt);
    event RateCancelled(Kind indexed kind);
    event PartnerScheduled(address indexed recipient, bool partner, uint256 effectiveAt);
    event PartnerCancelled(address indexed recipient);

    error ZeroAddress();
    error NotAdmin();
    error RateAboveCap();
    error NothingPending();

    constructor(address _admin, Rate memory oneTime, Rate memory recurring, Rate memory send) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
        _init(Kind.OneTime, oneTime);
        _init(Kind.Recurring, recurring);
        _init(Kind.Send, send);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // --- reads (effective now) -----------------------------------------------

    /// @notice The rate of `kind` effective right now.
    function rates(Kind kind) public view returns (uint16 bps, uint16 partnerBps, uint64 fixedFee) {
        Rate memory r = _effective(_rates[kind]);
        return (r.bps, r.partnerBps, r.fixedFee);
    }

    /// @notice Whether `recipient` gets the partner rate right now.
    function isPartner(address recipient) public view returns (bool) {
        PartnerSlot memory s = _partners[recipient];
        return s.eta != 0 && block.timestamp >= s.eta ? s.next : s.current;
    }

    /// @notice The rate scheduled for `kind` and when it takes effect; all zero if none is pending.
    function pendingRate(Kind kind)
        external
        view
        returns (uint16 bps, uint16 partnerBps, uint64 fixedFee, uint256 effectiveAt)
    {
        RateSlot memory s = _rates[kind];
        if (s.eta == 0 || block.timestamp >= s.eta) return (0, 0, 0, 0);
        return (s.next.bps, s.next.partnerBps, s.next.fixedFee, s.eta);
    }

    /// @notice The partner flag scheduled for `recipient` and when it takes effect (0 = none).
    function pendingPartner(address recipient) external view returns (bool partner, uint256 effectiveAt) {
        PartnerSlot memory s = _partners[recipient];
        if (s.eta == 0 || block.timestamp >= s.eta) return (false, 0);
        return (s.next, s.eta);
    }

    /// @notice Convenience: the bps and fixed fee a payment of `kind` to `recipient` settles at now.
    function feeFor(Kind kind, address recipient) external view returns (uint256 bps, uint256 fixedFee) {
        (uint16 b, uint16 pb, uint64 f) = rates(kind);
        return (isPartner(recipient) ? pb : b, f);
    }

    // --- admin ---------------------------------------------------------------

    /// @notice Schedule `rate` for `kind`, effective DELAY from now. Replacing a pending one restarts
    ///         the clock.
    function scheduleRate(Kind kind, Rate calldata rate) external onlyAdmin {
        _check(rate);
        RateSlot storage s = _rates[kind];
        s.current = _effective(s);
        s.next = rate;
        s.eta = uint64(block.timestamp + DELAY);
        emit RateScheduled(kind, rate.bps, rate.partnerBps, rate.fixedFee, s.eta);
    }

    /// @notice Cancel a scheduled rate before it takes effect. After that, schedule the old one back.
    function cancelRate(Kind kind) external onlyAdmin {
        RateSlot storage s = _rates[kind];
        if (s.eta == 0 || block.timestamp >= s.eta) revert NothingPending();
        delete s.next;
        s.eta = 0;
        emit RateCancelled(kind);
    }

    /// @notice Schedule listing (`partner = true`) or unlisting of recipients, effective DELAY from
    ///         now. Batched because a white-label partner may bring many merchant wallets at once.
    function schedulePartners(address[] calldata recipients, bool partner) external onlyAdmin {
        uint64 eta = uint64(block.timestamp + DELAY);
        for (uint256 i; i < recipients.length; i++) {
            address a = recipients[i];
            if (a == address(0)) revert ZeroAddress();
            _partners[a] = PartnerSlot(isPartner(a), partner, eta);
            emit PartnerScheduled(a, partner, eta);
        }
    }

    function cancelPartner(address recipient) external onlyAdmin {
        PartnerSlot storage s = _partners[recipient];
        if (s.eta == 0 || block.timestamp >= s.eta) revert NothingPending();
        s.eta = 0;
        s.next = false;
        emit PartnerCancelled(recipient);
    }

    // --- internals -----------------------------------------------------------

    function _effective(RateSlot memory s) private view returns (Rate memory) {
        return s.eta != 0 && block.timestamp >= s.eta ? s.next : s.current;
    }

    function _check(Rate memory r) private pure {
        if (r.bps > MAX_BPS || r.partnerBps > r.bps || r.fixedFee > MAX_FIXED_FEE) revert RateAboveCap();
    }

    function _init(Kind kind, Rate memory r) private {
        _check(r);
        _rates[kind].current = r;
        emit RateScheduled(kind, r.bps, r.partnerBps, r.fixedFee, block.timestamp);
    }
}
