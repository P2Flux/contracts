import { encodeAbiParameters, getContractAddress, keccak256, toBytes, zeroHash, type Address, type Hex } from 'viem'
import { p2fluxX402SplitterAbi, X402_VAULT_CREATION_CODE } from './x402.generated.js'

export { p2fluxX402SplitterAbi, X402_VAULT_CREATION_CODE }

/*
 * x402 settlement: AI agents paying for APIs, content and tools with an unmodified x402 client, settled
 * through P2FluxX402Splitter so the P2Flux fee is split out on-chain. See contracts/P2FluxX402Splitter.sol.
 */

/** P2Flux's fee on an x402 payment: 1%, never less than the deployment's `MIN_FEE`. */
export const X402_FEE_BPS = 100n

/** Mirrors `maxFee` in the contract: the most the relayer may take from a payment of `amount`. */
export const x402MaxFee = (amount: bigint, minFee: bigint) => {
  const fee = (amount * X402_FEE_BPS) / 10_000n
  return fee > minFee ? fee : minFee
}

/** Uniswap Permit2: the same address on every chain. */
export const PERMIT2: Address = '0x000000000022D473030F116dDEE9F6B43aC78BA3'

/**
 * x402's `upto` proxy (x402-foundation/x402 x402UptoPermit2Proxy). One CREATE2 address, verified on
 * Base and Base Sepolia (identical code hash) on 2026-09-29; the x402 client hardcodes it as the
 * Permit2 spender, so it is not configurable.
 */
export const X402_UPTO_PROXY: Address = '0x4020A4f3b7b90ccA423B9fabCc0CE57C6C240002'

/**
 * EIP-712 typed data for USDC's `TransferWithAuthorization`: what an x402 `exact` client signs, with
 * `to` = the seller's vault. For tests and tooling - in production the agent's own client builds it.
 */
export const transferWithAuthorizationTypedData = (args: {
  chainId: number
  token: Address
  tokenName: string
  tokenVersion: string
  from: Address
  to: Address
  value: bigint
  validBefore: bigint
  nonce: Hex
}) =>
  ({
    domain: {
      name: args.tokenName,
      version: args.tokenVersion,
      chainId: args.chainId,
      verifyingContract: args.token,
    },
    types: {
      TransferWithAuthorization: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'validAfter', type: 'uint256' },
        { name: 'validBefore', type: 'uint256' },
        { name: 'nonce', type: 'bytes32' },
      ],
    },
    primaryType: 'TransferWithAuthorization' as const,
    message: {
      from: args.from,
      to: args.to,
      value: args.value,
      validAfter: 0n,
      validBefore: args.validBefore,
      nonce: args.nonce,
    },
  }) as const

/** Must match `X402_REF_DOMAIN` in contracts/P2FluxX402Splitter.sol. */
export const X402_REF_DOMAIN = keccak256(toBytes('P2FLUX_X402_REF_V1'))

/**
 * The reference of an x402 payment, as the contract's `refOf` computes it: the payer and the nonce of
 * the payer's signature (the EIP-3009 nonce, or the Permit2 nonce as 32 bytes). It is what `Paid`
 * carries and what the payment id is computed over.
 */
export const x402Ref = (payer: Address, nonce: Hex): Hex =>
  keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'address' }, { type: 'bytes32' }], [X402_REF_DOMAIN, payer, nonce]))

/**
 * A seller's vault - the `payTo` an agent signs - as the contract's `vaultOf` derives it. Computed
 * locally so that answering "where does this seller get paid" never costs a chain read.
 */
export const x402VaultAddress = (splitter: Address, recipient: Address): Address =>
  getContractAddress({
    opcode: 'CREATE2',
    from: splitter,
    salt: zeroHash,
    bytecode: `${X402_VAULT_CREATION_CODE}${encodeAbiParameters([{ type: 'address' }], [recipient]).slice(2)}`,
  })
