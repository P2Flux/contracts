import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { privateKeyToAccount } from 'viem/accounts'
import { SPONSORED_KEYS, loadManifest, requireSponsored } from '../scripts/manifest.js'
import { assertImmutables, assertPredicted, planFromManifest } from '../scripts/sponsored-manifest.js'

/**
 * The Mainnet manifest is the only thing a sponsored Mainnet deployment may be checked against, so
 * the machinery is proven here without a chain: what it accepts, what it refuses, and that the
 * environment can never define an immutable financial parameter behind its back. The Mainnet
 * deployment itself stays refused (deploy-sponsored.ts) - this is readiness, not permission.
 */
const A = (n: number) => `0x${n.toString(16).padStart(40, '0')}`.replace(/^0x0/, '0x1') // distinct, checksum-neutral digits
const deployerKey = `0x${'11'.repeat(32)}` as const
const relayerKey = `0x${'22'.repeat(32)}` as const
const DEPLOYER = privateKeyToAccount(deployerKey).address
const RELAYER = privateKeyToAccount(relayerKey).address
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'

const base = {
  NETWORK: 'Base Mainnet', CHAIN_ID: '8453',
  DEPLOYER, ADMIN: '0x1111111111111111111111111111111111111111', RELAYER,
  FEE_WALLET: '0x2222222222222222222222222222222222222222', GAS_TREASURY: '0x3333333333333333333333333333333333333333', USDC,
  SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC, SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: '0x2222222222222222222222222222222222222222',
  SPLITTER_ONE_TIME_BPS: '100', SPLITTER_EXPECTED_ADDRESS: '0x4444444444444444444444444444444444444444', SPLITTER_GAS_ESTIMATE: '1',
  RECURRING_CONSTRUCTOR_ARG_1_ADMIN: '0x1111111111111111111111111111111111111111', RECURRING_CONSTRUCTOR_ARG_2_RELAYER: RELAYER,
  RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET: '0x2222222222222222222222222222222222222222', RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY: '0x3333333333333333333333333333333333333333',
  RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN: USDC,
  RECURRING_FEE_BPS: '200', RECURRING_NETWORK_FEE_MICRO_USDC: '100000', RECURRING_GAS_REIMBURSEMENT_HARD_CAP_MICRO_USDC: '50000',
  RECURRING_EXPECTED_ADDRESS: '0x5555555555555555555555555555555555555555', RECURRING_GAS_ESTIMATE: '1',
  DEPLOYER_FUNDING_ETH: '0.1', RELAYER_FUNDING_ETH: '0.1',
}
const sponsored = {
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC,
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: base.FEE_WALLET,
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY: base.GAS_TREASURY,
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER: RELAYER,
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC: '100000',
  SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC: '250000',
  SPONSORED_SPLITTER_ONE_TIME_BPS: '100',
  SPONSORED_SPLITTER_EXPECTED_ADDRESS: '0x6666666666666666666666666666666666666666',
  GAS_SPONSOR_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: USDC,
  GAS_SPONSOR_CONSTRUCTOR_ARG_2_GAS_TREASURY: base.GAS_TREASURY,
  GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER: RELAYER,
  GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC: '250000',
  GAS_SPONSOR_EXPECTED_ADDRESS: '0x7777777777777777777777777777777777777777',
}
const write = (values: Record<string, string>) => {
  const path = join(mkdtempSync(join(tmpdir(), 'manifest-')), 'mainnet.manifest')
  writeFileSync(path, Object.entries(values).map(([k, v]) => `${k}=${v}`).join('\n') + '\n')
  return path
}
void A

test('a complete sponsored manifest loads, and the plan comes from it alone', () => {
  const m = loadManifest(write({ ...base, ...sponsored }))
  const plan = planFromManifest(m, {})
  assert.equal(plan.token.toLowerCase(), USDC.toLowerCase())
  assert.equal(plan.relayer, RELAYER)
  assert.equal(plan.fixedNetworkFee, 100_000n)
  assert.equal(plan.hardCap, 250_000n)
  assert.deepEqual(plan.expected, { splitter: sponsored.SPONSORED_SPLITTER_EXPECTED_ADDRESS, sponsor: sponsored.GAS_SPONSOR_EXPECTED_ADDRESS })
})

