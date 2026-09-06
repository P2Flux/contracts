import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { privateKeyToAccount } from 'viem/accounts'
import { loadManifest } from '../scripts/manifest.js'
import { assertImmutables, assertPredicted, planFromManifest } from '../scripts/sponsored-manifest.js'
import { getAddress, getContractAddress } from 'viem'

const DK = `0x${'31'.repeat(32)}` as const, RK = `0x${'32'.repeat(32)}` as const
const DEPLOYER = privateKeyToAccount(DK).address, RELAYER = privateKeyToAccount(RK).address
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
const FEE = getAddress('0x' + 'a1'.repeat(20)), GAS = getAddress('0x' + 'b2'.repeat(20)), ADMIN = getAddress('0x' + 'c3'.repeat(20))
const exp = (n: number) => getContractAddress({ from: DEPLOYER, nonce: BigInt(n) })
const base: Record<string, string> = {
  NETWORK: 'Base Mainnet', CHAIN_ID: '8453', DEPLOYER, ADMIN, RELAYER, FEE_WALLET: FEE, GAS_TREASURY: GAS, USDC,
  SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC, SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: FEE, SPLITTER_ONE_TIME_BPS: '100', SPLITTER_EXPECTED_ADDRESS: exp(0), SPLITTER_GAS_ESTIMATE: '1',
  RECURRING_CONSTRUCTOR_ARG_1_ADMIN: ADMIN, RECURRING_CONSTRUCTOR_ARG_2_RELAYER: RELAYER, RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET: FEE, RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY: GAS, RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN: USDC,
  RECURRING_FEE_BPS: '200', RECURRING_NETWORK_FEE_MICRO_USDC: '100000', RECURRING_GAS_REIMBURSEMENT_HARD_CAP_MICRO_USDC: '50000', RECURRING_EXPECTED_ADDRESS: exp(1), RECURRING_GAS_ESTIMATE: '1',
  DEPLOYER_FUNDING_ETH: '0.1', RELAYER_FUNDING_ETH: '0.1',
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC, SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: FEE, SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY: GAS, SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER: RELAYER,
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC: '100000', SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC: '250000', SPONSORED_SPLITTER_ONE_TIME_BPS: '100', SPONSORED_SPLITTER_EXPECTED_ADDRESS: exp(2),
  GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC, GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY: GAS, GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER: RELAYER, GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC: '250000', GAS_SPONSOR_EXPECTED_ADDRESS: exp(3),
}
const write = (v: Record<string, string>) => { const p = join(mkdtempSync(join(tmpdir(), 'mf-')), 'm'); writeFileSync(p, Object.entries(v).map(([k, x]) => `${k}=${x}`).join('\n') + '\n'); return p }

test('a correct Mainnet plan resolves from the manifest alone', () => {
  const plan = planFromManifest(loadManifest(write(base)), {})
  assert.equal(plan.relayer, RELAYER); assert.equal(plan.fixedNetworkFee, 100_000n); assert.equal(plan.hardCap, 250_000n)
  assert.equal(assertPredicted(plan.expected!.splitter, DEPLOYER, 2, 'x'), exp(2))
})

test('every single-field corruption refuses', () => {
  const cases: [string, string][] = [
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC', '90000'],
    ['SPONSORED_SPLITTER_ONE_TIME_BPS', '99'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC', '100000'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC', '2000000'],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC', '250001'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', '0x036CbD53842c5426634e7929541eC2318f3dCF7e'],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', FEE],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', GAS],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY', FEE],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY', ADMIN],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER', ADMIN],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER', DEPLOYER],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', exp(3)],
    ['GAS_SPONSOR_EXPECTED_ADDRESS', exp(1)],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', '0x0000000000000000000000000000000000000000'],
    ['USDC', '0x036CbD53842c5426634e7929541eC2318f3dCF7e'],
    ['CHAIN_ID', '84532'],
  ]
  for (const [k, v] of cases) assert.throws(() => loadManifest(write({ ...base, [k]: v })), /manifest:/, `${k}=${v}`)
  for (const k of Object.keys(base).filter((k) => k.startsWith('SPONSORED_') || k.startsWith('GAS_SPONSOR_'))) {
    const v = { ...base }; delete v[k]
    assert.throws(() => loadManifest(write(v)), /sponsored group incomplete/, k)
  }
})

test('environment can never silently define an immutable value; wrong deployer/relayer keys refuse', () => {
  const m = loadManifest(write(base))
  for (const env of [{ FEE_WALLET: GAS }, { GAS_TREASURY: FEE }, { USDC_ADDRESS: FEE }, { SPONSOR_HARD_CAP_UNITS: '250001' }, { FIXED_NETWORK_FEE_UNITS: '1' }, { RELAYER_PK: DK }]) {
    assert.throws(() => planFromManifest(m, env), /disagrees|does not derive/, JSON.stringify(env))
  }
  const plan = planFromManifest(m, { FEE_WALLET: 'not-even-an-address'.padEnd(0) === '' ? '' : FEE.toLowerCase(), FIXED_NETWORK_FEE_UNITS: '100000' })
  assert.equal(plan.fixedNetworkFee, 100_000n, 'agreeing env changes nothing')
  // The deploy script derives the deployer from DEPLOYER_PK and checks it against the manifest.
  const src = readFileSync(new URL('../scripts/deploy-sponsored.ts', import.meta.url), 'utf8')
  assert.match(src, /DEPLOYER_PK does not derive to the manifest DEPLOYER/)
  assert.match(src, /Base Mainnet deploys only from an approved manifest/, 'Mainnet is manifest-only')
  assert.doesNotMatch(src, /Base Mainnet is not supported yet/)
  assert.throws(() => assertPredicted(exp(2), DEPLOYER, 5, 'x'), /would be created at/)
  assert.throws(() => assertImmutables('x', { relayer: RELAYER }, { relayer: ADMIN }), /relayer is/)
})
