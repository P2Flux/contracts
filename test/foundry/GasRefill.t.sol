// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxGasRefill} from "../../contracts/P2FluxGasRefill.sol";
import {MockUSDC} from "../../contracts/test/MockTokens.sol";
import {MockWETH, MockRouter, MockFeed} from "../../contracts/test/MockRefill.sol";

/// @notice The gas refill: ETH only to the relayer, only when it is low, at a fair price, within the
///         treasury's allowance and the daily limit - whoever calls it.
contract GasRefillTest is Test {
    MockUSDC internal usdc;
    MockWETH internal weth;
    MockRouter internal router;
    MockFeed internal feed;
    P2FluxGasRefill internal refill;
    address internal treasury = makeAddr("treasury");
    address payable internal relayer = payable(makeAddr("relayer"));
    address internal stranger = makeAddr("stranger");

    uint256 internal constant TEN_USDC = 10_000_000;
    uint256 internal constant BELOW = 0.003 ether;
    // 2500 USD per ETH: 10 USDC = 0.004 ETH.
    int256 internal constant PRICE = 2500e8;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        router = new MockRouter(weth);
        feed = new MockFeed();
        vm.deal(address(weth), 100 ether);
        feed.set(PRICE, block.timestamp);
        router.setRate(0.0004 ether); // 1 USDC -> 0.0004 ETH, the fair price
        refill = new P2FluxGasRefill(
            address(usdc), address(weth), treasury, relayer, address(router), 500, address(feed), TEN_USDC, BELOW, 3, 300, 3 hours
        );
        usdc.mint(treasury, 1_000_000_000);
        vm.prank(treasury);
        usdc.approve(address(refill), 200_000_000);
        vm.deal(relayer, 0.001 ether);
    }

    function test_refill_sendsEthToTheRelayer_andTakesExactlyTheRefillFromTheTreasury() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(stranger);
        uint256 out = refill.refill();
        assertEq(out, 0.004 ether);
        assertEq(relayer.balance, 0.005 ether);
        assertEq(treasuryBefore - usdc.balanceOf(treasury), TEN_USDC);
        assertEq(address(refill).balance, 0, "nothing rests in the contract");
        assertEq(usdc.balanceOf(address(refill)), 0);
        assertEq(stranger.balance, 0, "the caller gets nothing");
    }

    function test_refill_onlyWhenTheRelayerIsLow() public {
        vm.deal(relayer, BELOW);
        vm.expectRevert(P2FluxGasRefill.NotNeeded.selector);
        refill.refill();
    }

    function test_refill_atMostNPerDay_andAgainTheNextDay() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(relayer, 0);
            refill.refill();
        }
        vm.deal(relayer, 0);
        vm.expectRevert(P2FluxGasRefill.DailyLimit.selector);
        refill.refill();
        vm.warp(block.timestamp + 1 days);
        feed.set(PRICE, block.timestamp);
        refill.refill();
        assertEq(refill.refillsToday(), 1);
    }

    function test_refill_neverMoreThanTheTreasuryAllowed() public {
        vm.prank(treasury);
        usdc.approve(address(refill), TEN_USDC - 1);
        vm.expectRevert();
        refill.refill();
        // Revoked: nothing can be taken at all.
        vm.prank(treasury);
        usdc.approve(address(refill), 0);
        vm.expectRevert();
        refill.refill();
    }

    function test_refill_refusesABadPrice() public {
        router.setRate(0.000387 ether); // 3.25 % below fair: past the 3 % allowance
        vm.expectRevert(bytes("Too little received"));
        refill.refill();
        router.setRate(0.000389 ether); // 2.75 % below: inside it
        refill.refill();
    }

    function test_refill_refusesAStaleOrBrokenPrice() public {
        feed.set(PRICE, block.timestamp - 3 hours - 1);
        vm.expectRevert(P2FluxGasRefill.StalePrice.selector);
        refill.refill();
        feed.set(PRICE, block.timestamp + 1);
        vm.expectRevert(P2FluxGasRefill.StalePrice.selector);
        refill.refill();
        feed.set(0, block.timestamp);
        vm.expectRevert(P2FluxGasRefill.BadPrice.selector);
        refill.refill();
        feed.set(-1, block.timestamp);
        vm.expectRevert(P2FluxGasRefill.BadPrice.selector);
        refill.refill();
    }

    function test_onlyWethMaySendEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(refill).call{value: 1}("");
        assertFalse(ok);
    }

    function test_constructor_refusesZeroAddressesAndUnsafeParameters() public {
        vm.expectRevert(P2FluxGasRefill.ZeroAddress.selector);
        new P2FluxGasRefill(address(usdc), address(weth), treasury, payable(address(0)), address(router), 500, address(feed), TEN_USDC, BELOW, 3, 300, 3 hours);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(address(usdc), address(weth), treasury, relayer, address(router), 500, address(feed), TEN_USDC, BELOW, 3, 2_001, 3 hours);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(address(usdc), address(weth), treasury, relayer, address(router), 500, address(feed), 1_000_000_001, BELOW, 3, 300, 3 hours);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(address(usdc), address(weth), treasury, relayer, address(router), 500, address(feed), TEN_USDC, BELOW, 25, 300, 3 hours);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(address(usdc), address(weth), treasury, relayer, address(router), 500, address(feed), TEN_USDC, BELOW, 3, 300, 2 days);
    }

    /// @notice Whoever calls, whatever the rate the pool offers: the treasury loses at most the refill,
    ///         ETH only reaches the relayer, and nothing is ever below the price allowance.
    function testFuzz_refill_onlyEverPaysTheRelayer(address caller, uint256 rate, uint256 relayerStart) public {
        vm.assume(caller != relayer && caller != address(refill) && caller != treasury && caller != address(weth) && caller != address(router));
        rate = bound(rate, 0.0001 ether, 0.001 ether);
        relayerStart = bound(relayerStart, 0, BELOW - 1);
        router.setRate(rate);
        vm.deal(relayer, relayerStart);
        uint256 callerEth = caller.balance;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(caller);
        try refill.refill() returns (uint256 out) {
            assertEq(relayer.balance, relayerStart + out);
            assertGe(out, (0.004 ether * 9_700) / 10_000);
            assertEq(treasuryBefore - usdc.balanceOf(treasury), TEN_USDC);
        } catch {
            assertEq(relayer.balance, relayerStart);
            assertEq(usdc.balanceOf(treasury), treasuryBefore);
            assertLt(rate, 0.000388 ether, "refused only below the allowance");
        }
        assertEq(caller.balance, callerEth);
        assertEq(address(refill).balance, 0);
    }
}

/// @notice The same refill against the REAL Uniswap v3, WETH, USDC and Chainlink feed on a fork of Base.
///         Reads chain state, sends nothing:
///           BASE_MAINNET_RPC_URL=https://mainnet.base.org forge test --match-contract GasRefillMainnetFork
contract GasRefillMainnetFork is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant TREASURY = 0xdCdE2146cF3ab9aE37933211AF8943c807c31506;
    address payable constant RELAYER = payable(0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309);

    function test_fork_mainnet_refill_realUniswapRealPrice() public {
        string memory rpc = vm.envOr("BASE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        P2FluxGasRefill refill = new P2FluxGasRefill(USDC, WETH, TREASURY, RELAYER, ROUTER, 500, FEED, 10_000_000, 0.003 ether, 3, 300, 3 hours);
        deal(USDC, TREASURY, 100_000_000);
        vm.prank(TREASURY);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(refill), 100_000_000));
        assertTrue(ok);
        vm.deal(RELAYER, 0.001 ether);
        uint256 min = refill.minEthOut();
        uint256 out = refill.refill();
        assertGe(out, min);
        assertEq(RELAYER.balance, 0.001 ether + out);
        emit log_named_uint("ETH out for 10 USDC (wei)", out);
    }
}
