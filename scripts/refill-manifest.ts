/**
 * The P2FluxGasRefill deployment manifest: KEY=VALUE, anchored to the approved Base Mainnet manifest by
 * hash. The same rules as the other manifests - exactly the expected keys, checksummed addresses, the
 * wallets equal to the main manifest's, the third-party contracts (WETH, Uniswap router, Chainlink feed)
 * pinned here, every limit inside safe bounds, the exact creation bytecode pinned.
 */
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { encodeDeployData, isAddress, keccak256, type Abi, type Address, type Hex } from 'viem'
import { addr, loadManifest } from './manifest.js'

export const REFILL_KEYS = [
  'NETWORK', 'CHAIN_ID', 'MAIN_MANIFEST_SHA256',
  'DEPLOYER', 'RELAYER', 'GAS_TREASURY', 'USDC',
  'WETH', 'UNISWAP_ROUTER', 'POOL_FEE', 'ETH_USD_FEED', 'SEQUENCER_FEED',
  'REFILL_BELOW_WEI', 'MAX_ORACLE_AGE_SECONDS', 'DAILY_CAP_USDC_UNITS', 'MAX_TARGET_WEI', 'MAX_SLIPPAGE_BPS',
  'GAS_REFILL_EXPECTED_ADDRESS', 'GAS_REFILL_INITCODE_KECCAK',
] as const
type Key = (typeof REFILL_KEYS)[number]

/** Base Mainnet's canonical WETH, Uniswap v3 SwapRouter02, Chainlink ETH/USD feed (the API's own) and
 *  Chainlink L2 sequencer uptime feed. Read on chain 2026-10-01: the feed answers "ETH / USD", 8 decimals;
 *  the sequencer feed "L2 Sequencer Uptime Status Feed"; the 0.05 % USDC/WETH pool is the deepest. */
export const BASE_MAINNET_THIRD_PARTY = {
  WETH: '0x4200000000000000000000000000000000000006',
  UNISWAP_ROUTER: '0x2626664c2603336E57B271c5C0b26F421741e481',
  ETH_USD_FEED: '0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70',
  SEQUENCER_FEED: '0xBCF85224fc0756B9Fa45aA7892530B47e10b6433',
} as const

export type RefillParams = {
  usdc: Address; weth: Address; treasury: Address; relayer: Address; router: Address; poolFee: number; ethUsdFeed: Address
  sequencerFeed: Address; refillBelowWei: bigint; maxOracleAge: bigint; dailyCapUsdc: bigint; maxTargetWei: bigint; maxSlippageBps: bigint
}
export type RefillPlan = {
  args: readonly [RefillParams]
  expected: Address
  initcodeKeccak: Hex
  sha256: string
}

const fail = (message: string): never => {
  throw new Error(`gas refill manifest: ${message}`)
}

export const refillArgs = (m: Record<Key, string>): RefillPlan['args'] => [{
  usdc: addr(m.USDC), weth: addr(m.WETH), treasury: addr(m.GAS_TREASURY), relayer: addr(m.RELAYER), router: addr(m.UNISWAP_ROUTER),
  poolFee: Number(m.POOL_FEE), ethUsdFeed: addr(m.ETH_USD_FEED), sequencerFeed: addr(m.SEQUENCER_FEED),
  refillBelowWei: BigInt(m.REFILL_BELOW_WEI), maxOracleAge: BigInt(m.MAX_ORACLE_AGE_SECONDS),
  dailyCapUsdc: BigInt(m.DAILY_CAP_USDC_UNITS), maxTargetWei: BigInt(m.MAX_TARGET_WEI), maxSlippageBps: BigInt(m.MAX_SLIPPAGE_BPS),
}]

export const refillInitcodeKeccak = (artifact: { abi: unknown; bytecode: Hex }, args: RefillPlan['args']): Hex =>
  keccak256(encodeDeployData({ abi: artifact.abi as Abi, bytecode: artifact.bytecode, args: args as never }))

export function loadRefillManifest(path: string, mainPath: string, approvedSha256?: string): RefillPlan {
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
    if (!REFILL_KEYS.includes(key)) fail(`unexpected key ${key}`)
    if (values[key] !== undefined) fail(`duplicate key ${key}`)
    values[key] = trimmed.slice(eq + 1).trim()
  }
  for (const key of REFILL_KEYS) if (values[key] === undefined) fail(`missing key ${key}`)
  const m = values as Record<Key, string>

  for (const key of ['DEPLOYER', 'RELAYER', 'GAS_TREASURY', 'USDC', 'WETH', 'UNISWAP_ROUTER', 'ETH_USD_FEED', 'SEQUENCER_FEED', 'GAS_REFILL_EXPECTED_ADDRESS'] as Key[]) {
    if (!isAddress(m[key], { strict: true }) || addr(m[key]) !== m[key]) fail(`${key} is not a checksummed address: ${m[key]}`)
  }
  if (m.CHAIN_ID !== '8453' || m.NETWORK !== 'Base Mainnet') fail('this manifest format is for Base Mainnet (8453) only')
  for (const [key, pinned] of Object.entries(BASE_MAINNET_THIRD_PARTY)) {
    if (m[key as Key] !== pinned) fail(`${key} must be ${pinned}`)
  }
  const int = (key: Key, min: bigint, max: bigint) => {
    if (!/^\d{1,30}$/.test(m[key]) || BigInt(m[key]) < min || BigInt(m[key]) > max) fail(`${key} must be between ${min} and ${max}`)
  }
  if (!['100', '500', '3000'].includes(m.POOL_FEE)) fail('POOL_FEE must be 100, 500 or 3000')
  // Start values; the treasury raises the cap and the ceiling later with setLimits, no new contract.
  int('REFILL_BELOW_WEI', 1_000_000_000_000_000n, 50_000_000_000_000_000n) // floor 0.001 to 0.05 ETH
  int('MAX_ORACLE_AGE_SECONDS', 1_200n, 7_200n) // the feed's heartbeat is 20 minutes
  int('DAILY_CAP_USDC_UNITS', 1_000_000n, 1_000_000_000n) // 1 to 1,000 USDC a day at deploy
  int('MAX_TARGET_WEI', 2_000_000_000_000_000n, 1_000_000_000_000_000_000n) // 0.002 to 1 ETH
  int('MAX_SLIPPAGE_BPS', 50n, 500n)
  if (BigInt(m.MAX_TARGET_WEI) <= BigInt(m.REFILL_BELOW_WEI)) fail('MAX_TARGET_WEI must be above REFILL_BELOW_WEI')
  if (!/^0x[0-9a-f]{64}$/.test(m.GAS_REFILL_INITCODE_KECCAK)) fail('GAS_REFILL_INITCODE_KECCAK must be 0x + 64 lowercase hex')

  const main = loadManifest(mainPath)
  if (main.sha256 !== m.MAIN_MANIFEST_SHA256) fail(`MAIN_MANIFEST_SHA256 does not match ${mainPath} (${main.sha256})`)
  for (const [key, mainKey] of [['DEPLOYER', 'DEPLOYER'], ['RELAYER', 'RELAYER'], ['GAS_TREASURY', 'GAS_TREASURY'], ['USDC', 'USDC']] as const) {
    if (m[key] !== (main as Record<string, string>)[mainKey]) fail(`${key} (${m[key]}) differs from the main manifest's ${mainKey}`)
  }
  return { args: refillArgs(m), expected: addr(m.GAS_REFILL_EXPECTED_ADDRESS), initcodeKeccak: m.GAS_REFILL_INITCODE_KECCAK as Hex, sha256 }
}
