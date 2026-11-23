// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {P2FluxTest} from "../Helpers.sol";
import {P2FluxFeeRegistry} from "../../../contracts/v2/P2FluxFeeRegistry.sol";

/// @notice v2 fixtures: a registry at the owner-agreed prices of 23 Nov 2026, and timelock helpers.
abstract contract V2Test is P2FluxTest {
    P2FluxFeeRegistry internal registry;

    uint256 internal constant ONE_TIME_BPS = 100;
    uint256 internal constant ONE_TIME_PARTNER_BPS = 75;
    uint256 internal constant RECURRING_BPS = 150;
    uint256 internal constant RECURRING_PARTNER_BPS = 125;
    uint256 internal constant SEND_BPS = 10;
    uint256 internal constant FIXED_FEE = 50_000; // 0.05 USDC
    uint256 internal constant NETWORK_CAP = 250_000; // 0.25 USDC

    address internal partner = makeAddr("partner");

    function _v2SetUp() internal {
        _baseSetUp();
        registry = new P2FluxFeeRegistry(
            admin,
            P2FluxFeeRegistry.Rate(uint16(ONE_TIME_BPS), uint16(ONE_TIME_PARTNER_BPS), uint64(FIXED_FEE)),
            P2FluxFeeRegistry.Rate(uint16(RECURRING_BPS), uint16(RECURRING_PARTNER_BPS), uint64(FIXED_FEE)),
            P2FluxFeeRegistry.Rate(uint16(SEND_BPS), uint16(SEND_BPS), uint64(FIXED_FEE))
        );
        _listPartner(partner, true);
    }

    function _listPartner(address who, bool value) internal {
        address[] memory list = new address[](1);
        list[0] = who;
        vm.prank(admin);
        registry.schedulePartners(list, value);
        vm.warp(block.timestamp + registry.DELAY());
        registry.executePartners(list);
    }

    function _setRate(P2FluxFeeRegistry.Kind kind, uint256 bps, uint256 partnerBps, uint256 fixedFee) internal {
        vm.prank(admin);
        registry.scheduleRate(kind, P2FluxFeeRegistry.Rate(uint16(bps), uint16(partnerBps), uint64(fixedFee)));
        vm.warp(block.timestamp + registry.DELAY());
        registry.executeRate(kind);
    }
}

/// @notice A broken token whose receiveWithAuthorization credits one unit more than asked. Only
///         used to prove the "leave no more than found" guard fires.
contract OverpayToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function receiveWithAuthorization(
        address,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32,
        uint8,
        bytes32,
        bytes32
    ) external {
        balanceOf[to] += value + 1;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }
}
