import { type Address, type Hex } from 'viem';
import { p2fluxX402SplitterAbi, p2fluxBatchVaultsAbi, X402_VAULT_CREATION_CODE } from './x402.generated.js';
export { p2fluxX402SplitterAbi, p2fluxBatchVaultsAbi, X402_VAULT_CREATION_CODE };
/** P2Flux's fee on an x402 payment: 1%, never less than the deployment's `MIN_FEE`. */
export declare const X402_FEE_BPS = 100n;
/** Mirrors `maxFee` in the contract: the most the relayer may take from a payment of `amount`. */
export declare const x402MaxFee: (amount: bigint, minFee: bigint) => bigint;
/** Uniswap Permit2: the same address on every chain. */
export declare const PERMIT2: Address;
/**
 * x402's `upto` proxy (x402-foundation/x402 x402UptoPermit2Proxy). One CREATE2 address, verified on
 * Base and Base Sepolia (identical code hash) on 2026-09-29; the x402 client hardcodes it as the
 * Permit2 spender, so it is not configurable.
 */
export declare const X402_UPTO_PROXY: Address;
/**
 * EIP-712 typed data for USDC's `TransferWithAuthorization`: what an x402 `exact` client signs, with
 * `to` = the seller's vault. For tests and tooling - in production the agent's own client builds it.
 */
export declare const transferWithAuthorizationTypedData: (args: {
    chainId: number;
    token: Address;
    tokenName: string;
    tokenVersion: string;
    from: Address;
    to: Address;
    value: bigint;
    validBefore: bigint;
    nonce: Hex;
}) => {
    readonly domain: {
        readonly name: string;
        readonly version: string;
        readonly chainId: number;
        readonly verifyingContract: `0x${string}`;
    };
    readonly types: {
        readonly TransferWithAuthorization: readonly [{
            readonly name: "from";
            readonly type: "address";
        }, {
            readonly name: "to";
            readonly type: "address";
        }, {
            readonly name: "value";
            readonly type: "uint256";
        }, {
            readonly name: "validAfter";
            readonly type: "uint256";
        }, {
            readonly name: "validBefore";
            readonly type: "uint256";
        }, {
            readonly name: "nonce";
            readonly type: "bytes32";
        }];
    };
    readonly primaryType: "TransferWithAuthorization";
    readonly message: {
        readonly from: `0x${string}`;
        readonly to: `0x${string}`;
        readonly value: bigint;
        readonly validAfter: 0n;
        readonly validBefore: bigint;
        readonly nonce: `0x${string}`;
    };
};
/** Must match `X402_REF_DOMAIN` in contracts/P2FluxX402Splitter.sol. */
export declare const X402_REF_DOMAIN: `0x${string}`;
/**
 * The reference of an x402 payment, as the contract's `refOf` computes it: the payer and the nonce of
 * the payer's signature (the EIP-3009 nonce, or the Permit2 nonce as 32 bytes). It is what `Paid`
 * carries and what the payment id is computed over.
 */
export declare const x402Ref: (payer: Address, nonce: Hex) => Hex;
/**
 * A seller's vault - the `payTo` an agent signs - as the contract's `vaultOf` derives it. Computed
 * locally so that answering "where does this seller get paid" never costs a chain read.
 */
export declare const x402VaultAddress: (splitter: Address, recipient: Address) => Address;
/** Fee on a batch-settlement payout, basis points (P2FluxBatchVaults.FEE_BPS): 3%. */
export declare const X402_BATCH_FEE_BPS = 300n;
/**
 * A seller's batch vault - the `receiver` of their x402 batch-settlement channels. Same vault code and
 * derivation as the exact vault, from the P2FluxBatchVaults factory instead, so the address differs.
 */
export declare const batchVaultAddress: (batchVaults: Address, recipient: Address) => Address;
