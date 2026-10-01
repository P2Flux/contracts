/**
 * The gas refill manifest loader, attacked one field at a time, on top of the REAL approved Base
 * Mainnet manifest. Nothing touches a network.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { loadRefillManifest, refillArgs, refillInitcodeKeccak } from '../scripts/refill-manifest.js'
import { loadManifest } from '../scripts/manifest.js'

const MAIN = new URL('../manifests/base-mainnet.manifest', import.meta.url).pathname
const REAL = new URL('../manifests/base-mainnet-gas-refill.manifest', import.meta.url).pathname
const main = loadManifest(MAIN)
const artifact = JSON.parse(readFileSync(new URL('../out/P2FluxGasRefill.json', import.meta.url), 'utf8'))
const valid = (): Record<string, string> =>
  Object.fromEntries(readFileSync(REAL, 'utf8').trim().split('\n').map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
const write = (v: Record<string, string>) => {
  const p = join(mkdtempSync(join(tmpdir(), 'refill-manifest-')), 'm')
  writeFileSync(p, Object.entries(v).map(([k, x]) => `${k}=${x}`).join('\n') + '\n')
  return p
}
const sha = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex')
const STRANGER = '0x000000000000000000000000000000000000dEaD'

test('the manifest in the repository loads against the contract as compiled here, only under its hash', () => {
  const plan = loadRefillManifest(REAL, MAIN, sha(REAL))
  assert.equal(plan.args[2], main.GAS_TREASURY)
  assert.equal(plan.args[3], main.RELAYER)
  assert.equal(plan.initcodeKeccak, refillInitcodeKeccak(artifact, refillArgs(valid() as never)))
  assert.throws(() => loadRefillManifest(REAL, MAIN, 'ab'.repeat(32)), /the approved manifest is/)
})

const refused: [string, (v: Record<string, string>) => void, RegExp][] = [
  ['ETH to anyone but the relayer', (v) => { v.RELAYER = STRANGER }, /differs from the main manifest/],
  ['USDC from anyone but the gas treasury', (v) => { v.GAS_TREASURY = STRANGER }, /differs from the main manifest/],
  ['another router', (v) => { v.UNISWAP_ROUTER = STRANGER }, /UNISWAP_ROUTER must be/],
  ['another price feed', (v) => { v.ETH_USD_FEED = STRANGER }, /ETH_USD_FEED must be/],
  ['another WETH', (v) => { v.WETH = STRANGER }, /WETH must be/],
  ['a refill above 50 USDC', (v) => { v.REFILL_USDC_UNITS = '50000001' }, /REFILL_USDC_UNITS/],
  ['more than 6 a day', (v) => { v.MAX_REFILLS_PER_DAY = '7' }, /MAX_REFILLS_PER_DAY/],
  ['more than 5 % price allowance', (v) => { v.MAX_SLIPPAGE_BPS = '501' }, /MAX_SLIPPAGE_BPS/],
  ['a price older than a day', (v) => { v.MAX_ORACLE_AGE_SECONDS = '86401' }, /MAX_ORACLE_AGE_SECONDS/],
  ['an unknown pool', (v) => { v.POOL_FEE = '10000' }, /POOL_FEE/],
  ['another chain', (v) => { v.CHAIN_ID = '84532' }, /Base Mainnet/],
  ['a stale main manifest', (v) => { v.MAIN_MANIFEST_SHA256 = 'cd'.repeat(32) }, /MAIN_MANIFEST_SHA256/],
  ['an extra key', (v) => { v.OWNER = STRANGER }, /unexpected key/],
  ['a missing key', (v) => { delete v.MAX_REFILLS_PER_DAY }, /missing key/],
]
for (const [name, mutate, message] of refused) {
  test(`refused: ${name}`, () => {
    const v = valid()
    mutate(v)
    assert.throws(() => loadRefillManifest(write(v), MAIN), message)
  })
}
