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

/**
 * The sponsored pair, as a complete group or not at all.
 *
 * A manifest without the group can still deploy the splitter and the recurring contract; one WITH
 * it is the only artefact a sponsored Mainnet deployment may be checked against. Every immutable
 * constructor argument is here, each address line repeats its role line exactly, every economic
 * constant is pinned to what the API and the bytecode expect, and the two expected addresses are
 * what the deployer's nonces must produce. Environment variables never define any of these; at most
 * they are checked against them.
 */
export const SPONSORED_KEYS = [
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN',
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET',
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY',
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER',
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC',
  'SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC',
  'SPONSORED_SPLITTER_ONE_TIME_BPS',
  'SPONSORED_SPLITTER_EXPECTED_ADDRESS',
  'GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN',
  'GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY',
  'GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER',
  'GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC',
  'GAS_SPONSOR_EXPECTED_ADDRESS',
] as const
export type SponsoredKey = (typeof SPONSORED_KEYS)[number]

export type Manifest = Record<Key, string> & Partial<Record<SponsoredKey, string>> & { sha256: string; path: string }
/** A manifest whose sponsored group is complete and validated. */
export type SponsoredManifest = Manifest & Record<SponsoredKey, string>

const fail = (message: string): never => {
  throw new Error(`manifest: ${message}`)
}

export function loadManifest(path = process.env.DEPLOY_MANIFEST || ''): Manifest {
  if (!path) fail('DEPLOY_MANIFEST is required (path to the approved deployment manifest)')
  const raw = readFileSync(path)
  const sha256 = createHash('sha256').update(raw).digest('hex')

  const values: Partial<Record<Key | SponsoredKey, string>> = {}
  for (const line of raw.toString('utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const eq = trimmed.indexOf('=')
    if (eq <= 0) fail(`unreadable line: ${trimmed}`)
    const key = trimmed.slice(0, eq) as Key | SponsoredKey
    if (!KEYS.includes(key as Key) && !SPONSORED_KEYS.includes(key as SponsoredKey)) fail(`unexpected key ${key}`)
    if (values[key] !== undefined) fail(`duplicate key ${key}`)
    values[key] = trimmed.slice(eq + 1).trim()
  }
  for (const key of KEYS) if (values[key] === undefined) fail(`missing key ${key}`)
  const m = values as Record<Key, string> & Partial<Record<SponsoredKey, string>>

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

  // The sponsored group: complete or absent. A half-written group is refused, not "resolved".
  const present = SPONSORED_KEYS.filter((k) => m[k] !== undefined)
  if (present.length > 0 && present.length !== SPONSORED_KEYS.length) {
    fail(`sponsored group incomplete: missing ${SPONSORED_KEYS.filter((k) => m[k] === undefined).join(', ')}`)
  }
  if (present.length === SPONSORED_KEYS.length) validateSponsored(m as Record<Key | SponsoredKey, string>)

  return { ...m, sha256, path }
}

const validateSponsored = (m: Record<Key | SponsoredKey, string>) => {
  const sameAs = (a: SponsoredKey, b: Key) => {
    if (m[a] !== m[b]) fail(`${a} (${m[a]}) does not equal ${b} (${m[b]})`)
  }
  for (const key of ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', 'GAS_SPONSOR_EXPECTED_ADDRESS'] as const) {
    if (!isAddress(m[key], { strict: true })) fail(`${key} is not a checksummed address: ${m[key]}`)
    if (/^0x0{40}$/.test(m[key])) fail(`${key} is the zero address`)
  }
  if (m.SPONSORED_SPLITTER_EXPECTED_ADDRESS.toLowerCase() === m.GAS_SPONSOR_EXPECTED_ADDRESS.toLowerCase()) {
    fail('the two sponsored expected addresses are the same')
  }
  for (const key of ['SPLITTER_EXPECTED_ADDRESS', 'RECURRING_EXPECTED_ADDRESS'] as const) {
    if ([m.SPONSORED_SPLITTER_EXPECTED_ADDRESS, m.GAS_SPONSOR_EXPECTED_ADDRESS].some((a) => a.toLowerCase() === m[key].toLowerCase())) {
      fail(`a sponsored expected address repeats ${key}`)
    }
  }
  sameAs('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'USDC')
  sameAs('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', 'FEE_WALLET')
  sameAs('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY', 'GAS_TREASURY')
  sameAs('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER', 'RELAYER')
  sameAs('GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'USDC')
  sameAs('GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY', 'GAS_TREASURY')
  sameAs('GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER', 'RELAYER')
  /* The economics. The fixed fee is the recurring contract's NETWORK_FEE, merchant-funded, and the
   * API quotes it from its own table; a manifest saying anything else describes a contract the API
   * would refuse at startup. The cap is what SPONSOR_HARD_CAP mirrors, identical on both contracts. */
  if (m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC !== '100000') {
    fail('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC must be 100000')
  }
  const cap = m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC
  if (!/^[1-9]\d*$/.test(cap)) fail('SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC must be a positive integer')
  if (BigInt(cap) <= 100_000n) fail('the hard cap must exceed the fixed network fee')
  if (BigInt(cap) > 1_000_000n) fail('the hard cap must not exceed 1 USDC')
  if (m.GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC !== cap) {
    fail('GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC must equal the splitter hard cap')
  }
  if (m.SPONSORED_SPLITTER_ONE_TIME_BPS !== '100') fail('SPONSORED_SPLITTER_ONE_TIME_BPS must be 100')
}

/** The manifest with its sponsored group present, or a failure naming what is missing. */
export function requireSponsored(m: Manifest): SponsoredManifest {
  const missing = SPONSORED_KEYS.filter((k) => m[k] === undefined)
  if (missing.length) fail(`sponsored deployment requires manifest keys: ${missing.join(', ')}`)
  return m as SponsoredManifest
}

export const addr = (value: string): Address => getAddress(value)
