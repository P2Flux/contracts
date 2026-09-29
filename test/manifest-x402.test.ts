/**
 * The x402 deployment manifest loader, attacked one field at a time. A fixture built on top of the
 * REAL approved Base Mainnet manifest (the x402 manifest must name its hash and agree with it), with
 * the initcode hash of the contract as compiled here. Nothing touches a network.
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { getContractAddress, type Hex } from 'viem'
import { loadManifest } from '../scripts/manifest.js'
import { loadX402Manifest, x402InitcodeKeccak } from '../scripts/x402-manifest.js'
import { X402_UPTO_PROXY } from '../src/x402.js'

const MAIN = new URL('../manifests/base-mainnet.manifest', import.meta.url).pathname
const main = loadManifest(MAIN)
const artifact = JSON.parse(readFileSync(new URL('../out/P2FluxX402Splitter.json', import.meta.url), 'utf8')) as {
  abi: unknown
  bytecode: Hex
}
const plan = { token: main.USDC, feeWallet: main.FEE_WALLET, relayer: main.RELAYER, uptoProxy: X402_UPTO_PROXY, minFee: 3000n } as never

const valid = (): Record<string, string> => ({
  NETWORK: 'Base Mainnet',
  CHAIN_ID: '8453',
  MAIN_MANIFEST_SHA256: main.sha256,
  DEPLOYER: main.DEPLOYER,
  RELAYER: main.RELAYER,
  FEE_WALLET: main.FEE_WALLET,
  USDC: main.USDC,
  X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN: main.USDC,
  X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET: main.FEE_WALLET,
  X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER: main.RELAYER,
  X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY: X402_UPTO_PROXY,
  X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC: '3000',
  X402_SPLITTER_FEE_BPS: '100',
  X402_SPLITTER_EXPECTED_ADDRESS: getContractAddress({ from: main.DEPLOYER as Hex, nonce: 4n }),
  X402_SPLITTER_INITCODE_KECCAK: x402InitcodeKeccak(artifact, plan),
})
const write = (v: Record<string, string>) => {
  const p = join(mkdtempSync(join(tmpdir(), 'x402-manifest-')), 'm')
  writeFileSync(p, Object.entries(v).map(([k, x]) => `${k}=${x}`).join('\n') + '\n')
  return p
}
const sha = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex')
const STRANGER = '0x000000000000000000000000000000000000dEaD'

test('a correct x402 manifest loads, and only under its approved hash', () => {
  const path = write(valid())
  const loaded = loadX402Manifest(path, MAIN, sha(path))
  assert.equal(loaded.relayer, main.RELAYER)
  assert.equal(loaded.feeWallet, main.FEE_WALLET)
  assert.equal(loaded.minFee, 3000n)
  assert.equal(loaded.uptoProxy, X402_UPTO_PROXY)
  assert.equal(loaded.initcodeKeccak, x402InitcodeKeccak(artifact, plan))
  assert.throws(() => loadX402Manifest(path, MAIN, 'ab'.repeat(32)), /the approved manifest is/)
})

test('every single-field corruption is refused', () => {
  const cases: [string, (m: Record<string, string>) => void, RegExp][] = [
    ['another relayer', (m) => { m.RELAYER = STRANGER; m.X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER = STRANGER }, /RELAYER .* differs from the main manifest/],
    ['relayer argument differs from the role', (m) => { m.X402_SPLITTER_CONSTRUCTOR_ARG_3_RELAYER = STRANGER }, /does not equal RELAYER/],
    ['another fee wallet', (m) => { m.FEE_WALLET = STRANGER; m.X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET = STRANGER }, /FEE_WALLET .* differs from the main manifest/],
    ['fee wallet argument differs from the role', (m) => { m.X402_SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET = STRANGER }, /does not equal FEE_WALLET/],
    ['Sepolia USDC', (m) => { m.USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'; m.X402_SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN = m.USDC }, /USDC .* differs from the main manifest/],
    ['another deployer', (m) => { m.DEPLOYER = STRANGER }, /DEPLOYER .* differs from the main manifest/],
    ['another upto proxy', (m) => { m.X402_SPLITTER_CONSTRUCTOR_ARG_4_UPTO_PROXY = STRANGER }, /not the canonical x402 upto proxy/],
    ['a minimum fee above 0.10 USDC', (m) => { m.X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC = '100001' }, /MIN_FEE must be/],
    ['a minimum fee that is not a number', (m) => { m.X402_SPLITTER_CONSTRUCTOR_ARG_5_MIN_FEE_MICRO_USDC = '0x3000' }, /MIN_FEE must be/],
    ['another fee rate', (m) => { m.X402_SPLITTER_FEE_BPS = '200' }, /FEE_BPS must be 100/],
    ['another chain', (m) => { m.CHAIN_ID = '84532' }, /Base Mainnet \(8453\) only/],
    ['another main manifest', (m) => { m.MAIN_MANIFEST_SHA256 = 'cd'.repeat(32) }, /MAIN_MANIFEST_SHA256 does not match/],
    ['a lowercase address', (m) => { m.X402_SPLITTER_EXPECTED_ADDRESS = m.X402_SPLITTER_EXPECTED_ADDRESS!.toLowerCase() }, /not a checksummed address/],
    ['the zero address', (m) => { m.X402_SPLITTER_EXPECTED_ADDRESS = `0x${'0'.repeat(40)}` }, /zero address|not a checksummed/],
    ['a malformed initcode hash', (m) => { m.X402_SPLITTER_INITCODE_KECCAK = '0x1234' }, /INITCODE_KECCAK must be/],
    ['a missing key', (m) => { delete m.X402_SPLITTER_INITCODE_KECCAK }, /missing key/],
    ['an unexpected key', (m) => { m.X402_SPLITTER_OWNER = STRANGER }, /unexpected key/],
  ]
  for (const [name, corrupt, expected] of cases) {
    const m = valid()
    corrupt(m)
    assert.throws(() => loadX402Manifest(write(m), MAIN), expected, name)
  }
})

test('a duplicate key is refused', () => {
  const path = write(valid())
  writeFileSync(path, `${readFileSync(path, 'utf8')}RELAYER=${STRANGER}\n`)
  assert.throws(() => loadX402Manifest(path, MAIN), /duplicate key/)
})

test('the pinned initcode hash changes with the bytecode and with every constructor argument', () => {
  const base = x402InitcodeKeccak(artifact, plan)
  assert.notEqual(x402InitcodeKeccak({ ...artifact, bytecode: `${artifact.bytecode}00` }, plan), base, 'bytecode')
  for (const over of [{ relayer: STRANGER }, { feeWallet: STRANGER }, { token: STRANGER }, { uptoProxy: STRANGER }, { minFee: 2000n }]) {
    assert.notEqual(x402InitcodeKeccak(artifact, { ...(plan as object), ...over } as never), base, JSON.stringify(Object.keys(over)))
  }
})