test('a manifest without the group still loads for the other contracts, but a sponsored deploy is refused', () => {
  const m = loadManifest(write(base))
  assert.throws(() => requireSponsored(m), /requires manifest keys: SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN/)
})

test('every missing sponsored field is refused, one at a time', () => {
  for (const key of SPONSORED_KEYS) {
    const values = { ...base, ...sponsored } as Record<string, string>
    delete values[key]
    assert.throws(() => loadManifest(write(values)), /sponsored group incomplete/, `${key} missing must refuse`)
  }
})

test('an argument line that does not repeat its role line is refused, not resolved', () => {
  for (const [key, bad] of [
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET', base.GAS_TREASURY],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_3_RELAYER', base.ADMIN],
    ['SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC', '200000'],
    ['GAS_SPONSOR_CONSTRUCTOR_ARG_4_MAX_SPONSOR_FEE_HARD_CAP_MICRO_USDC', '240000'],
    ['SPONSORED_SPLITTER_ONE_TIME_BPS', '150'],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', sponsored.GAS_SPONSOR_EXPECTED_ADDRESS],
    ['SPONSORED_SPLITTER_EXPECTED_ADDRESS', 'not-an-address'],
  ] as const) {
    assert.throws(() => loadManifest(write({ ...base, ...sponsored, [key]: bad })), /manifest:/, `${key}=${bad} must refuse`)
  }
})

test('environment variables are checked against the manifest and may never define a value', () => {
  const m = loadManifest(write({ ...base, ...sponsored }))
  for (const env of [
    { FEE_WALLET: base.GAS_TREASURY },
    { GAS_TREASURY: base.FEE_WALLET },
    { USDC_ADDRESS: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' },
    { SPONSOR_HARD_CAP_UNITS: '500000' },
    { FIXED_NETWORK_FEE_UNITS: '0' },
    { RELAYER_PK: deployerKey },
  ]) {
    assert.throws(() => planFromManifest(m, env), /disagrees with the manifest|does not derive to the manifest RELAYER/, JSON.stringify(env))
  }
  // Agreeing environment is fine, and changes nothing.
  const plan = planFromManifest(m, { FEE_WALLET: base.FEE_WALLET.toLowerCase(), SPONSOR_HARD_CAP_UNITS: '250000', RELAYER_PK: relayerKey })
  assert.equal(plan.hardCap, 250_000n)
})

test('a deployer nonce that would create a different address is refused before any gas is spent', () => {
  const m = loadManifest(write({ ...base, ...sponsored }))
  const plan = planFromManifest(m, {})
  assert.throws(() => assertPredicted(plan.expected!.splitter, DEPLOYER, 0, 'P2FluxSponsoredSplitter'), /would be created at .* the manifest expects/)
})

test('an immutable read back from the chain that disagrees with the manifest is refused', () => {
  const want = { supportedToken: USDC, FIXED_NETWORK_FEE: 100_000n, MAX_NETWORK_FEE_HARD_CAP: 250_000n }
  assertImmutables('x', want, { supportedToken: USDC.toLowerCase(), FIXED_NETWORK_FEE: 100_000n, MAX_NETWORK_FEE_HARD_CAP: 250_000n })
  assert.throws(() => assertImmutables('x', want, { ...want, FIXED_NETWORK_FEE: 100_001n }), /FIXED_NETWORK_FEE is 100001 on chain, manifest says 100000/)
  assert.throws(() => assertImmutables('x', want, { ...want, supportedToken: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' }), /supportedToken/)
})

test('the deploy script refuses Mainnet without a manifest; the rehearsal exits before any wallet exists', async () => {
  const { readFileSync } = await import('node:fs')
  const src = readFileSync(new URL('../scripts/deploy-sponsored.ts', import.meta.url), 'utf8')
  assert.doesNotMatch(src, /Base Mainnet is not supported yet/)
  assert.match(src, /expectedChain === base\.id && !manifest/)
  assert.match(src, /Base Mainnet deploys only from an approved manifest/)
  assert.ok(src.indexOf("process.env.DRY_RUN === '1'") < src.indexOf('createWalletClient({ account: deployer'))
})
