// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockUSDC} from "./MockTokens.sol";

/// @notice WETH for tests: holds ETH, `withdraw` sends it to the caller.
contract MockWETH {
    mapping(address => uint256) public balanceOf;

    receive() external payable {}

    function mintTo(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }
}

/// @notice A Uniswap-like router that pays `wethPerUsdc` (18-decimal WETH per 1e6 USDC) and honours amountOutMinimum.
contract MockRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    MockWETH public immutable weth;
    uint256 public wethPerUsdc;

    constructor(MockWETH _weth) {
        weth = _weth;
    }

    function setRate(uint256 _wethPerUsdc) external {
        wethPerUsdc = _wethPerUsdc;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        MockUSDC(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = (p.amountIn * wethPerUsdc) / 1e6;
        require(out >= p.amountOutMinimum, "Too little received");
        weth.mintTo(p.recipient, out);
    }
}

/// @notice A Chainlink-like feed with a settable answer and timestamp.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
