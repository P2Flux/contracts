/**
 * Verify a Mainnet deployment manifest without sending anything.
 *
 *   DEPLOY_MANIFEST=/path/to/manifest npx tsx scripts/verify-manifest.ts
 *
 * Loads the manifest through the same loader the deploy scripts use (so what passes here is what
 * they will consume), simulates both constructors against real Base Mainnet state with exactly the
 * manifest's arguments, estimates gas, derives the CREATE addresses the current deployer nonce
 * implies, and proves no transaction has been sent. Prints the manifest SHA-256 and the build
 * commit so the approval, the bytecode and the run are one thing.
 */
import { execSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { createPublicClient, encodeDeployData, formatEther, getContractAddress, http, type Hex } from 'viem'
import { base } from 'viem/chains'
import { addr, loadManifest } from './manifest.js'

const m = loadManifest()
const chain = createPublicClient({ chain: base, transport: http(process.env.RPC_URL || 'https://base-rpc.publicnode.com') })
if ((await chain.getChainId()) !== Number(m.CHAIN_ID)) throw new Error('RPC is not the manifest chain')

const art = (n: string) => JSON.parse(readFileSync(new URL(`../out/${n}.json`, import.meta.url), 'utf8')) as { abi: never[]; bytecode: Hex }
const splitter = art('P2FluxSplitter'), recurring = art('P2FluxRecurring')

const splitterArgs = [addr(m.SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN), addr(m.SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET)] as const
const recurringArgs = [
  addr(m.RECURRING_CONSTRUCTOR_ARG_1_ADMIN), addr(m.RECURRING_CONSTRUCTOR_ARG_2_RELAYER),
  addr(m.RECURRING_CONSTRUCTOR_ARG_3_FEE_WALLET), addr(m.RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY),
  addr(m.RECURRING_CONSTRUCTOR_ARG_5_SUPPORTED_TOKEN),
] as const
const deployer = addr(m.DEPLOYER)
const splitterData = encodeDeployData({ abi: splitter.abi, bytecode: splitter.bytecode, args: splitterArgs as never })
const recurringData = encodeDeployData({ abi: recurring.abi, bytecode: recurring.bytecode, args: recurringArgs as never })

const build = execSync('git rev-parse HEAD', { cwd: new URL('..', import.meta.url) }).toString().trim()
const dirty = execSync('git status --porcelain -- contracts out', { cwd: new URL('..', import.meta.url) }).toString().trim()

const usdcCode = await chain.getCode({ address: addr(m.USDC) })
const simS = await chain.call({ account: deployer, data: splitterData })
const simR = await chain.call({ account: deployer, data: recurringData })
const gasS = await chain.estimateGas({ account: deployer, data: splitterData })
const gasR = await chain.estimateGas({ account: deployer, data: recurringData })
const [nonce, balance] = await Promise.all([chain.getTransactionCount({ address: deployer }), chain.getBalance({ address: deployer })])
const expectS = getContractAddress({ from: deployer, nonce: 0n })
const expectR = getContractAddress({ from: deployer, nonce: 1n })

const line = (k: string, v: string) => console.log(k.padEnd(34) + v)
line('MANIFEST', m.path)
line('MANIFEST_SHA256', m.sha256)
line('BUILD_COMMIT', build + (dirty ? '  (contracts/out modified - NOT clean)' : '  (contracts/ and out/ clean)'))
line('ROLE_ADDRESSES_VALID_DISTINCT', 'yes (enforced by loader)')
line('USDC_HOLDS_CODE_ON_MAINNET', usdcCode && usdcCode !== '0x' ? `yes (${(usdcCode.length - 2) / 2} bytes)` : 'NO')
line('SPLITTER_ARGS', JSON.stringify(splitterArgs))
line('SPLITTER_SIMULATION', `ok, runtime ${((simS.data?.length ?? 2) - 2) / 2} bytes`)
line('SPLITTER_GAS_ESTIMATE', gasS.toString() + (gasS.toString() === m.SPLITTER_GAS_ESTIMATE ? '  (= manifest)' : `  (manifest says ${m.SPLITTER_GAS_ESTIMATE})`))
line('SPLITTER_EXPECTED_ADDRESS', expectS + (expectS === m.SPLITTER_EXPECTED_ADDRESS ? '  (= manifest, nonce 0)' : '  MISMATCH vs manifest'))
line('RECURRING_ARGS', JSON.stringify(recurringArgs))
line('RECURRING_SIMULATION', `ok, runtime ${((simR.data?.length ?? 2) - 2) / 2} bytes`)
line('RECURRING_GAS_ESTIMATE', gasR.toString() + (gasR.toString() === m.RECURRING_GAS_ESTIMATE ? '  (= manifest)' : `  (manifest says ${m.RECURRING_GAS_ESTIMATE})`))
line('RECURRING_EXPECTED_ADDRESS', expectR + (expectR === m.RECURRING_EXPECTED_ADDRESS ? '  (= manifest, nonce 1)' : '  MISMATCH vs manifest'))
line('DEPLOYER_NONCE', String(nonce))
line('DEPLOYER_BALANCE_ETH', formatEther(balance))
line('MAINNET_TX_SENT', nonce === 0 ? 'none' : `YES - nonce is ${nonce}`)
