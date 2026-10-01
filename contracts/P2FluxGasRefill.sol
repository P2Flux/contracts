// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Uniswap v3 SwapRouter02 (no deadline field).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title P2FluxGasRefill
/// @notice Keeps the P2Flux relayer in gas from P2Flux's own USDC: when the relayer falls below a floor,
///         USDC is taken from the gas treasury (which collects the network fees paid for exactly this),
///         swapped to ETH on Uniswap and sent to the relayer - enough to bring it up to a target.
///
/// @dev Fixed at deployment, changeable by nobody:
///        - the ETH goes to `relayer` and nowhere else;
///        - USDC comes only from `treasury`, and only as far as the treasury has approved this contract;
///        - a refill happens only while the relayer holds less than `refillBelowWei`;
///        - the price must be a fresh Chainlink ETH/USD price (and, where an L2 sequencer feed is set,
///          the sequencer must have been up for an hour), and the swap must return at least that
///          price less `maxSlippageBps`.
///      Changeable only by `treasury` - the wallet whose USDC this spends, which already decides the
///      allowance - so limits grow with traffic without a new contract: `dailyCapUsdc` (USDC per UTC
///      day; type(uint256).max for none), `maxTargetWei` (the most a refill tops the relayer up to) and
///      `maxSlippageBps` (never above 5 %).
///      Anyone may call `refill()`: the worst a stranger can do is top the relayer up when it was low
///      anyway, at a fair price, within the treasury's limits. No owner, no upgrade, no withdrawal
///      path; ETH or tokens sent here by mistake are not recoverable.
contract P2FluxGasRefill is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The price allowance can never be set above this (5 %).
    uint256 public constant MAX_SLIPPAGE_CEILING_BPS = 500;
    /// @notice After an L2 sequencer outage, prices are not trusted until it has been up this long.
    uint256 public constant SEQUENCER_GRACE = 1 hours;
    /// @notice The smallest refill, so a dust top-up never costs more gas than it brings (1 USDC).
    uint256 public constant MIN_REFILL_USDC = 1_000_000;

    IERC20 public immutable usdc;
    address public immutable weth;
    address public immutable treasury;
    address payable public immutable relayer;
    ISwapRouter02 public immutable router;
    uint24 public immutable poolFee;
    IAggregatorV3 public immutable ethUsdFeed;
    /// @notice Chainlink's L2 sequencer uptime feed; address(0) where the network has none (testnets).
    IAggregatorV3 public immutable sequencerFeed;
    uint256 public immutable refillBelowWei;
    uint256 public immutable maxOracleAge;

    uint256 public dailyCapUsdc;
    uint256 public maxTargetWei;
    uint256 public maxSlippageBps;

    /// @notice The UTC day of the last refill, and the USDC spent that day.
    uint256 public day;
    uint256 public spentToday;

    event Refilled(uint256 usdcIn, uint256 ethOut, uint256 relayerBalanceAfter);
    event LimitsSet(uint256 dailyCapUsdc, uint256 maxTargetWei, uint256 maxSlippageBps);

    error ZeroAddress();
    error BadParameter();
    error NotTreasury();
    error NotNeeded();
    error DailyLimit();
    error StalePrice();
    error BadPrice();
    error SequencerDown();
    error NotWeth();
    error EthTransferFailed();

    /// @notice Everything fixed at deployment, and the treasury's first limits.
    struct Params {
        address usdc;
        address weth;
        address treasury;
        address payable relayer;
        address router;
        uint24 poolFee;
        address ethUsdFeed;
        address sequencerFeed;
        uint256 refillBelowWei;
        uint256 maxOracleAge;
        uint256 dailyCapUsdc;
        uint256 maxTargetWei;
        uint256 maxSlippageBps;
    }

    constructor(Params memory p) {
        if (
            p.usdc == address(0) || p.weth == address(0) || p.treasury == address(0) || p.relayer == address(0)
                || p.router == address(0) || p.ethUsdFeed == address(0)
        ) revert ZeroAddress();
        if (p.refillBelowWei == 0 || p.maxOracleAge == 0 || p.maxOracleAge > 1 days) revert BadParameter();
        // The price arithmetic below assumes a USD feed with 8 decimals.
        if (IAggregatorV3(p.ethUsdFeed).decimals() != 8) revert BadParameter();
        usdc = IERC20(p.usdc);
        weth = p.weth;
        treasury = p.treasury;
        relayer = p.relayer;
        router = ISwapRouter02(p.router);
        poolFee = p.poolFee;
        ethUsdFeed = IAggregatorV3(p.ethUsdFeed);
        sequencerFeed = IAggregatorV3(p.sequencerFeed);
        refillBelowWei = p.refillBelowWei;
        maxOracleAge = p.maxOracleAge;
        _setLimits(p.dailyCapUsdc, p.maxTargetWei, p.maxSlippageBps);
    }

    /// @notice The treasury's own limits on how its USDC is spent. Only the treasury may change them.
    function setLimits(uint256 _dailyCapUsdc, uint256 _maxTargetWei, uint256 _maxSlippageBps) external {
        if (msg.sender != treasury) revert NotTreasury();
        _setLimits(_dailyCapUsdc, _maxTargetWei, _maxSlippageBps);
    }

    function _setLimits(uint256 _dailyCapUsdc, uint256 _maxTargetWei, uint256 _maxSlippageBps) private {
        // A target at or below the floor could never lift the relayer out of it.
        if (_dailyCapUsdc < MIN_REFILL_USDC || _maxTargetWei <= refillBelowWei || _maxSlippageBps > MAX_SLIPPAGE_CEILING_BPS) {
            revert BadParameter();
        }
        dailyCapUsdc = _dailyCapUsdc;
        maxTargetWei = _maxTargetWei;
        maxSlippageBps = _maxSlippageBps;
        emit LimitsSet(_dailyCapUsdc, _maxTargetWei, _maxSlippageBps);
    }

    /// @notice The Chainlink ETH/USD price (8 decimals), refusing a stale one or one during or just after an L2 sequencer outage.
    function price() public view returns (uint256) {
        if (address(sequencerFeed) != address(0)) {
            (, int256 status, uint256 upSince,,) = sequencerFeed.latestRoundData();
            // 0 = up. `startedAt` is when that status began.
            if (status != 0 || upSince == 0 || block.timestamp - upSince < SEQUENCER_GRACE) revert SequencerDown();
        }
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxOracleAge) revert StalePrice();
        return uint256(answer);
    }

    /// @notice USDC that would be swapped now to bring the relayer to `targetWei`, before the daily cap.
    function quote(uint256 targetWei) public view returns (uint256 usdcIn, uint256 target) {
        target = targetWei < maxTargetWei ? targetWei : maxTargetWei;
        uint256 balance = relayer.balance;
        if (target <= balance) return (0, target);
        // wei * price(8 dec) / 1e20 = USDC units (6 dec); rounded up so the target is reached.
        usdcIn = ((target - balance) * price() + 1e20 - 1) / 1e20;
        if (usdcIn < MIN_REFILL_USDC) usdcIn = MIN_REFILL_USDC;
    }

    /// @notice Refill the relayer up to `targetWei` (at most `maxTargetWei`) if it is below the floor.
    ///         Anyone may call it; it only ever pays the relayer.
    function refill(uint256 targetWei) external nonReentrant returns (uint256 ethOut) {
        if (relayer.balance >= refillBelowWei) revert NotNeeded();
        uint256 today = block.timestamp / 1 days;
        if (today != day) {
            day = today;
            spentToday = 0;
        }
        (uint256 usdcIn,) = quote(targetWei);
        if (usdcIn == 0) revert NotNeeded();
        uint256 left = dailyCapUsdc - spentToday;
        if (left < MIN_REFILL_USDC) revert DailyLimit();
        if (usdcIn > left) usdcIn = left;
        spentToday += usdcIn;

        // One division, last: usdcIn * 1e20 * 1e4 stays far inside uint256 for any real amount.
        uint256 minOut = (usdcIn * 1e20 * (10_000 - maxSlippageBps)) / (price() * 10_000);
        usdc.safeTransferFrom(treasury, address(this), usdcIn);
        usdc.forceApprove(address(router), usdcIn);
        uint256 wethOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: weth,
                fee: poolFee,
                recipient: address(this),
                amountIn: usdcIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IWETH9(weth).withdraw(wethOut);
        // Everything this contract holds in ETH goes to the relayer: nothing is meant to rest here.
        ethOut = address(this).balance;
        (bool ok,) = relayer.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
        emit Refilled(usdcIn, ethOut, relayer.balance);
    }

    /// @dev Only WETH unwrapping sends ETH here.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }
}
