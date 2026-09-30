/**
 * The P2FluxBatchVaults deployment manifest: a small KEY=VALUE file next to the approved Base Mainnet
 * manifest, anchored to it by hash. Same rules as x402-manifest.ts: exactly the expected keys, strict
 * EIP-55 addresses, every constructor argument equal to the value it restates, the fee rate stated,
 * and the exact creation bytecode pinned - the approval covers what will be signed, not a file name.
 */
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { encodeDeployData, isAddress, keccak256, type Abi, type Address, type Hex } from 'viem'
import { addr, loadManifest } from './manifest.js'

export const BATCH_KEYS = [
  'NETWORK', 'CHAIN_ID', 'MAIN_MANIFEST_SHA256',
  'DEPLOYER', 'FEE_WALLET', 'USDC',
  'BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN',
  'BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET',
  'BATCH_VAULTS_FEE_BPS',
  'BATCH_VAULTS_EXPECTED_ADDRESS',
  'BATCH_VAULTS_INITCODE_KECCAK',
] as const
type Key = (typeof BATCH_KEYS)[number]

export type BatchPlan = { token: Address; feeWallet: Address; expected: Address | null; initcodeKeccak: Hex | null; sha256: string | null }

const fail = (message: string): never => {
  throw new Error(`batch vaults manifest: ${message}`)
}

export const batchInitcodeKeccak = (artifact: { abi: unknown; bytecode: Hex }, plan: Pick<BatchPlan, 'token' | 'feeWallet'>): Hex =>
  keccak256(encodeDeployData({ abi: artifact.abi as Abi, bytecode: artifact.bytecode, args: [plan.token, plan.feeWallet] }))

export function loadBatchManifest(path: string, mainPath: string, approvedSha256?: string): BatchPlan {
  const raw = readFileSync(path)
  const sha256 = createHash('sha256').update(raw).digest('hex')
  if (approvedSha256 !== undefined && approvedSha256.toLowerCase() !== sha256) fail(`this file is ${sha256}, the approved manifest is ${approvedSha256}`)
  const values: Partial<Record<Key, string>> = {}
  for (const line of raw.toString('utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const eq = trimmed.indexOf('=')
    if (eq <= 0) fail(`unreadable line: ${trimmed}`)
    const key = trimmed.slice(0, eq) as Key
    if (!BATCH_KEYS.includes(key)) fail(`unexpected key ${key}`)
    if (values[key] !== undefined) fail(`duplicate key ${key}`)
    values[key] = trimmed.slice(eq + 1).trim()
  }
  for (const key of BATCH_KEYS) if (values[key] === undefined) fail(`missing key ${key}`)
  const m = values as Record<Key, string>

  for (const key of ['DEPLOYER', 'FEE_WALLET', 'USDC', 'BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET', 'BATCH_VAULTS_EXPECTED_ADDRESS'] as Key[]) {
    if (!isAddress(m[key], { strict: true }) || addr(m[key]) !== m[key]) fail(`${key} is not a checksummed address: ${m[key]}`)
    if (/^0x0{40}$/.test(m[key])) fail(`${key} is the zero address`)
  }
  if (m.BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN !== m.USDC) fail('ARG_1 does not equal USDC')
  if (m.BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET !== m.FEE_WALLET) fail('ARG_2 does not equal FEE_WALLET')
  if (m.BATCH_VAULTS_FEE_BPS !== '300') fail('BATCH_VAULTS_FEE_BPS must be 300')
  if (m.CHAIN_ID !== '8453' || m.NETWORK !== 'Base Mainnet') fail('this manifest format is for Base Mainnet (8453) only')
  if (!/^0x[0-9a-f]{64}$/.test(m.BATCH_VAULTS_INITCODE_KECCAK)) fail('BATCH_VAULTS_INITCODE_KECCAK must be 0x + 64 lowercase hex')

  const main = loadManifest(mainPath)
  if (main.sha256 !== m.MAIN_MANIFEST_SHA256) fail(`MAIN_MANIFEST_SHA256 does not match ${mainPath} (${main.sha256})`)
  for (const key of ['USDC', 'FEE_WALLET', 'DEPLOYER'] as const) {
    if (m[key] !== main[key]) fail(`${key} (${m[key]}) differs from the main manifest's ${key} (${main[key]})`)
  }
  return { token: addr(m.USDC), feeWallet: addr(m.FEE_WALLET), expected: addr(m.BATCH_VAULTS_EXPECTED_ADDRESS), initcodeKeccak: m.BATCH_VAULTS_INITCODE_KECCAK as Hex, sha256 }
}
