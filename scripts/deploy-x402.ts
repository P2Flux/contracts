/**
 * Deploy P2FluxX402Splitter - x402 settlement for AI agents paying for APIs, content and tools.
 *
 * Additive: nothing already deployed changes. Relayer-only with no setter, so the relayer argument is
 * the one to get right - a wrong relayer is a contract nothing can ever call.
 *
 *   CHAIN_ID=84532 npx tsx scripts/deploy-x402.ts                                  # Base Sepolia
 *   CHAIN_ID=8453 X402_MANIFEST=manifests/base-mainnet-x402.manifest \
 *     DEPLOY_MANIFEST=manifests/base-mainnet.manifest npx tsx scripts/deploy-x402.ts # Base Mainnet
 *
 * Testnet reads FEE_WALLET, RELAYER_PK (address only), USDC_ADDRESS and X402_MIN_FEE_UNITS (default
 * 3000 = 0.003 USDC) from the environment; Mainnet deploys from the x402 manifest and nothing else.
 * Signs with DEPLOYER_PK (or ADMIN_PK). Prints no keys. DRY_RUN=1 checks everything and sends nothing.
 *
 * The deploy block printed at the end goes into X402_SPLITTER_DEPLOY_BLOCK in the API's config:
 * recovering an x402 payment searches the contract's history from it.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, formatUnits, getContractAddress, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { base, baseSepolia } from 'viem/chains'
import { X402_UPTO_PROXY } from '../src/x402.js'
import { assertImmutables, assertPredicted } from './sponsored-manifest.js'
import { loadManifest } from './manifest.js'
import { loadX402Manifest, x402InitcodeKeccak, type X402Plan } from './x402-manifest.js'

for (const line of readFileSync(process.env.ENV_FILE || '../p2flux_payment/.env', 'utf8').split('\n')) {
  const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
  if (match && !process.env[match[1]!]) process.env[match[1]!] = match[2]!.replace(/^["']|["']$/g, '')
}

const need = (name: string): string => {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../out/${name}.json`, import.meta.url), 'utf8')) as { abi: unknown[]; bytecode: Hex }

const expectedChain = Number(process.env.CHAIN_ID || 84532)
const viemChain = { [baseSepolia.id]: baseSepolia, [base.id]: base }[expectedChain]
if (!viemChain) throw new Error(`CHAIN_ID must be ${baseSepolia.id} (Base Sepolia) or ${base.id} (Base Mainnet)`)
const rpc = process.env.RPC_URL_DEPLOY || (expectedChain === base.id ? 'https://mainnet.base.org' : 'https://sepolia.base.org')
const chain = createPublicClient({ chain: viemChain, transport: http(rpc) })
const onChainId = await chain.getChainId()
if (onChainId !== expectedChain) throw new Error(`RPC is chain ${onChainId}, expected ${expectedChain}`)

const deployer = privateKeyToAccount((process.env.DEPLOYER_PK || need('ADMIN_PK')) as Hex)

let plan: X402Plan
if (expectedChain === base.id) {
  if (!process.env.X402_MANIFEST || !process.env.DEPLOY_MANIFEST || !process.env.X402_MANIFEST_SHA256) {
    throw new Error(
      'Base Mainnet deploys only from an approved manifest: set X402_MANIFEST, X402_MANIFEST_SHA256 (the approved hash) and DEPLOY_MANIFEST',
    )
  }
  plan = loadX402Manifest(process.env.X402_MANIFEST, process.env.DEPLOY_MANIFEST, process.env.X402_MANIFEST_SHA256)
  if (deployer.address !== loadManifest(process.env.DEPLOY_MANIFEST).DEPLOYER) {
    throw new Error('DEPLOYER_PK does not derive to the manifest DEPLOYER')
  }
  if (process.env.RELAYER_PK && privateKeyToAccount(process.env.RELAYER_PK as Hex).address !== plan.relayer) {
    throw new Error('RELAYER_PK does not derive to the manifest RELAYER')
  }
} else {
  plan = {
    token: (process.env.USDC_ADDRESS || '0x036CbD53842c5426634e7929541eC2318f3dCF7e') as Address,
    feeWallet: need('FEE_WALLET') as Address,
    // The key the API actually signs with: a relayer that does not match it is a dead contract.
    relayer: privateKeyToAccount(need('RELAYER_PK') as Hex).address,
    uptoProxy: X402_UPTO_PROXY,
    minFee: BigInt(process.env.X402_MIN_FEE_UNITS || '3000'),
    expected: null,
    initcodeKeccak: null,
    sha256: null,
  }
}

// The constructor refuses both, but a revert costs deploy gas and this costs two reads - and catches
// the classic cross-chain mistake (a Sepolia USDC address on Mainnet).
for (const [name, address] of [['token', plan.token], ['upto proxy', plan.uptoProxy]] as const) {
  const code = await chain.getCode({ address })
  if (!code || code === '0x') throw new Error(`${name} ${address} holds no contract code on chain ${onChainId}`)
}

const balance = await chain.getBalance({ address: deployer.address })
console.log('chain       ', onChainId)
console.log('deployer    ', deployer.address, formatEther(balance), 'ETH')
console.log('token       ', plan.token)
console.log('feeWallet   ', plan.feeWallet)
console.log('relayer     ', plan.relayer, plan.sha256 ? '(from manifest)' : '(from RELAYER_PK)')
console.log('upto proxy  ', plan.uptoProxy)
console.log('MIN_FEE     ', formatUnits(plan.minFee, 6), 'USDC (fee = max(1%, MIN_FEE))')
if (balance === 0n) throw new Error('deployer has no ETH on this chain')

const nonce = await chain.getTransactionCount({ address: deployer.address, blockTag: 'pending' })
const willCreate = plan.expected
  ? assertPredicted(plan.expected, deployer.address, nonce, 'P2FluxX402Splitter')
  : getContractAddress({ from: deployer.address, nonce: BigInt(nonce) })
console.log('')
console.log('P2FluxX402Splitter will be created at', willCreate, `(nonce ${nonce})`, plan.expected ? '- matches manifest' : '')
if (plan.sha256) console.log('x402 manifest sha256', plan.sha256)

/* The bytecode about to be signed, against the bytecode that was approved. `out/` is a build output
 * on a workstation: nothing else ties it to the reviewed source. */
