// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title P2FluxFeeRegistry
/// @notice The one place P2Flux fees live on a chain. Every v2 payment contract on that chain reads
///         its rate from here, so a price change or a partner listing is one admin action per chain,
///         not one per contract.
///
/// @dev What the admin can and cannot do, and nothing else exists:
///        - change a rate, only within the HARD CAPS below, and only DELAY after scheduling it, during
///          which the pending change is public on chain and can be cancelled;
///        - list or unlist a recipient as a partner, under the same delay;
///        - nothing that moves funds, redirects them, or touches a payer's signed terms.
///      A scheduled change that nobody executes within GRACE of becoming due lapses, so a forgotten
///      change can never be applied by surprise months later.
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
    /// @param fixedFee Flat fee in token base units (6-decimal USDC). Merchant-funded on payments,
    ///        sender-funded on relayed sends. Goes to the gas treasury, as the v1 fixed fee does.
    struct Rate {
        uint16 bps;
        uint16 partnerBps;
        uint64 fixedFee;
    }

    /// @notice Hard ceiling on any percentage fee: 2%, today's recurring rate. Code, not config.
    uint16 public constant MAX_BPS = 200;

    /// @notice Hard ceiling on any fixed fee: 0.20 USDC (6 decimals). Code, not config.
    uint64 public constant MAX_FIXED_FEE = 0.2e6;

    /// @notice How long a scheduled change is visible before it may take effect.
    uint256 public constant DELAY = 48 hours;

    /// @notice How long after becoming due a scheduled change may still be executed.
    uint256 public constant GRACE = 7 days;

    /// @notice Schedules and cancels changes. Cannot move funds. Immutable.
    address public immutable admin;

    mapping(Kind => Rate) public rates;
    mapping(Kind => Rate) public pendingRates;
    /// @notice When the pending rate for a kind may be executed. Zero = nothing pending.
    mapping(Kind => uint256) public pendingRateEta;

    mapping(address => bool) public isPartner;
    mapping(address => bool) public pendingPartner;
    /// @notice When the pending partner flag for a recipient may be executed. Zero = nothing pending.
    mapping(address => uint256) public pendingPartnerEta;

    event RateScheduled(Kind indexed kind, uint16 bps, uint16 partnerBps, uint64 fixedFee, uint256 eta);
    event RateCancelled(Kind indexed kind);
    event RateChanged(Kind indexed kind, uint16 bps, uint16 partnerBps, uint64 fixedFee);
    event PartnerScheduled(address indexed recipient, bool partner, uint256 eta);
    event PartnerCancelled(address indexed recipient);
    event PartnerChanged(address indexed recipient, bool partner);

    error ZeroAddress();
    error NotAdmin();
    error RateAboveCap();
    error NothingPending();
    error TooEarly();
    error Lapsed();

    constructor(address _admin, Rate memory oneTime, Rate memory recurring, Rate memory send) {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
        _setRate(Kind.OneTime, oneTime);
        _setRate(Kind.Recurring, recurring);
        _setRate(Kind.Send, send);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // --- read (what payment contracts call) ---------------------------------

    /// @notice The fee terms a payment of `kind` to `recipient` settles at right now.
    function feeFor(Kind kind, address recipient) external view returns (uint256 bps, uint256 fixedFee) {
        Rate memory r = rates[kind];
        return (isPartner[recipient] ? r.partnerBps : r.bps, r.fixedFee);
    }

    // --- rates ---------------------------------------------------------------

    /// @notice Schedule a new rate for `kind`. Replacing a pending one restarts the clock.
    function scheduleRate(Kind kind, Rate calldata rate) external onlyAdmin {
        _check(rate);
        uint256 eta = block.timestamp + DELAY;
        pendingRates[kind] = rate;
        pendingRateEta[kind] = eta;
        emit RateScheduled(kind, rate.bps, rate.partnerBps, rate.fixedFee, eta);
    }

    function cancelRate(Kind kind) external onlyAdmin {
        if (pendingRateEta[kind] == 0) revert NothingPending();
        delete pendingRates[kind];
        delete pendingRateEta[kind];
        emit RateCancelled(kind);
    }

    /// @notice Apply a pending rate once due. Anyone may call: the change was public for DELAY.
    function executeRate(Kind kind) external {
        _due(pendingRateEta[kind]);
        Rate memory r = pendingRates[kind];
        delete pendingRates[kind];
        delete pendingRateEta[kind];
        _setRate(kind, r);
    }

    // --- partners ------------------------------------------------------------

    /// @notice Schedule listing (`partner = true`) or unlisting of recipients. Batched because a
    ///         white-label partner may bring many merchant wallets at once.
    function schedulePartners(address[] calldata recipients, bool partner) external onlyAdmin {
        uint256 eta = block.timestamp + DELAY;
        for (uint256 i; i < recipients.length; i++) {
            address a = recipients[i];
            if (a == address(0)) revert ZeroAddress();
            pendingPartner[a] = partner;
            pendingPartnerEta[a] = eta;
            emit PartnerScheduled(a, partner, eta);
        }
    }

    function cancelPartner(address recipient) external onlyAdmin {
        if (pendingPartnerEta[recipient] == 0) revert NothingPending();
        delete pendingPartner[recipient];
        delete pendingPartnerEta[recipient];
        emit PartnerCancelled(recipient);
    }

    /// @notice Apply pending partner changes once due. Anyone may call.
    function executePartners(address[] calldata recipients) external {
        for (uint256 i; i < recipients.length; i++) {
            address a = recipients[i];
            _due(pendingPartnerEta[a]);
            bool partner = pendingPartner[a];
            delete pendingPartner[a];
            delete pendingPartnerEta[a];
            isPartner[a] = partner;
            emit PartnerChanged(a, partner);
        }
    }

    // --- internals -----------------------------------------------------------

    function _check(Rate memory r) private pure {
        if (r.bps > MAX_BPS || r.partnerBps > r.bps || r.fixedFee > MAX_FIXED_FEE) revert RateAboveCap();
    }

    function _setRate(Kind kind, Rate memory r) private {
        _check(r);
        rates[kind] = r;
        emit RateChanged(kind, r.bps, r.partnerBps, r.fixedFee);
    }

    function _due(uint256 eta) private view {
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly();
        if (block.timestamp > eta + GRACE) revert Lapsed();
    }
}
