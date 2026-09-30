// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P2FluxX402Vault} from "./P2FluxX402Splitter.sol";

/// @title P2FluxBatchVaults
/// @notice Per-seller vaults for x402 `batch-settlement`: the `receiver` of an agent's payment channel
///         in the standard x402 escrow. The escrow pays a seller's claimed vouchers into their vault;
///         anyone may then `flush` it, and the vault pays the seller 97% and P2Flux 3%.
///
/// @dev The vault is `P2FluxX402Vault`, unchanged: its recipient is fixed at deployment and part of its
///      CREATE2 address, and it can only pay that recipient and the fee wallet. This factory is separate
///      from `P2FluxX402Splitter` so the two fee rates can never meet - a seller's batch vault and exact
///      vault are different addresses.
///
///      Not upgradeable, no owner, no roles. Nothing here moves money anywhere but to a vault's seller
///      and to the immutable fee wallet (and a fee the fee wallet cannot receive goes to the seller).
contract P2FluxBatchVaults is ReentrancyGuard {
    /// @notice The P2Flux fee on everything paid out of a batch vault, in basis points: 3%.
    uint16 public constant FEE_BPS = 300;

    address public immutable supportedToken;
    address public immutable feeWallet;

    event Flushed(address indexed recipient, uint256 net, uint256 fee);

    error ZeroAddress();
    error ZeroAmount();

    constructor(address _supportedToken, address _feeWallet) {
        if (_supportedToken == address(0) || _feeWallet == address(0)) revert ZeroAddress();
        supportedToken = _supportedToken;
        feeWallet = _feeWallet;
    }

    /// @notice The seller's batch vault: the `receiver` of their payment channels. Deployed on first flush.
    function vaultOf(address recipient) public view returns (address) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(P2FluxX402Vault).creationCode, abi.encode(recipient)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), initCodeHash))))
            );
    }

    /// @notice Pay out a seller's batch vault: 97% to the seller, 3% to P2Flux.
    /// @dev Anyone may call it: the money can only go to the seller and the fee wallet.
    function flush(address recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        address vault = vaultOf(recipient);
        if (vault.code.length == 0) new P2FluxX402Vault{salt: bytes32(0)}(recipient);
        uint256 balance = IERC20(supportedToken).balanceOf(vault);
        if (balance == 0) revert ZeroAmount();
        uint256 fee = (balance * FEE_BPS) / 10_000;
        uint256 feePaid = P2FluxX402Vault(vault).release(IERC20(supportedToken), feeWallet, balance, fee);
        emit Flushed(recipient, balance - feePaid, feePaid);
    }
}
