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
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title P2FluxGasRefill
/// @notice Keeps the P2Flux relayer in gas from P2Flux's own USDC: when the relayer runs low, a fixed
///         amount of USDC is taken from the gas treasury (which collects the network fees paid for
///         exactly this), swapped to ETH on Uniswap and sent to the relayer.
///
/// @dev Everything that matters is fixed at deployment and cannot be changed by anyone:
///        - the ETH goes to `relayer` and nowhere else;
///        - USDC comes only from `treasury`, and only as far as the treasury has approved this contract
///          (the treasury's owner sets, raises or revokes that allowance with its own key);
///        - a refill happens only while the relayer holds less than `refillBelowWei`;
///        - each refill is exactly `refillUsdc`, at most `maxRefillsPerDay` per UTC day;
///        - the swap must return at least the Chainlink price less `maxSlippageBps`, from a price no
///          older than `maxOracleAge`.
///      So anyone may call `refill()`: the worst a stranger can do is trigger a refill the relayer
///      needed anyway, at a fair price. No owner, no pause, no upgrade, no withdrawal path. ETH or
///      tokens sent here by mistake are not recoverable - nothing is meant to rest here.
contract P2FluxGasRefill is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable weth;
    address public immutable treasury;
    address payable public immutable relayer;
    ISwapRouter02 public immutable router;
    uint24 public immutable poolFee;
    IAggregatorV3 public immutable ethUsdFeed;
    uint256 public immutable refillUsdc;
    uint256 public immutable refillBelowWei;
    uint256 public immutable maxRefillsPerDay;
    uint256 public immutable maxSlippageBps;
    uint256 public immutable maxOracleAge;

    /// @notice The UTC day of the last refill, and how many refills that day has had.
    uint256 public day;
    uint256 public refillsToday;

    event Refilled(uint256 usdcIn, uint256 ethOut, uint256 relayerBalanceAfter);

    error ZeroAddress();
    error BadParameter();
    error NotNeeded();
    error DailyLimit();
    error StalePrice();
    error BadPrice();
    error NotWeth();
    error EthTransferFailed();

    constructor(
        address _usdc,
        address _weth,
        address _treasury,
        address payable _relayer,
        address _router,
        uint24 _poolFee,
        address _ethUsdFeed,
        uint256 _refillUsdc,
        uint256 _refillBelowWei,
        uint256 _maxRefillsPerDay,
        uint256 _maxSlippageBps,
        uint256 _maxOracleAge
    ) {
        if (
            _usdc == address(0) || _weth == address(0) || _treasury == address(0) || _relayer == address(0)
                || _router == address(0) || _ethUsdFeed == address(0)
        ) revert ZeroAddress();
        if (
            _refillUsdc == 0 || _refillUsdc > 1_000_000_000 || _refillBelowWei == 0 || _maxRefillsPerDay == 0
                || _maxRefillsPerDay > 24 || _maxSlippageBps > 2_000 || _maxOracleAge == 0 || _maxOracleAge > 1 days
        ) revert BadParameter();
        usdc = IERC20(_usdc);
        weth = _weth;
        treasury = _treasury;
        relayer = _relayer;
        router = ISwapRouter02(_router);
        poolFee = _poolFee;
        ethUsdFeed = IAggregatorV3(_ethUsdFeed);
        refillUsdc = _refillUsdc;
        refillBelowWei = _refillBelowWei;
        maxRefillsPerDay = _maxRefillsPerDay;
        maxSlippageBps = _maxSlippageBps;
        maxOracleAge = _maxOracleAge;
    }

    /// @notice The least ETH a refill must return: `refillUsdc` at the Chainlink price, less the slippage allowance.
    function minEthOut() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxOracleAge) revert StalePrice();
        // USDC has 6 decimals, the feed 8, ETH 18: wei = usdc * 1e12 * 1e8 / answer, less the allowance.
        // One division, last: at most 1e9 * 1e20 * 1e4 before it, far inside uint256.
        return (refillUsdc * 1e20 * (10_000 - maxSlippageBps)) / (uint256(answer) * 10_000);
    }

    /// @notice Refill the relayer if it is low. Anyone may call it; it only ever pays the relayer.
    function refill() external nonReentrant returns (uint256 ethOut) {
        if (relayer.balance >= refillBelowWei) revert NotNeeded();
        uint256 today = block.timestamp / 1 days;
        if (today != day) {
            day = today;
            refillsToday = 0;
        }
        if (refillsToday >= maxRefillsPerDay) revert DailyLimit();
        refillsToday++;

        uint256 minOut = minEthOut();
        usdc.safeTransferFrom(treasury, address(this), refillUsdc);
        usdc.forceApprove(address(router), refillUsdc);
        uint256 wethOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: weth,
                fee: poolFee,
                recipient: address(this),
                amountIn: refillUsdc,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IWETH9(weth).withdraw(wethOut);
        // Everything this contract holds in ETH goes to the relayer: nothing is meant to rest here.
        ethOut = address(this).balance;
        (bool ok,) = relayer.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
        emit Refilled(refillUsdc, ethOut, relayer.balance);
    }

    /// @dev Only WETH unwrapping sends ETH here.
    receive() external payable {
        if (msg.sender != weth) revert NotWeth();
    }
}
