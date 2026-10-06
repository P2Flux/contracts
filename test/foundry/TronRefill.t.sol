// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxTronRefill} from "../../contracts/tron/P2FluxTronRefill.sol";

contract UsdtMock {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return false; // Tron USDT's quirk
    }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// A SunSwap router at a fixed price (1 USDT unit -> `rate` sun), honouring amountOutMin.
contract RouterMock {
    uint256 public rate = 3; // 1 USDT ~ 3 TRX
    function setRate(uint256 r) external { rate = r; }
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        UsdtMock(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        require(out >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        (bool ok, ) = to.call{value: out}("");
        require(ok, "TRX");
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
    receive() external payable {}
}

contract TronRefillTest is Test {
    UsdtMock usdt;
    RouterMock router;
    P2FluxTronRefill refill;
    address relayer = address(0xBEEF);
    address cold = address(0xC01D);
    address admin = address(0xAD);

    function setUp() public {
        usdt = new UsdtMock();
        router = new RouterMock();
        vm.deal(address(router), 1e30);
        refill = new P2FluxTronRefill(address(usdt), address(router), address(0x77), relayer, cold, admin, 50e6, 100e6, 200e6, 20e6);
        usdt.mint(address(refill), 300e6);
        vm.warp(1_800_000_000);
    }

    function test_refills_the_relayer_when_low() public {
        vm.prank(relayer);
        refill.refill(30e6, 90e6);
        assertEq(relayer.balance, 90e6);
        assertEq(usdt.balanceOf(address(refill)), 270e6);
        assertEq(usdt.allowance(address(refill), address(router)), 0, "no allowance left over");
    }

    function test_only_the_relayer_and_only_when_low() public {
        vm.expectRevert(P2FluxTronRefill.NotRelayer.selector);
        refill.refill(1e6, 0);
        vm.deal(relayer, 200e6);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronRefill.RelayerNotLow.selector);
        refill.refill(1e6, 0);
    }

    function test_per_swap_and_per_day_limits() public {
        vm.startPrank(relayer);
        vm.expectRevert(P2FluxTronRefill.TooMuch.selector);
        refill.refill(50e6 + 1, 0);
        refill.refill(50e6, 0);
        vm.deal(relayer, 0);
        refill.refill(50e6, 0);
        vm.deal(relayer, 0);
        vm.expectRevert(P2FluxTronRefill.TooMuch.selector);
        refill.refill(1, 0);
        vm.warp(block.timestamp + 1 days);
        refill.refill(50e6, 0);
        vm.stopPrank();
    }

    function test_min_out_protects_the_price() public {
        router.setRate(1);
        vm.prank(relayer);
        vm.expectRevert(bytes("INSUFFICIENT_OUTPUT_AMOUNT"));
        refill.refill(10e6, 30e6);
        assertEq(usdt.balanceOf(address(refill)), 300e6);
    }

    function test_forward_keeps_the_working_balance_and_sends_the_rest_to_cold() public {
        vm.prank(address(0x1234));
        refill.forward();
        assertEq(usdt.balanceOf(cold), 280e6);
        assertEq(usdt.balanceOf(address(refill)), 20e6);
        refill.forward(); // nothing above keep: no-op
        assertEq(usdt.balanceOf(cold), 280e6);
    }

    function test_relayer_rotation_admin_only_and_trx_follows() public {
        vm.expectRevert(P2FluxTronRefill.NotAdmin.selector);
        refill.setRelayer(address(1));
        address next = address(0xBEE2);
        vm.prank(admin);
        refill.setRelayer(next);
        vm.prank(relayer);
        vm.expectRevert(P2FluxTronRefill.NotRelayer.selector);
        refill.refill(1e6, 0);
        vm.prank(next);
        refill.refill(1e6, 0);
        assertEq(next.balance, 3e6);
        assertEq(relayer.balance, 0);
    }

    /// Whatever the relayer asks, USDT leaves only as a refill within the limits or to the cold treasury.
    function testFuzz_usdt_only_leaves_within_limits(uint96[6] calldata asks, bool[6] calldata forwards) public {
        uint256 swapped;
        for (uint256 i = 0; i < 6; i++) {
            vm.deal(relayer, 0);
            uint256 amount = uint256(asks[i]) % (60e6);
            vm.prank(relayer);
            try refill.refill(amount, 0) {
                swapped += amount;
            } catch {}
            if (forwards[i]) refill.forward();
        }
        assertLe(swapped, 100e6, "per-day cap");
        assertEq(usdt.balanceOf(address(refill)) + usdt.balanceOf(cold) + usdt.balanceOf(address(router)), 300e6);
        assertEq(usdt.balanceOf(address(router)), swapped);
    }
}
