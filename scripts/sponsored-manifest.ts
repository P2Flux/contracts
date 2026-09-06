import { getContractAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { addr, requireSponsored, type Manifest } from './manifest.js'

/**
 * What a sponsored deployment is going to do, resolved from ONE source.
 *
 * With a manifest, the manifest. Every immutable constructor argument, both expected addresses,
 * both economic constants. Environment variables that happen to be set are compared against it
 * and refused on disagreement; none of them may define a value. Without a manifest (testnet), the
 * environment is the source, as it always was - and Mainnet is refused before either applies.
 */
export type SponsoredPlan = {
  token: Address
  feeWallet: Address
  gasTreasury: Address
  relayer: Address
  fixedNetworkFee: bigint
  hardCap: bigint
  expected: { splitter: Address; sponsor: Address } | null
}

const fail = (message: string): never => {
  throw new Error(`sponsored deployment: ${message}`)
}

const disagree = (name: string, env: string | undefined, manifest: string) => {
  if (env !== undefined && env !== '' && env.toLowerCase() !== manifest.toLowerCase()) {
    fail(`${name}=${env} disagrees with the manifest (${manifest}); the manifest is the source of truth`)
  }
}

export function planFromManifest(manifest: Manifest, env: NodeJS.ProcessEnv): SponsoredPlan {
  const m = requireSponsored(manifest)
  const plan: SponsoredPlan = {
    token: addr(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN),
    feeWallet: addr(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET),
    gasTreasury: addr(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_3_GAS_TREASURY),
    relayer: addr(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_4_RELAYER),
    fixedNetworkFee: BigInt(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_5_FIXED_NETWORK_FEE_MICRO_USDC),
    hardCap: BigInt(m.SPONSORED_SPLITTER_CONSTRUCTOR_ARG_6_MAX_NETWORK_FEE_HARD_CAP_MICRO_USDC),
    expected: { splitter: addr(m.SPONSORED_SPLITTER_EXPECTED_ADDRESS), sponsor: addr(m.GAS_SPONSOR_EXPECTED_ADDRESS) },
  }
  // Checked, never defining.
  disagree('USDC_ADDRESS', env.USDC_ADDRESS, plan.token)
  disagree('FEE_WALLET', env.FEE_WALLET, plan.feeWallet)
  disagree('GAS_TREASURY', env.GAS_TREASURY, plan.gasTreasury)
  disagree('SPONSOR_HARD_CAP_UNITS', env.SPONSOR_HARD_CAP_UNITS, plan.hardCap.toString())
  disagree('FIXED_NETWORK_FEE_UNITS', env.FIXED_NETWORK_FEE_UNITS, plan.fixedNetworkFee.toString())
  if (env.RELAYER_PK) {
    const derived = privateKeyToAccount(env.RELAYER_PK as Hex).address
    if (derived.toLowerCase() !== plan.relayer.toLowerCase()) fail('RELAYER_PK does not derive to the manifest RELAYER')
  }
  return plan
}

/** The address this deployer's next transaction creates must be the one the manifest approved. */
export function assertPredicted(expected: Address, deployer: Address, nonce: number, name: string) {
  const willCreate = getContractAddress({ from: deployer, nonce: BigInt(nonce) })
  if (willCreate.toLowerCase() !== expected.toLowerCase()) {
    fail(`${name} would be created at ${willCreate} (deployer nonce ${nonce}); the manifest expects ${expected}`)
  }
  return willCreate
}

/** Every immutable read back off the deployed contract must be what the manifest said it would be. */
export function assertImmutables(name: string, expected: Record<string, string | bigint>, read: Record<string, unknown>) {
  for (const [key, want] of Object.entries(expected)) {
    const got = read[key]
    const same = typeof want === 'bigint' ? BigInt(got as bigint) === want : String(got).toLowerCase() === want.toLowerCase()
    if (!same) fail(`${name}.${key} is ${String(got)} on chain, manifest says ${String(want)}`)
  }
}
