/**
 * The batch vaults manifest loader, attacked one field at a time, on top of the REAL approved Base
 * Mainnet manifest. Nothing touches a network.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { getContractAddress, type Hex } from 'viem'
import { batchInitcodeKeccak, loadBatchManifest } from '../scripts/batch-manifest.js'
import { loadManifest } from '../scripts/manifest.js'

const MAIN = new URL('../manifests/base-mainnet.manifest', import.meta.url).pathname
const main = loadManifest(MAIN)
const artifact = JSON.parse(readFileSync(new URL('../out/P2FluxBatchVaults.json', import.meta.url), 'utf8')) as { abi: unknown; bytecode: Hex }
const keccak = batchInitcodeKeccak(artifact, { token: main.USDC as Hex, feeWallet: main.FEE_WALLET as Hex })

const valid = (): Record<string, string> => ({
  NETWORK: 'Base Mainnet',
  CHAIN_ID: '8453',
  MAIN_MANIFEST_SHA256: main.sha256,
  DEPLOYER: main.DEPLOYER,
  FEE_WALLET: main.FEE_WALLET,
  USDC: main.USDC,
  BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: main.USDC,
  BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET: main.FEE_WALLET,
  BATCH_VAULTS_FEE_BPS: '300',
  BATCH_VAULTS_EXPECTED_ADDRESS: getContractAddress({ from: main.DEPLOYER as Hex, nonce: 5n }),
  BATCH_VAULTS_INITCODE_KECCAK: keccak,
})
const write = (v: Record<string, string>) => {
  const p = join(mkdtempSync(join(tmpdir(), 'batch-manifest-')), 'm')
  writeFileSync(p, Object.entries(v).map(([k, x]) => `${k}=${x}`).join('\n') + '\n')
  return p
}
const sha = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex')
const STRANGER = '0x000000000000000000000000000000000000dEaD'

test('a correct batch manifest loads, and only under its approved hash', () => {
  const path = write(valid())
  const loaded = loadBatchManifest(path, MAIN, sha(path))
  assert.equal(loaded.feeWallet, main.FEE_WALLET)
  assert.equal(loaded.token, main.USDC)
  assert.equal(loaded.initcodeKeccak, keccak)
  assert.throws(() => loadBatchManifest(path, MAIN, 'ab'.repeat(32)), /the approved manifest is/)
})

const refused: [string, (v: Record<string, string>) => void, RegExp][] = [
  ['a fee wallet that is not the approved one', (v) => { v.FEE_WALLET = STRANGER; v.BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET = STRANGER }, /differs from the main manifest/],
  ['a constructor fee wallet that differs from FEE_WALLET', (v) => { v.BATCH_VAULTS_CONSTRUCTOR_ARG_2_FEE_WALLET = STRANGER }, /ARG_2/],
  ['a constructor token that differs from USDC', (v) => { v.BATCH_VAULTS_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN = STRANGER }, /ARG_1/],
  ['another fee rate', (v) => { v.BATCH_VAULTS_FEE_BPS = '500' }, /must be 300/],
  ['another chain', (v) => { v.CHAIN_ID = '84532' }, /Base Mainnet/],
  ['a lowercase address', (v) => { v.DEPLOYER = v.DEPLOYER!.toLowerCase() }, /checksummed/],
  ['the zero address', (v) => { v.BATCH_VAULTS_EXPECTED_ADDRESS = '0x' + '0'.repeat(40) }, /zero address/],
  ['a stale main manifest hash', (v) => { v.MAIN_MANIFEST_SHA256 = 'cd'.repeat(32) }, /MAIN_MANIFEST_SHA256/],
  ['an unpinned bytecode', (v) => { v.BATCH_VAULTS_INITCODE_KECCAK = '0x1234' }, /INITCODE_KECCAK/],
  ['a missing key', (v) => { delete v.BATCH_VAULTS_FEE_BPS }, /missing key/],
  ['an extra key', (v) => { v.OWNER = STRANGER }, /unexpected key/],
]
for (const [name, mutate, message] of refused) {
  test(`refused: ${name}`, () => {
    const v = valid()
    mutate(v)
    assert.throws(() => loadBatchManifest(write(v), MAIN), message)
  })
}

test('the manifests in the repository load against the contracts as compiled here', () => {
  const path = new URL('../manifests/base-mainnet-batch.manifest', import.meta.url).pathname
  assert.equal(loadBatchManifest(path, MAIN).initcodeKeccak, keccak)
})
