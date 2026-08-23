/**
 * The deployment manifest: one plain-text file of KEY=VALUE lines that is the ONLY source of every
 * constructor argument a Mainnet deployment uses.
 *
 * Why a file and not the environment: the values are immutable forever once deployed, so the
 * thing that was reviewed and approved must be byte-for-byte the thing that is deployed. The
 * loader refuses anything that is not exactly the expected key set, re-checks every address,
 * insists the five roles are distinct, and cross-checks that each constructor-argument line
 * equals the role line it claims to repeat - a manifest that says FEE_WALLET=A and
 * SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET=B is refused, not resolved. The SHA-256 of the raw bytes
 * is returned so the approval and the deployment run can be tied to the same document.
 */
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { getAddress, isAddress, type Address } from 'viem'

const KEYS = [
  'NETWORK', 'CHAIN_ID',
  'DEPLOYER', 'ADMIN', 'RELAYER', 'FEE_WALLET', 'GAS_TREASURY', 'USDC',
  'SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET',
  'SPLITTER_ONE_TIME_BPS', 'SPLITTER_EXPECTED_ADDRESS', 'SPLITTER_GAS_ESTIMATE',
  'RECURRING_CONSTRUCTOR_ARG_1_ADMIN', 'RECURRING_CONSTRUCTOR_ARG_2_RELAYER',
  'RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET', 'RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY',
  'RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN',
  'RECURRING_FEE_BPS', 'RECURRING_NETWORK_FEE_MICRO_USDC', 'RECURRING_GAS_REIMBURSEMENT_HARD_CAP_MICRO_USDC',
  'RECURRING_EXPECTED_ADDRESS', 'RECURRING_GAS_ESTIMATE',
  'DEPLOYER_FUNDING_ETH', 'RELAYER_FUNDING_ETH',
] as const
type Key = (typeof KEYS)[number]

export type Manifest = Record<Key, string> & { sha256: string; path: string }

const fail = (message: string): never => {
  throw new Error(`manifest: ${message}`)
}

export function loadManifest(path = process.env.DEPLOY_MANIFEST || ''): Manifest {
  if (!path) fail('DEPLOY_MANIFEST is required (path to the approved deployment manifest)')
  const raw = readFileSync(path)
  const sha256 = createHash('sha256').update(raw).digest('hex')

  const values: Partial<Record<Key, string>> = {}
  for (const line of raw.toString('utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const eq = trimmed.indexOf('=')
    if (eq <= 0) fail(`unreadable line: ${trimmed}`)
    const key = trimmed.slice(0, eq) as Key
    if (!KEYS.includes(key)) fail(`unexpected key ${key}`)
    if (values[key] !== undefined) fail(`duplicate key ${key}`)
    values[key] = trimmed.slice(eq + 1).trim()
  }
  for (const key of KEYS) if (values[key] === undefined) fail(`missing key ${key}`)
  const m = values as Record<Key, string>

  // Every address valid under EIP-55 (strict - a wrong-case hex string is refused, not "fixed").
  const addressKeys: Key[] = [
    'DEPLOYER', 'ADMIN', 'RELAYER', 'FEE_WALLET', 'GAS_TREASURY', 'USDC',
    'SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', 'SPLITTER_EXPECTED_ADDRESS',
    'RECURRING_CONSTRUCTOR_ARG_1_ADMIN', 'RECURRING_CONSTRUCTOR_ARG_2_RELAYER', 'RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET',
    'RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY', 'RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN', 'RECURRING_EXPECTED_ADDRESS',
  ]
  for (const key of addressKeys) {
    if (!isAddress(m[key], { strict: true })) fail(`${key} is not a checksummed address: ${m[key]}`)
    if (/^0x0{40}$/.test(m[key])) fail(`${key} is the zero address`)
  }

  // Five distinct roles.
  const roles = ['DEPLOYER', 'ADMIN', 'RELAYER', 'FEE_WALLET', 'GAS_TREASURY'] as const
  if (new Set(roles.map((r) => m[r].toLowerCase())).size !== 5) fail('the five role addresses are not distinct')

  // Each constructor-argument line must repeat its role line exactly. Nothing is "resolved".
  const same = (a: Key, b: Key) => {
    if (m[a] !== m[b]) fail(`${a} (${m[a]}) does not equal ${b} (${m[b]})`)
  }
  same('SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'USDC')
  same('SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', 'FEE_WALLET')
  same('RECURRING_CONSTRUCTOR_ARG_1_ADMIN', 'ADMIN')
  same('RECURRING_CONSTRUCTOR_ARG_2_RELAYER', 'RELAYER')
  same('RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET', 'FEE_WALLET')
  same('RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY', 'GAS_TREASURY')
  same('RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN', 'USDC')

  // Protocol constants the manifest claims must be the ones compiled into the bytecode.
  if (m.SPLITTER_ONE_TIME_BPS !== '100') fail('SPLITTER_ONE_TIME_BPS must be 100')
  if (m.RECURRING_FEE_BPS !== '200') fail('RECURRING_FEE_BPS must be 200')
  if (m.RECURRING_NETWORK_FEE_MICRO_USDC !== '100000') fail('RECURRING_NETWORK_FEE_MICRO_USDC must be 100000')
  if (m.RECURRING_GAS_REIMBURSEMENT_HARD_CAP_MICRO_USDC !== '50000') fail('RECURRING_GAS_REIMBURSEMENT_HARD_CAP_MICRO_USDC must be 50000')
  if (m.CHAIN_ID !== '8453' || m.NETWORK !== 'Base Mainnet') fail('this manifest format is for Base Mainnet (8453) only')
  if (m.USDC !== '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913') fail('USDC is not the canonical Base Mainnet USDC')

  return { ...m, sha256, path }
}

export const addr = (value: string): Address => getAddress(value)
