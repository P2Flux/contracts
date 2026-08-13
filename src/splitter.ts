import { usdc } from './addresses.js'

/** Must match `MAX_GAS_FEE` in contracts/P2FluxSplitter.sol. */
export const MAX_GAS_FEE = usdc('0.05')

export const ONE_TIME_BPS = 100n
export const RECURRING_BPS = 200n

export const feeFor = (amount: bigint, bps: bigint) => (amount * bps) / 10_000n

const permissionTuple = {
  type: 'tuple',
  name: 'permission',
  components: [
    { name: 'account', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'token', type: 'address' },
    { name: 'allowance', type: 'uint160' },
    { name: 'period', type: 'uint48' },
    { name: 'start', type: 'uint48' },
    { name: 'end', type: 'uint48' },
    { name: 'salt', type: 'uint256' },
    { name: 'extraData', type: 'bytes' },
  ],
} as const

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
    name: 'charge',
    stateMutability: 'nonpayable',
    inputs: [permissionTuple, { name: 'gasFee', type: 'uint256' }],
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
  { type: 'function', name: 'relayer', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'feeWallet', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'admin', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'MAX_GAS_FEE', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  {
    type: 'event',
    name: 'Paid',
    inputs: [
      { name: 'ref', type: 'bytes32', indexed: true },
      { name: 'recipient', type: 'address', indexed: true },
      { name: 'net', type: 'uint256' },
      { name: 'fee', type: 'uint256' },
    ],
  },
  { type: 'event', name: 'PaymentSettled', inputs: [{ name: 'paymentId', type: 'bytes32', indexed: true }] },
  {
    type: 'event',
    name: 'Charged',
    inputs: [
      { name: 'permissionHash', type: 'bytes32', indexed: true },
      { name: 'recipient', type: 'address', indexed: true },
      { name: 'net', type: 'uint256' },
      { name: 'fee', type: 'uint256' },
      { name: 'gasFee', type: 'uint256' },
    ],
  },
  { type: 'error', name: 'NotAdmin', inputs: [] },
  { type: 'error', name: 'NotRelayer', inputs: [] },
  { type: 'error', name: 'ZeroAddress', inputs: [] },
  { type: 'error', name: 'ZeroAmount', inputs: [] },
  { type: 'error', name: 'GasFeeTooHigh', inputs: [] },
  { type: 'error', name: 'AlreadyChargedThisPeriod', inputs: [] },
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
