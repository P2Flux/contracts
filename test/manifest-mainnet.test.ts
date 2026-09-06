/**
 * The REAL Base Mainnet manifest (manifests/base-mainnet.manifest), not a fixture: it must load,
 * name exactly the canonical roles and economics, predict the sponsored pair from deployer nonces
 * 2 and 3 in deployment order (SponsoredSplitter first, then GasSponsor), and refuse every
 * single-field corruption. Nothing here touches a network.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { getContractAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { loadManifest } from '../scripts/manifest.js'
import { assertImmutables, assertPredicted, planFromManifest } from '../scripts/sponsored-manifest.js'

const PATH = new URL('../manifests/base-mainnet.manifest', import.meta.url).pathname
const CANON = {
  DEPLOYER: '0x69D942d721156587bb53241A71614f26B4b38E2a',
  ADMIN: '0xEc8779352AF47C5CbF877e1B22B5CFF6Df042410',
  RELAYER: '0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309',
  FEE_WALLET: '0x12FDDADa5C8d027537B90342a68F5dd1A79C8feB',
  GAS_TREASURY: '0xdCdE2146cF3ab9aE37933211AF8943c807c31506',
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  SPLITTER_EXPECTED_ADDRESS: '0x5A3bD0945cd0C80B124870881dE49a717D20E0D0',
  RECURRING_EXPECTED_ADDRESS: '0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975',
} as const
/** Deployment order in deploy-sponsored.ts: the splitter is the deployer's next CREATE, the sponsor the one after. */
const SPONSORED_SPLITTER_NONCE = 2
const GAS_SPONSOR_NONCE = 3

const lines = () => Object.fromEntries(readFileSync(PATH, 'utf8').split('\n').filter(Boolean).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
const write = (v: Record<string, string>) => {
  const p = join(mkdtempSync(join(tmpdir(), 'mainnet-manifest-')), 'm')
  writeFileSync(p, Object.entries(v).map(([k, x]) => `${k}=${x}`).join('\n') + '\n')
  return p
}

test('the Mainnet manifest loads and names the canonical roles, token and economics', () => {
  const m = loadManifest(PATH)
  for (const [k, v] of Object.entries(CANON)) assert.equal(m[k as keyof typeof CANON], v, k)
  assert.equal(m.CHAIN_ID, '8453')
  assert.equal(m.SPONSORED_SPLITTER_ONE_TIME_BPS, '100')
  assert.equal(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC, '100000')
  assert.equal(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC, '250000')
  assert.equal(m.GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC, '250000')
  const plan = planFromManifest(m, {})
  assert.equal(plan.token, CANON.USDC); assert.equal(plan.feeWallet, CANON.FEE_WALLET); assert.equal(plan.gasTreasury, CANON.GAS_TREASURY); assert.equal(plan.relayer, CANON.RELAYER)
  assert.equal(plan.fixedNetworkFee, 100_000n); assert.equal(plan.hardCap, 250_000n)
})

test('the existing contracts are the deployer\'s nonce 0 and 1, and the sponsored pair is nonce 2 then 3', () => {
  const m = loadManifest(PATH)
  assert.equal(getContractAddress({ from: CANON.DEPLOYER, nonce: 0n }), m.SPLITTER_EXPECTED_ADDRESS)
  assert.equal(getContractAddress({ from: CANON.DEPLOYER, nonce: 1n }), m.RECURRING_EXPECTED_ADDRESS)
  const plan = planFromManifest(m, {})
  assert.equal(assertPredicted(plan.expected!.splitter, CANON.DEPLOYER, SPONSORED_SPLITTER_NONCE, 'P2FluxSponsoredSplitter'), m.SPONSORED_SPLITTER_EXPECTED_ADDRESS)
  assert.equal(assertPredicted(plan.expected!.sponsor, CANON.DEPLOYER, GAS_SPONSOR_NONCE, 'P2FluxGasSponsor'), m.GAS_SPONSOR_EXPECTED_ADDRESS)
  // Any other nonce - a stray transaction from the deployer before the run - is refused before gas is spent.
  for (const n of [0, 1, 3, 4]) assert.throws(() => assertPredicted(plan.expected!.splitter, CANON.DEPLOYER, n, 'P2FluxSponsoredSplitter'), /would be created at .* the manifest expects/)
  for (const n of [0, 1, 2, 4]) assert.throws(() => assertPredicted(plan.expected!.sponsor, CANON.DEPLOYER, n, 'P2FluxGasSponsor'), /would be created at .* the manifest expects/)
})

test('every single-field corruption of the real manifest is refused', () => {
  const base = lines()
  const sepoliaUsdc = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
  const other = privateKeyToAccount(`0x${'77'.repeat(32)}`).address
  const cases: [string, string][] = [
    ['CHAIN_ID', '84532'],
    ['NETWORK', 'Base Sepolia'],
    ['USDC', sepoliaUsdc],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', sepoliaUsdc],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN', sepoliaUsdc],
    ['RELAYER', other],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER', other],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER', CANON.ADMIN],
    ['FEE_WALLET', CANON.GAS_TREASURY],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', CANON.GAS_TREASURY],
    ['GAS_TREASURY', CANON.FEE_WALLET],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY', other],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY', other],
    ['SPONSORED_SPLITTER_ONE_TIME_BPS', '99'],
    ['SPLITTER_ONE_TIME_BPS', '101'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC', '90000'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC', '100000'],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC', '2000000'],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC', '250001'],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', base.GAS_SPONSOR_EXPECTED_ADDRESS!],
    ['GAS_SPONSOR_EXPECTED_ADDRESS', CANON.SPLITTER_EXPECTED_ADDRESS],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', '0x0000000000000000000000000000000000000000'],
    // A wrong EIP-55 checksum (one letter's case flipped) is refused, not repaired.
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', base.SPONSORED_SPLITTER_EXPECTED_ADDRESS!.replace(/[a-f]/, (c) => c.toUpperCase())],
  ]
  for (const [k, v] of cases) assert.throws(() => loadManifest(write({ ...base, [k]: v })), /manifest:/, `${k}=${v}`)
  for (const k of Object.keys(base)) {
    const v = { ...base }; delete v[k]
    assert.throws(() => loadManifest(write(v)), /manifest:/, `missing ${k}`)
  }
  assert.throws(() => loadManifest(write({ ...base, EXTRA: '1' })), /unexpected key/)
  /* A different DEPLOYER is a valid role line, so the loader alone accepts it - and then nothing it
   * predicts matches: the pair the manifest names can only be created by the canonical deployer. */
  const wrongDeployer = loadManifest(write({ ...base, DEPLOYER: other }))
  const plan = planFromManifest(wrongDeployer, {})
  assert.throws(() => assertPredicted(plan.expected!.splitter, other, SPONSORED_SPLITTER_NONCE, 'P2FluxSponsoredSplitter'), /the manifest expects/)
  assert.throws(() => assertPredicted(plan.expected!.sponsor, other, GAS_SPONSOR_NONCE, 'P2FluxGasSponsor'), /the manifest expects/)
})

