// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITRC20Refill {
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev SunSwap V2 (a Uniswap V2 fork; TRX keeps the `ETH` names).
interface ISunSwapRouter {
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);
}

/// @title P2FluxTronRefill
/// @notice The gas treasury of `P2FluxTronVaults`: it receives the network costs buyers and merchants
///         reimburse (in USDT) and turns just enough of them into TRX for the relayer, which pays the
///         energy. The rest goes to P2Flux's cold treasury.
///
/// @dev Two things can happen to its USDT, and nothing else:
///        - `refill`: swapped to TRX on SunSwap, the TRX sent to the relayer - only while the relayer is
///          low on TRX, at most MAX_SWAP per swap and MAX_PER_DAY per day;
///        - `forward`: everything above KEEP sent to the cold treasury (anyone may call).
///      Only the relayer may refill, because it alone names `minOut` (from its own price view): a stolen
///      relayer key could at worst sell MAX_PER_DAY a day at a bad price. The admin (cold key) can only
///      rotate the relayer - the TRX must never keep flowing to a key that was replaced.
///      No owner withdrawal, not upgradeable.
contract P2FluxTronRefill {
    address public immutable token;
    address public immutable router;
    address public immutable wtrx;
    address public immutable coldTreasury;
    address public immutable admin;
    /// @notice Most USDT (6 decimals) one swap sells.
    uint256 public immutable maxSwap;
    /// @notice Most USDT sold per day (UTC-agnostic: a rolling day from the first swap of the window).
    uint256 public immutable maxPerDay;
    /// @notice A refill only while the relayer holds less TRX (sun) than this.
    uint256 public immutable lowWaterSun;
    /// @notice USDT kept here as the working balance; above it, `forward` sends to the cold treasury.
    uint256 public immutable keep;

    address public relayer;
    uint256 public windowStart;
    uint256 public soldInWindow;

    event Refilled(uint256 usdtIn, uint256 trxOut);
    event Forwarded(uint256 amount);
    event RelayerChanged(address relayer);

    error ZeroAddress();
    error NotRelayer();
    error NotAdmin();
    error RelayerNotLow();
    error TooMuch();
    error ApproveFailed();
    error TransferFailed();

    constructor(
        address _token,
        address _router,
        address _wtrx,
        address _relayer,
        address _coldTreasury,
        address _admin,
        uint256 _maxSwap,
        uint256 _maxPerDay,
        uint256 _lowWaterSun,
        uint256 _keep
    ) {
        if (
            _token == address(0) || _router == address(0) || _wtrx == address(0) || _relayer == address(0)
                || _coldTreasury == address(0) || _admin == address(0)
        ) revert ZeroAddress();
        token = _token;
        router = _router;
        wtrx = _wtrx;
        relayer = _relayer;
        coldTreasury = _coldTreasury;
        admin = _admin;
        maxSwap = _maxSwap;
        maxPerDay = _maxPerDay;
        lowWaterSun = _lowWaterSun;
        keep = _keep;
    }

    function setRelayer(address _relayer) external {
        if (msg.sender != admin) revert NotAdmin();
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
        emit RelayerChanged(_relayer);
    }

    /// @notice Sell `amountIn` USDT for at least `minOut` TRX, paid to the relayer.
    function refill(uint256 amountIn, uint256 minOut) external {
        address to = relayer;
        if (msg.sender != to) revert NotRelayer();
        if (to.balance >= lowWaterSun) revert RelayerNotLow();
        if (amountIn == 0 || amountIn > maxSwap) revert TooMuch();
        if (block.timestamp >= windowStart + 1 days) {
            windowStart = block.timestamp;
            soldInWindow = 0;
        }
        if (soldInWindow + amountIn > maxPerDay) revert TooMuch();
        soldInWindow += amountIn;

        // Exactly this swap's amount, judged by the allowance itself (Tron USDT's return values are not trusted).
        (bool ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", router, amountIn));
        if (!ok || ITRC20Refill(token).allowance(address(this), router) != amountIn) revert ApproveFailed();

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wtrx;
        uint256 before = to.balance;
        ISunSwapRouter(router).swapExactTokensForETH(amountIn, minOut, path, to, block.timestamp);
        emit Refilled(amountIn, to.balance - before);
    }

    /// @notice Send everything above the working balance to the cold treasury. Anyone may call.
    function forward() external {
        uint256 held = ITRC20Refill(token).balanceOf(address(this));
        if (held <= keep) return;
        uint256 amount = held - keep;
        uint256 before = ITRC20Refill(token).balanceOf(coldTreasury);
        (bool ok, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", coldTreasury, amount));
        if (!ok || ITRC20Refill(token).balanceOf(coldTreasury) != before + amount) revert TransferFailed();
        emit Forwarded(amount);
    }
}