const built = artifact('P2FluxX402Splitter')
const initcodeKeccak = x402InitcodeKeccak(built, plan)
console.log('initcode keccak', initcodeKeccak, plan.initcodeKeccak ? '' : '(testnet: not pinned)')
if (plan.initcodeKeccak && plan.initcodeKeccak !== initcodeKeccak) {
  throw new Error(`out/P2FluxX402Splitter.json builds ${initcodeKeccak}, the manifest approved ${plan.initcodeKeccak}: recompile from the approved commit`)
}

if (process.env.DRY_RUN === '1') {
  console.log('DRY_RUN: nothing sent')
  process.exit(0)
}

const wallet = createWalletClient({ account: deployer, chain: viemChain, transport: http(rpc) })
const hash = await wallet.deployContract({
  abi: built.abi as never,
  bytecode: built.bytecode,
  args: [plan.token, plan.feeWallet, plan.relayer, plan.uptoProxy, plan.minFee],
})
console.log('tx          ', hash)
const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('P2FluxX402Splitter deployment failed')
if (receipt.contractAddress.toLowerCase() !== willCreate.toLowerCase()) {
  throw new Error(`created at ${receipt.contractAddress}, expected ${willCreate}`)
}
console.log('gas used    ', receipt.gasUsed.toString())

// What the chain now holds, immutable by immutable, against the plan.
const address = receipt.contractAddress
const fields = {
  supportedToken: plan.token,
  feeWallet: plan.feeWallet,
  relayer: plan.relayer,
  uptoProxy: plan.uptoProxy,
  MIN_FEE: plan.minFee,
  FEE_BPS: 100n,
}
/* Public RPCs are load-balanced: the node answering the read can be a block behind the one that
 * mined the deployment and see no code yet (this happened on the first Sepolia deploy). Read at the
 * deployment's own block, and give a lagging node a few seconds to catch up. */
const readAtDeploy = async (functionName: string) => {
  for (let attempt = 1; ; attempt++) {
    try {
      return await chain.readContract({ address, abi: built.abi as never, functionName, blockNumber: receipt.blockNumber })
    } catch (err) {
      if (attempt >= 6) throw err
      await new Promise((resolve) => setTimeout(resolve, 2_000))
    }
  }
}
const read: Record<string, unknown> = {}
for (const fn of Object.keys(fields)) read[fn] = await readAtDeploy(fn)
assertImmutables('P2FluxX402Splitter', fields, read)
console.log('P2FluxX402Splitter immutables verified against the plan')

console.log('')
console.log('X402_SPLITTER_ADDRESS=' + address)
console.log('X402_SPLITTER_DEPLOY_BLOCK=' + receipt.blockNumber.toString())
