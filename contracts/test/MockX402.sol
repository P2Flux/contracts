// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISignatureTransfer, IX402UptoPermit2Proxy} from "../P2FluxX402Splitter.sol";

interface IPullToken {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @notice Stands in for x402UptoPermit2Proxy + Permit2 in unit tests. It reproduces what the
///         settlement contract relies on from them - only the named facilitator may call, never more
///         than the signed maximum, each nonce once, the money goes to `witness.to` - and skips the
///         Permit2 signature check, which is Permit2's job, not ours. The real proxy and Permit2 are
///         exercised by the Base Sepolia fork test and the end-to-end run.
contract MockUptoPermit2Proxy {
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    /// @dev Test switch: move one unit less than asked, to prove the settlement contract notices.
    bool public shortchange;

    error UnauthorizedFacilitator();
    error AmountExceedsPermitted();
    error InvalidNonce();

    function setShortchange(bool value) external {
        shortchange = value;
    }

    function settle(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        IX402UptoPermit2Proxy.Witness calldata witness,
        bytes calldata
    ) public {
        if (amount > permit.permitted.amount) revert AmountExceedsPermitted();
        if (msg.sender != witness.facilitator) revert UnauthorizedFacilitator();
        if (nonceUsed[owner][permit.nonce]) revert InvalidNonce();
        nonceUsed[owner][permit.nonce] = true;
        uint256 moved = shortchange ? amount - 1 : amount;
        require(IPullToken(permit.permitted.token).transferFrom(owner, witness.to, moved), "pull failed");
    }

    /// @dev The real proxy swallows a failed EIP-2612 permit and proceeds on the existing allowance.
    function settleWithPermit(
        IX402UptoPermit2Proxy.EIP2612Permit calldata p,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 amount,
        address owner,
        IX402UptoPermit2Proxy.Witness calldata witness,
        bytes calldata signature
    ) external {
        try IPullToken(permit.permitted.token).permit(owner, address(this), p.value, p.deadline, p.v, p.r, p.s) {}
            catch {}
        settle(permit, amount, owner, witness, signature);
    }
}
