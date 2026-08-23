/**
 * Deploy P2FluxSplitter.
 *
 * The splitter is the simpler deployment - two constructor arguments, no admin, no relayer, no
 * privileged role of any kind - but the two it has are immutable forever: the supported token and
 * the fee wallet. A typo in the fee wallet is a contract that pays somebody else 1% of every
 * payment for the rest of its life, so this prints everything, verifies the chain it is talking
 * to, and refuses a token address that holds no code (mirroring the constructor's own check, but
 * failing here costs nothing).
 *
 *   CHAIN_ID=84532 npx tsx scripts/deploy-splitter.ts        # Base Sepolia
 *   CHAIN_ID=8453  npx tsx scripts/deploy-splitter.ts        # Base Mainnet - real money
 *
 * Signs with DEPLOYER_PK (or ADMIN_PK for the old Sepolia workflow - the splitter grants the
 * deployer no lasting power either way). Reads FEE_WALLET and the token from the environment.
 * Prints no keys.
 *
 * The deploy block in the output is not decoration: payment recovery searches the splitter's whole
 * history from that block, so it goes into SPLITTER_DEPLOY_BLOCKS in the API's config.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { base, baseSepolia } from 'viem/chains'
import { getContractAddress } from 'viem'
import { addr, loadManifest } from './manifest.js'

/* Mainnet deploys from an approved manifest and from NOTHING else - see deploy.ts and manifest.ts. */
const manifest = process.env.DEPLOY_MANIFEST ? loadManifest() : null

for (const line of readFileSync(process.env.ENV_FILE || '../p2flux_payment/.env', 'utf8').split('\n')) {
  const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
  if (match && !process.env[match[1]!]) process.env[match[1]!] = match[2]!.replace(/^["']|["']$/g, '')
}

const need = (name: string): string => {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

const artifact = JSON.parse(readFileSync(new URL('../out/P2FluxSplitter.json', import.meta.url), 'utf8')) as {
  abi: unknown[]
  bytecode: Hex
}

const expectedChain = Number(process.env.CHAIN_ID || 84532)
const viemChain = { [baseSepolia.id]: baseSepolia, [base.id]: base }[expectedChain]
if (!viemChain) throw new Error(`CHAIN_ID must be ${baseSepolia.id} (Base Sepolia) or ${base.id} (Base Mainnet)`)

const rpc = process.env.RPC_URL || (expectedChain === base.id ? 'https://mainnet.base.org' : 'https://sepolia.base.org')
const chain = createPublicClient({ chain: viemChain, transport: http(rpc) })

const onChainId = await chain.getChainId()
if (onChainId !== expectedChain) throw new Error(`RPC is chain ${onChainId}, expected ${expectedChain}`)

const deployerKey = process.env.DEPLOYER_PK || process.env.ADMIN_PK
if (!deployerKey) throw new Error('DEPLOYER_PK (or ADMIN_PK) is required')
const deployer = privateKeyToAccount(deployerKey as Hex)
if (expectedChain === base.id && !manifest) throw new Error('Base Mainnet requires DEPLOY_MANIFEST - no env-file deployments to Mainnet')

const feeWallet: Address = manifest ? addr(manifest.SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET) : (need('FEE_WALLET') as Address)
const token: Address = manifest
  ? addr(manifest.SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN)
  : ((process.env.USDC_ADDRESS ||
      (expectedChain === base.id
        ? '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
        : '0x036CbD53842c5426634e7929541eC2318f3dCF7e')) as Address)

if (manifest) {
  if (manifest.CHAIN_ID !== String(expectedChain)) throw new Error(`manifest is for chain ${manifest.CHAIN_ID}, CHAIN_ID is ${expectedChain}`)
  if (deployer.address.toLowerCase() !== manifest.DEPLOYER.toLowerCase()) throw new Error('DEPLOYER_PK does not derive to the manifest DEPLOYER')
  const nonce = await chain.getTransactionCount({ address: deployer.address })
  const willCreate = getContractAddress({ from: deployer.address, nonce: BigInt(nonce) })
  if (willCreate.toLowerCase() !== manifest.SPLITTER_EXPECTED_ADDRESS.toLowerCase()) {
    throw new Error(`this deployment would create ${willCreate} (deployer nonce ${nonce}), manifest expects ${manifest.SPLITTER_EXPECTED_ADDRESS}`)
  }
  console.log('manifest    ', manifest.path)
  console.log('manifest sha256', manifest.sha256)
  console.log('will create ', willCreate, `(nonce ${nonce})`)
}

/* The constructor refuses a codeless token too, but a revert costs deployment gas and this check
 * costs one read. It also catches the classic cross-chain mistake - a Sepolia USDC address on
 * Mainnet holds nothing. */
const code = await chain.getCode({ address: token })
if (!code || code === '0x') throw new Error(`token ${token} holds no contract code on chain ${onChainId}`)

const balance = await chain.getBalance({ address: deployer.address })
console.log('chain       ', onChainId)
console.log('deployer    ', deployer.address, formatEther(balance), 'ETH')
console.log('feeWallet   ', feeWallet)
console.log('token       ', token)

if (balance === 0n) throw new Error('deployer has no ETH on this chain')

const wallet = createWalletClient({ account: deployer, chain: viemChain, transport: http(rpc) })
const hash = await wallet.deployContract({
  abi: artifact.abi as never,
  bytecode: artifact.bytecode,
  // Reversed relative to the recurring constructor, deliberately checked here: token FIRST.
  args: [token, feeWallet],
})
console.log('tx          ', hash)

const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('deployment failed')

console.log('')
console.log('SPLITTER_ADDRESS=' + receipt.contractAddress)
console.log('SPLITTER_DEPLOY_BLOCK=' + receipt.blockNumber.toString())
console.log('gas used    ', receipt.gasUsed.toString())
