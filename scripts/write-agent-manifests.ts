/**
 * Writes the two Base Mainnet manifests for agent payments - the x402 splitter and the batch vaults -
 * from the approved main manifest and the contracts as compiled here. Read-only on chain (the
 * deployer's nonce, and that USDC and the Permit2 proxy exist there); signs and sends nothing.
 *
 *   npx tsx scripts/write-agent-manifests.ts
 *
 * The splitter is deployed first (deployer nonce N), the vaults second (N+1), the gas refill third
 * (N+2). Any other transaction from the deployer in between changes the addresses: rerun this and
 * approve the new hashes.
 */
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { createPublicClient, getContractAddress, http, type Hex } from 'viem'
import { base } from 'viem/chains'
import { X402_UPTO_PROXY } from '../src/x402.js'
import { batchInitcodeKeccak, loadBatchManifest } from './batch-manifest.js'
import { addr, loadManifest } from './manifest.js'
import { loadX402Manifest, x402InitcodeKeccak } from './x402-manifest.js'
import { BASE_MAINNET_THIRD_PARTY, loadRefillManifest, refillArgs, refillInitcodeKeccak } from './refill-manifest.js'

const MAIN = process.env.DEPLOY_MANIFEST || 'manifests/base-mainnet.manifest'
const main = loadManifest(MAIN)
const artifact = (name: string) => JSON.parse(readFileSync(new URL(`../out/${name}.json`, import.meta.url), 'utf8')) as { abi: unknown[]; bytecode: Hex }

const chain = createPublicClient({ chain: base, transport: http(process.env.RPC_URL_DEPLOY || 'https://mainnet.base.org') })
if ((await chain.getChainId()) !== base.id) throw new Error('RPC is not Base Mainnet')
for (const [name, address] of [['USDC', main.USDC], ['Permit2 proxy', X402_UPTO_PROXY]] as const) {
  const code = await chain.getCode({ address: addr(address) })
  if (!code || code === '0x') throw new Error(`no contract at ${name} ${address} on Base Mainnet`)
}
const nonce = BigInt(await chain.getTransactionCount({ address: addr(main.DEPLOYER) }))
const token = addr(main.USDC), feeWallet = addr(main.FEE_WALLET), relayer = addr(main.RELAYER)
const head = { NETWORK: 'Base Mainnet', CHAIN_ID: '8453', MAIN_MANIFEST_SHA256: main.sha256, DEPLOYER: main.DEPLOYER }

const files: [string, Record<string, string>][] = [
  ['manifests/base-mainnet-x402.manifest', {
    ...head, RELAYER: main.RELAYER, FEE_WALLET: main.FEE_WALLET, USDC: main.USDC,
    X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: main.USDC,
    X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: main.FEE_WALLET,
    X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER: main.RELAYER,
    X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY: X402_UPTO_PROXY,
    X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC: '3000',
    X402_SPLITTER_FEE_BPS: '100',
    X402_SPLITTER_EXPECTED_ADDRESS: getContractAddress({ from: addr(main.DEPLOYER), nonce }),
    X402_SPLITTER_INITCODE_KECCAK: x402InitcodeKeccak(artifact('P2FluxX402Splitter'), { token, feeWallet, relayer, uptoProxy: X402_UPTO_PROXY, minFee: 3000n } as never),
  }],
  ['manifests/base-mainnet-batch.manifest', {
    ...head, FEE_WALLET: main.FEE_WALLET, USDC: main.USDC,
    BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: main.USDC,
    BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET: main.FEE_WALLET,
    BATCH_VAULTS_FEE_BPS: '300',
    BATCH_VAULTS_EXPECTED_ADDRESS: getContractAddress({ from: addr(main.DEPLOYER), nonce: nonce + 1n }),
    BATCH_VAULTS_INITCODE_KECCAK: batchInitcodeKeccak(artifact('P2FluxBatchVaults'), { token, feeWallet }),
  }],
  ['manifests/base-mainnet-gas-refill.manifest', ((): Record<string, string> => {
    const m: Record<string, string> = {
      ...head, RELAYER: main.RELAYER, GAS_TREASURY: main.GAS_TREASURY, USDC: main.USDC,
      ...BASE_MAINNET_THIRD_PARTY, POOL_FEE: '500',
      // Below 0.01 ETH the relayer is topped up to a target the API asks for (at most 0.05 ETH), with at
      // most 100 USDC a day, at least the Chainlink price less 3 %, from a price at most 1 hour old.
      // The treasury raises the cap and the ceiling later with setLimits, as traffic grows.
      REFILL_BELOW_WEI: '10000000000000000', MAX_ORACLE_AGE_SECONDS: '3600', DAILY_CAP_USDC_UNITS: '100000000', MAX_TARGET_WEI: '50000000000000000', MAX_SLIPPAGE_BPS: '300',
      GAS_REFILL_EXPECTED_ADDRESS: getContractAddress({ from: addr(main.DEPLOYER), nonce: nonce + 2n }),
    }
    m.GAS_REFILL_INITCODE_KECCAK = refillInitcodeKeccak(artifact('P2FluxGasRefill'), refillArgs(m as never))
    return m
  })()],
]
console.log(`deployer ${main.DEPLOYER} nonce ${nonce}`)
for (const [path, values] of files) {
  const body = Object.entries(values).map(([k, v]) => `${k}=${v}`).join('\n') + '\n'
  writeFileSync(path, body)
  const sha = createHash('sha256').update(body).digest('hex')
  // Round trip through the loader the deploy script uses: a file it would refuse is not written quietly.
  if (path.includes('x402')) loadX402Manifest(path, MAIN, sha)
  else if (path.includes('batch')) loadBatchManifest(path, MAIN, sha)
  else loadRefillManifest(path, MAIN, sha)
  console.log(`${path}\n  sha256 ${sha}\n  address ${values.X402_SPLITTER_EXPECTED_ADDRESS ?? values.BATCH_VAULTS_EXPECTED_ADDRESS ?? values.GAS_REFILL_EXPECTED_ADDRESS}`)
}
