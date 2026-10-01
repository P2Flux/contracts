// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {P2FluxGasRefill} from "../../contracts/P2FluxGasRefill.sol";
import {MockUSDC} from "../../contracts/test/MockTokens.sol";
import {MockWETH, MockRouter, MockFeed} from "../../contracts/test/MockRefill.sol";

/// @notice The gas refill: ETH only to the relayer, only below the floor, up to a target, at a fair
///         price, within the treasury's allowance and daily cap - whoever calls it. Limits change only
///         by the treasury.
contract GasRefillTest is Test {
    MockUSDC internal usdc;
    MockWETH internal weth;
    MockRouter internal router;
    MockFeed internal feed;
    MockFeed internal sequencer;
    P2FluxGasRefill internal refill;
    address internal treasury = makeAddr("treasury");
    address payable internal relayer = payable(makeAddr("relayer"));
    address internal stranger = makeAddr("stranger");

    uint256 internal constant FLOOR = 0.01 ether;
    uint256 internal constant CEILING = 0.05 ether;
    uint256 internal constant CAP = 100_000_000; // 100 USDC a day
    // 2500 USD per ETH: 1 USDC = 0.0004 ETH.
    int256 internal constant PRICE = 2500e8;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        router = new MockRouter(weth);
        feed = new MockFeed();
        sequencer = new MockFeed();
        vm.deal(address(weth), 1000 ether);
        feed.set(PRICE, block.timestamp);
        sequencer.set(0, block.timestamp - 2 hours); // up for two hours
        router.setRate(0.0004 ether); // the fair price
        refill = _deploy(address(sequencer));
        usdc.mint(treasury, 1_000_000_000_000);
        vm.prank(treasury);
        usdc.approve(address(refill), type(uint256).max);
        vm.deal(relayer, 0.002 ether);
    }

    function _deploy(address seq) internal returns (P2FluxGasRefill) {
        return new P2FluxGasRefill(_params(seq, FLOOR, 1 hours, 300));
    }

    function _params(address seq, uint256 floor, uint256 age, uint256 slippage) internal view returns (P2FluxGasRefill.Params memory) {
        return P2FluxGasRefill.Params({
            usdc: address(usdc), weth: address(weth), treasury: treasury, relayer: relayer, router: address(router), poolFee: 500,
            ethUsdFeed: address(feed), sequencerFeed: seq, refillBelowWei: floor, maxOracleAge: age,
            dailyCapUsdc: CAP, maxTargetWei: CEILING, maxSlippageBps: slippage
        });
    }

    function test_refill_topsUpToTheTarget_takingWhatThatCosts() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(stranger);
        uint256 out = refill.refill(0.02 ether);
        // 0.018 ETH missing at 2500 USD = 45 USDC.
        assertEq(treasuryBefore - usdc.balanceOf(treasury), 45_000_000);
        assertEq(out, 0.018 ether);
        assertEq(relayer.balance, 0.02 ether);
        assertEq(refill.spentToday(), 45_000_000);
        assertEq(address(refill).balance, 0, "nothing rests in the contract");
        assertEq(stranger.balance, 0, "the caller gets nothing");
    }

    function test_refill_targetNeverAboveTheCeiling() public {
        vm.prank(treasury);
        refill.setLimits(1_000_000_000, CEILING, 300); // a cap that is not the limit here
        refill.refill(10 ether);
        assertEq(relayer.balance, CEILING);
    }

    function test_refill_onlyBelowTheFloor() public {
        vm.deal(relayer, FLOOR);
        vm.expectRevert(P2FluxGasRefill.NotNeeded.selector);
        refill.refill(0.02 ether);
    }

    function test_refill_aTargetBelowTheBalanceIsNotARefill() public {
        vm.expectRevert(P2FluxGasRefill.NotNeeded.selector);
        refill.refill(0.001 ether);
    }

    function test_refill_atLeastOneUsdc() public {
        vm.deal(relayer, 0.0099 ether);
        refill.refill(0.0099 ether + 1); // a wei short of nothing: still 1 USDC
        assertEq(refill.spentToday(), 1_000_000);
    }

    function test_refill_dailyCapInUsdc_partialThenRefused_andAgainTheNextDay() public {
        // 0.05 - 0.002 = 0.048 ETH = 120 USDC wanted; the cap allows 100.
        refill.refill(CEILING);
        assertEq(refill.spentToday(), CAP);
        assertEq(relayer.balance, 0.002 ether + 0.04 ether);
        vm.deal(relayer, 0);
        vm.expectRevert(P2FluxGasRefill.DailyLimit.selector);
        refill.refill(0.02 ether);
        vm.warp(block.timestamp + 1 days);
        feed.set(PRICE, block.timestamp);
        refill.refill(0.02 ether);
        assertEq(refill.spentToday(), 50_000_000);
    }

    function test_setLimits_onlyTheTreasury_andWithinBounds() public {
        vm.prank(stranger);
        vm.expectRevert(P2FluxGasRefill.NotTreasury.selector);
        refill.setLimits(type(uint256).max, 1 ether, 300);
        vm.startPrank(treasury);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        refill.setLimits(CAP, CEILING, 501); // allowance above 5 %
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        refill.setLimits(CAP, FLOOR, 300); // a ceiling at the floor lifts nothing
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        refill.setLimits(999_999, CEILING, 300); // a cap below one refill
        // Grows with traffic, up to no cap at all.
        refill.setLimits(type(uint256).max, 1 ether, 300);
        vm.stopPrank();
        assertEq(refill.dailyCapUsdc(), type(uint256).max);
        refill.refill(1 ether);
        assertEq(relayer.balance, 1 ether);
    }

    function test_refill_neverMoreThanTheTreasuryAllowed() public {
        vm.prank(treasury);
        usdc.approve(address(refill), 1_000_000);
        vm.expectRevert();
        refill.refill(0.02 ether);
        vm.prank(treasury);
        usdc.approve(address(refill), 0);
        vm.expectRevert();
        refill.refill(0.0099 ether);
    }

    function test_refill_refusesABadPrice() public {
        router.setRate(0.000387 ether); // 3.25 % below fair: past the 3 % allowance
        vm.expectRevert(bytes("Too little received"));
        refill.refill(0.02 ether);
        router.setRate(0.000389 ether); // 2.75 % below: inside it
        refill.refill(0.02 ether);
    }

    function test_refill_refusesAStaleOrBrokenPrice() public {
        feed.set(PRICE, block.timestamp - 1 hours - 1);
        vm.expectRevert(P2FluxGasRefill.StalePrice.selector);
        refill.refill(0.02 ether);
        feed.set(PRICE, block.timestamp + 1);
        vm.expectRevert(P2FluxGasRefill.StalePrice.selector);
        refill.refill(0.02 ether);
        feed.set(0, block.timestamp);
        vm.expectRevert(P2FluxGasRefill.BadPrice.selector);
        refill.refill(0.02 ether);
        feed.set(-1, block.timestamp);
        vm.expectRevert(P2FluxGasRefill.BadPrice.selector);
        refill.refill(0.02 ether);
    }

    function test_refill_waitsAnHourAfterAnL2SequencerOutage() public {
        sequencer.set(1, block.timestamp - 3 hours); // down
        vm.expectRevert(P2FluxGasRefill.SequencerDown.selector);
        refill.refill(0.02 ether);
        sequencer.set(0, block.timestamp - 59 minutes); // up, but not for an hour
        vm.expectRevert(P2FluxGasRefill.SequencerDown.selector);
        refill.refill(0.02 ether);
        sequencer.set(0, block.timestamp - 61 minutes);
        refill.refill(0.02 ether);
    }

    function test_noSequencerFeed_onNetworksWithoutOne() public {
        P2FluxGasRefill r = _deploy(address(0));
        vm.prank(treasury);
        usdc.approve(address(r), type(uint256).max);
        sequencer.set(1, block.timestamp); // would refuse, but is not used
        r.refill(0.02 ether);
        assertEq(relayer.balance, 0.02 ether);
    }

    function test_constructor_refusesAFeedThatIsNotEightDecimals() public {
        feed.setDecimals(18);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        _deploy(address(sequencer));
    }

    function test_constructor_refusesZeroAddressesAndUnsafeParameters() public {
        P2FluxGasRefill.Params memory p = _params(address(0), FLOOR, 1 hours, 300);
        p.relayer = payable(address(0));
        vm.expectRevert(P2FluxGasRefill.ZeroAddress.selector);
        new P2FluxGasRefill(p);
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(_params(address(0), FLOOR, 2 days, 300));
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(_params(address(0), FLOOR, 1 hours, 600));
        vm.expectRevert(P2FluxGasRefill.BadParameter.selector);
        new P2FluxGasRefill(_params(address(0), CEILING, 1 hours, 300)); // floor at the ceiling
    }

    function test_onlyWethMaySendEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(refill).call{value: 1}("");
        assertFalse(ok);
    }

    /// @notice Whoever calls, whatever target and pool rate: ETH only reaches the relayer, the treasury
    ///         loses at most the day's cap, never below the price allowance, the relayer never above the ceiling.
    function testFuzz_refill_onlyEverPaysTheRelayer(address caller, uint256 target, uint256 rate, uint256 relayerStart) public {
        vm.assume(caller != relayer && caller != address(refill) && caller != treasury && caller != address(weth) && caller != address(router));
        rate = bound(rate, 0.0001 ether, 0.001 ether);
        relayerStart = bound(relayerStart, 0, FLOOR - 1);
        target = bound(target, 0, 100 ether);
        router.setRate(rate);
        vm.deal(relayer, relayerStart);
        uint256 callerEth = caller.balance;
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(caller);
        try refill.refill(target) returns (uint256 out) {
            assertEq(relayer.balance, relayerStart + out);
            uint256 spent = treasuryBefore - usdc.balanceOf(treasury);
            assertLe(spent, CAP);
            assertGe(out, (spent * 0.0004 ether * 9_700) / 10_000 / 1e6);
            if (rate == 0.0004 ether) assertLe(relayer.balance, CEILING + 0.0004 ether);
        } catch {
            assertEq(relayer.balance, relayerStart);
            assertEq(usdc.balanceOf(treasury), treasuryBefore);
        }
        assertEq(caller.balance, callerEth);
        assertEq(address(refill).balance, 0);
    }
}