test('a predicted-address mismatch from a moved deployer nonce is refused; a wrong deployer key never matches', () => {
  const plan = planFromManifest(loadManifest(PATH), {})
  const stranger = privateKeyToAccount(`0x${'78'.repeat(32)}`).address
  assert.throws(() => assertPredicted(plan.expected!.splitter, stranger, SPONSORED_SPLITTER_NONCE, 'P2FluxSponsoredSplitter'), /the manifest expects/)
  assert.throws(() => assertPredicted(plan.expected!.splitter, CANON.DEPLOYER, SPONSORED_SPLITTER_NONCE + 1, 'P2FluxSponsoredSplitter'), /the manifest expects/)
})

test('environment disagreement with the real manifest is refused; agreement defines nothing', () => {
  const m = loadManifest(PATH)
  for (const env of [
    { FEE_WALLET: CANON.GAS_TREASURY }, { GAS_TREASURY: CANON.FEE_WALLET }, { USDC_ADDRESS: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' },
    { SPONSOR_HARD_CAP_UNITS: '500000' }, { FIXED_NETWORK_FEE_UNITS: '0' }, { RELAYER_PK: `0x${'79'.repeat(32)}` },
  ]) assert.throws(() => planFromManifest(m, env), /disagrees with the manifest|does not derive to the manifest RELAYER/, JSON.stringify(env))
  const plan = planFromManifest(m, { FEE_WALLET: CANON.FEE_WALLET.toLowerCase(), SPONSOR_HARD_CAP_UNITS: '250000', FIXED_NETWORK_FEE_UNITS: '100000' })
  assert.equal(plan.hardCap, 250_000n)
})

test('an immutable read back that disagrees with the real manifest is refused', () => {
  const plan = planFromManifest(loadManifest(PATH), {})
  const splitter = { supportedToken: plan.token, feeWallet: plan.feeWallet, gasTreasury: plan.gasTreasury, relayer: plan.relayer, FIXED_NETWORK_FEE: plan.fixedNetworkFee, MAX_NETWORK_FEE_HARD_CAP: plan.hardCap, ONE_TIME_BPS: 100n }
  assertImmutables('P2FluxSponsoredSplitter', splitter, { ...splitter, feeWallet: plan.feeWallet.toLowerCase() })
  for (const [k, v] of Object.entries({ feeWallet: CANON.GAS_TREASURY, gasTreasury: CANON.FEE_WALLET, relayer: CANON.ADMIN, supportedToken: '0x036CbD53842c5426634e7929541eC2318f3dCF7e', FIXED_NETWORK_FEE: 100_001n, MAX_NETWORK_FEE_HARD_CAP: 250_001n, ONE_TIME_BPS: 99n })) {
    assert.throws(() => assertImmutables('P2FluxSponsoredSplitter', splitter, { ...splitter, [k]: v }), new RegExp(`P2FluxSponsoredSplitter\\.${k} is`), k)
  }
  const sponsor = { supportedToken: plan.token, gasTreasury: plan.gasTreasury, relayer: plan.relayer, MAX_SPONSOR_FEE_HARD_CAP: plan.hardCap }
  assert.throws(() => assertImmutables('P2FluxGasSponsor', sponsor, { ...sponsor, MAX_SPONSOR_FEE_HARD_CAP: 250_000_000n }), /MAX_SPONSOR_FEE_HARD_CAP is 250000000/)
})
