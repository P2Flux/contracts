// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockFiatToken} from "../../../../contracts/test/MockTokens.sol";
import {P2FluxFeeRegistry as Reg} from "../../../../contracts/v2/P2FluxFeeRegistry.sol";
import {P2FluxPaymentsV2 as Sponsored} from "../../../../contracts/v2/P2FluxPaymentsV2.sol";

/// @notice Symbolic checks for halmos (`check_` prefix; forge ignores them). Every legal rate at once:
///         halmos --root . --match-contract ReviewHalmos --solver-timeout-assertion 0
contract ReviewHalmos is Test {
    /// minimumAmount is the exact boundary for every (bps, fixedFee) inside the caps.
    function check_minimumAmountExact(uint16 bps, uint64 fixedFee) public {
        vm.assume(bps <= 200 && fixedFee <= 0.2e6);
        MockFiatToken t = new MockFiatToken();
        Reg r = new Reg(address(1), Reg.Rate(bps, bps, fixedFee), Reg.Rate(0, 0, 0), Reg.Rate(0, 0, 0));
        Sponsored s = new Sponsored(address(t), address(2), address(3), address(4), address(r), 0);
        uint256 m = s.minimumAmount(address(5));
        assert(m - (m * bps) / 10_000 > fixedFee);
        assert((m - 1) - ((m - 1) * bps) / 10_000 <= fixedFee);
    }

    /// The registry can never hold a rate outside the caps, whatever the constructor is given.
    function check_registryCaps(uint16 bps, uint16 pbps, uint64 fixedFee) public {
        Reg r = new Reg(address(1), Reg.Rate(bps, pbps, fixedFee), Reg.Rate(0, 0, 0), Reg.Rate(0, 0, 0));
        (uint256 b, uint256 f) = r.feeFor(Reg.Kind.OneTime, address(5));
        assert(b <= 200 && f <= 0.2e6 && pbps <= bps);
    }
}