/// @notice The same refill against the REAL Uniswap v3, WETH, USDC, Chainlink price feed and L2
///         sequencer feed on a fork of Base. Reads chain state, sends nothing:
///           BASE_MAINNET_RPC_URL=https://mainnet.base.org forge test --match-contract GasRefillMainnetFork
contract GasRefillMainnetFork is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant TREASURY = 0xdCdE2146cF3ab9aE37933211AF8943c807c31506;
    address payable constant RELAYER = payable(0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309);

    function test_fork_mainnet_refill_realUniswapRealPriceRealSequencer() public {
        string memory rpc = vm.envOr("BASE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        P2FluxGasRefill refill = new P2FluxGasRefill(
            P2FluxGasRefill.Params({
                usdc: USDC, weth: WETH, treasury: TREASURY, relayer: RELAYER, router: ROUTER, poolFee: 500, ethUsdFeed: FEED,
                sequencerFeed: SEQUENCER, refillBelowWei: 0.01 ether, maxOracleAge: 1 hours, dailyCapUsdc: 100_000_000,
                maxTargetWei: 0.05 ether, maxSlippageBps: 300
            })
        );
        deal(USDC, TREASURY, 1_000_000_000);
        vm.prank(TREASURY);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(refill), 200_000_000));
        assertTrue(ok);
        vm.deal(RELAYER, 0.001 ether);
        (uint256 usdcIn,) = refill.quote(0.02 ether);
        uint256 out = refill.refill(0.02 ether);
        assertEq(RELAYER.balance, 0.001 ether + out);
        assertGe(out, (0.019 ether * 9_700) / 10_000);
        emit log_named_uint("USDC in (units)", usdcIn);
        emit log_named_uint("ETH out (wei)", out);
        emit log_named_uint("ETH/USD (8 dec)", refill.price());
    }
}
