import { encodeAbiParameters, keccak256, toBytes, type Address, type Hex } from 'viem'
export const ONE_TIME_BPS = 100n
export const RECURRING_BPS = 200n

export const feeFor = (amount: bigint, bps: bigint) => (amount * bps) / 10_000n

/** Must match `PAYMENT_DOMAIN` in contracts/P2FluxSplitter.sol. */
export const PAYMENT_DOMAIN = keccak256(toBytes('P2FLUX_PAYMENT_V1'))

/**
 * The settlement id the contract computes, recomputed locally.
 *
 * Binding a receipt to this - rather than to the `Paid` event alone - is what makes a verification
 * mean "this exact intent, in this exact token, settled". The token is part of the identity, so a
 * settlement in anything else simply is not this payment.
 */
export const paymentIdFor = (args: {
  token: Address
  recipient: Address
  amount: bigint
  reference: Hex
}): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'address' }, { type: 'address' }, { type: 'uint256' }, { type: 'bytes32' }],
      [PAYMENT_DOMAIN, args.token, args.recipient, args.amount, args.reference],
    ),
  )

/**
 * Hand-written subset of P2FluxSplitter. The compiled artifact lives in gitignored `out/`, so the
 * API cannot depend on it. Custom errors are included so reverts decode to real names.
 */
export const splitterAbi = [
  {
    type: 'function',
    name: 'pay',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'payWithPermit',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
      { name: 'deadline', type: 'uint256' },
      { name: 'v', type: 'uint8' },
      { name: 'r', type: 'bytes32' },
      { name: 's', type: 'bytes32' },
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'paymentId',
    stateMutability: 'pure',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
    ],
    outputs: [{ type: 'bytes32' }],
  },
  {
    type: 'function',
    name: 'isPaymentProcessed',
    stateMutability: 'view',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'recipient', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'ref', type: 'bytes32' },
    ],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'processedPayments',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32' }],
    outputs: [{ type: 'bool' }],
  },
  { type: 'function', name: 'feeWallet', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'supportedToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'PAYMENT_DOMAIN', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  {
    type: 'event',
    name: 'Paid',
    inputs: [
      { name: 'ref', type: 'bytes32', indexed: true },
      { name: 'recipient', type: 'address', indexed: true },
      { name: 'token', type: 'address', indexed: true },
      { name: 'net', type: 'uint256' },
      { name: 'fee', type: 'uint256' },
    ],
  },
  { type: 'event', name: 'PaymentSettled', inputs: [{ name: 'paymentId', type: 'bytes32', indexed: true }] },
  { type: 'error', name: 'ZeroAddress', inputs: [] },
  { type: 'error', name: 'ZeroAmount', inputs: [] },
  { type: 'error', name: 'TokenNotSupported', inputs: [] },
  { type: 'error', name: 'NotAContract', inputs: [] },
  { type: 'error', name: 'TransferFailed', inputs: [] },
  { type: 'error', name: 'PaymentAlreadyProcessed', inputs: [{ name: 'paymentId', type: 'bytes32' }] },
] as const

/** ERC-20 Transfer, for verifying that the split actually happened. */
export const transferEvent = {
  type: 'event',
  name: 'Transfer',
  inputs: [
    { name: 'from', type: 'address', indexed: true },
    { name: 'to', type: 'address', indexed: true },
    { name: 'value', type: 'uint256' },
  ],
} as const
