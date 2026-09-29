/**
 * The x402 deployment manifest: its own small KEY=VALUE file, so the approved Base Mainnet manifest
 * (and the hash its approval is tied to) is never edited to add a contract.
 *
 * Same rules as manifest.ts: exactly the expected keys, strict EIP-55 addresses, every constructor
 * argument line repeating its role line, the protocol constants pinned. And one more: the relayer,
 * fee wallet and token must be the ones the approved main manifest names - an x402 splitter wired to
 * a different relayer is a contract the running API can never call, and there is no setter.
 */
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { isAddress, type Address } from 'viem'
import { addr, loadManifest } from './manifest.js'
import { X402_UPTO_PROXY } from '../src/x402.js'

export const X402_KEYS = [
  'NETWORK', 'CHAIN_ID', 'MAIN_MANIFEST_SHA256',
  'DEPLOYER', 'RELAYER', 'FEE_WALLET', 'USDC',
  'X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN',
  'X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET',
  'X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER',
  'X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY',
  'X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC',
  'X402_SPLITTER_FEE_BPS',
  'X402_SPLITTER_EXPECTED_ADDRESS',
] as const
type Key = (typeof X402_KEYS)[number]

export type X402Plan = {
  token: Address
  feeWallet: Address
  relayer: Address
  uptoProxy: Address
  minFee: bigint
  expected: Address | null
  sha256: string | null
}

const fail = (message: string): never => {
  throw new Error(`x402 manifest: ${message}`)
}

export function loadX402Manifest(path: string, mainPath: string): X402Plan {
  const raw = readFileSync(path)
  const values: Partial<Record<Key, string>> = {}
  for (const line of raw.toString('utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    const eq = trimmed.indexOf('=')
    if (eq <= 0) fail(`unreadable line: ${trimmed}`)
    const key = trimmed.slice(0, eq) as Key
    if (!X402_KEYS.includes(key)) fail(`unexpected key ${key}`)
    if (values[key] !== undefined) fail(`duplicate key ${key}`)
    values[key] = trimmed.slice(eq + 1).trim()
  }
  for (const key of X402_KEYS) if (values[key] === undefined) fail(`missing key ${key}`)
  const m = values as Record<Key, string>

  const addressKeys: Key[] = [
    'DEPLOYER', 'RELAYER', 'FEE_WALLET', 'USDC',
    'X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET',
    'X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER', 'X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY',
    'X402_SPLITTER_EXPECTED_ADDRESS',
  ]
  for (const key of addressKeys) {
    if (!isAddress(m[key], { strict: true })) fail(`${key} is not a checksummed address: ${m[key]}`)
    if (/^0x0{40}$/.test(m[key])) fail(`${key} is the zero address`)
  }
  const same = (a: Key, b: Key) => {
    if (m[a] !== m[b]) fail(`${a} (${m[a]}) does not equal ${b} (${m[b]})`)
  }
  same('X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', 'USDC')
  same('X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', 'FEE_WALLET')
  same('X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER', 'RELAYER')
  if (m.X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY !== X402_UPTO_PROXY) fail('ARG_4 is not the canonical x402 upto proxy')
  if (m.X402_SPLITTER_FEE_BPS !== '100') fail('X402_SPLITTER_FEE_BPS must be 100')
  const minFee = m.X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC
  if (!/^\d+$/.test(minFee) || BigInt(minFee) > 100_000n) fail('MIN_FEE must be an integer between 0 and 100000 (0.10 USDC)')
  if (m.CHAIN_ID !== '8453' || m.NETWORK !== 'Base Mainnet') fail('this manifest format is for Base Mainnet (8453) only')

  // Anchored to the approved main manifest: same token, fee wallet and relayer, and that exact file.
  const main = loadManifest(mainPath)
  if (main.sha256 !== m.MAIN_MANIFEST_SHA256) fail(`MAIN_MANIFEST_SHA256 does not match ${mainPath} (${main.sha256})`)
  for (const [key, mainKey] of [['USDC', 'USDC'], ['FEE_WALLET', 'FEE_WALLET'], ['RELAYER', 'RELAYER'], ['DEPLOYER', 'DEPLOYER']] as const) {
    if (m[key] !== main[mainKey]) fail(`${key} (${m[key]}) differs from the main manifest's ${mainKey} (${main[mainKey]})`)
  }

  return {
    token: addr(m.USDC),
    feeWallet: addr(m.FEE_WALLET),
    relayer: addr(m.RELAYER),
    uptoProxy: addr(m.X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY),
    minFee: BigInt(minFee),
    expected: addr(m.X402_SPLITTER_EXPECTED_ADDRESS),
    sha256: createHash('sha256').update(raw).digest('hex'),
  }
}
