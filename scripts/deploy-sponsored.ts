/**
 * Deploy P2FluxSponsoredSplitter and P2FluxGasSponsor - the two contracts that let a customer
 * holding no native currency pay, subscribe, or repair an allowance by signing.
 *
 * Both are additive: nothing already deployed changes, and a deployment that stops here leaves the
 * existing splitter and recurring contracts exactly as they were. Both are also relayer-only, which
 * is the argument to get right - a wrong relayer is a pair of contracts nothing can ever call, and
 * there is no setter to fix it with.
 *
 *   CHAIN_ID=84532 npx tsx scripts/deploy-sponsored.ts        # Base Sepolia
 *   CHAIN_ID=8453  npx tsx scripts/deploy-sponsored.ts        # Base Mainnet - real money
 *
 * Signs with DEPLOYER_PK (or ADMIN_PK for the old Sepolia workflow); neither contract grants the
 * deployer any lasting power. Reads FEE_WALLET, GAS_TREASURY, RELAYER_PK (address only) and the
 * token from the environment. Prints no keys.
 *
 * The deploy block in the output is not decoration: recovering a sponsored payment searches that
 * contract's history from it, so it goes into SPONSORED_SPLITTER_DEPLOY_BLOCK in the API's config.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, formatUnits, http, type Address, type Hex } from 'viem'
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

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../out/${name}.json`, import.meta.url), 'utf8')) as {
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

/* Mainnet is refused here rather than merely gated on a manifest.
 *
 * A Mainnet deployment of these two must name them in the approved manifest - expected addresses
 * and every constructor argument - the way the recurring contract and the splitter are named, and
 * the manifest has no such fields yet. Until it does there is no approved artefact to check a
 * Mainnet deployment against, and a deployment nobody can check is exactly what the manifest exists
 * to prevent. The capability table refuses the mode on Mainnet for the same reason. */
if (expectedChain === base.id) {
  throw new Error('Base Mainnet is not supported yet: add the sponsored contracts to the deploy manifest first')
}

const feeWallet: Address = manifest ? addr(manifest.SPLITTER_CONSTRUCTOR_ARG_2_FEE_WALLET) : (need('FEE_WALLET') as Address)
const gasTreasury: Address = manifest
  ? addr(manifest.RECURRING_CONSTRUCTOR_ARG_4_GAS_TREASURY)
  : (need('GAS_TREASURY') as Address)
const token: Address = manifest
  ? addr(manifest.SPLITTER_CONSTRUCTOR_ARG_1_SUPPORTED_TOKEN)
  : ((process.env.USDC_ADDRESS ||
      (expectedChain === base.id
        ? '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
        : '0x036CbD53842c5426634e7929541eC2318f3dCF7e')) as Address)

/* The relayer is the only address either contract will ever accept a call from, and there is no
 * setter. With a manifest, the approved RELAYER line is the authority and the relayer's key is not
 * wanted on the deploy machine at all; if RELAYER_PK is present anyway it is checked against the
 * manifest, never allowed to define the address. Without a manifest (testnet), the key that the API
 * actually signs with is the source, because a relayer address that does not match the running
 * relayer is a pair of dead contracts. */
const relayer: Address = (() => {
  if (!manifest) return privateKeyToAccount(need('RELAYER_PK') as Hex).address
  const expected = addr(manifest.RELAYER)
  if (addr(manifest.RECURRING_CONSTRUCTOR_ARG_2_RELAYER).toLowerCase() !== expected.toLowerCase()) {
    throw new Error('manifest RELAYER and RECURRING_CONSTRUCTOR_ARG_2_RELAYER disagree')
  }
  if (process.env.RELAYER_PK && privateKeyToAccount(process.env.RELAYER_PK as Hex).address.toLowerCase() !== expected.toLowerCase()) {
    throw new Error('RELAYER_PK does not derive to the manifest RELAYER')
  }
  return expected
})()

/* The two immutable ceilings. They bound what any single signature can ever move on top of what it
 * is paying for, and no configuration can raise them afterwards - which is the point of putting
 * them in the contracts rather than in the API's own table. 0.25 USDC at 6 decimals; the API's
 * SPONSOR_HARD_CAP must agree, and its startup check reads these back to prove it does. */
const HARD_CAP = BigInt(process.env.SPONSOR_HARD_CAP_UNITS || '250000')
/* The fixed network fee on a ONE-TIME payment, 0.10 USDC. MERCHANT-funded, out of the amount, and
 * paid to the gas treasury - the same quantity and destination as the recurring contract's
 * NETWORK_FEE. It is never added to what the buyer is debited. Subscriptions carry their own. */
const FIXED_NETWORK_FEE = BigInt(process.env.FIXED_NETWORK_FEE_UNITS || '100000')

if (manifest) {
  if (manifest.CHAIN_ID !== String(expectedChain)) throw new Error(`manifest is for chain ${manifest.CHAIN_ID}, CHAIN_ID is ${expectedChain}`)
  if (deployer.address.toLowerCase() !== manifest.DEPLOYER.toLowerCase()) throw new Error('DEPLOYER_PK does not derive to the manifest DEPLOYER')
}

/* Both constructors refuse a codeless token, but a revert costs deployment gas and this costs one
 * read - and it catches the classic cross-chain mistake, a Sepolia USDC address on Mainnet. */
const code = await chain.getCode({ address: token })
if (!code || code === '0x') throw new Error(`token ${token} holds no contract code on chain ${onChainId}`)

const balance = await chain.getBalance({ address: deployer.address })
console.log('chain       ', onChainId)
console.log('deployer    ', deployer.address, formatEther(balance), 'ETH')
console.log('token       ', token)
console.log('feeWallet   ', feeWallet)
console.log('gasTreasury ', gasTreasury)
console.log('relayer     ', relayer, manifest ? '(from manifest)' : '(from RELAYER_PK)')
console.log('hard cap    ', formatUnits(HARD_CAP, 6), 'USDC per sponsored operation')
console.log('fixed fee   ', formatUnits(FIXED_NETWORK_FEE, 6), 'USDC, merchant-funded, one-time only')

if (balance === 0n) throw new Error('deployer has no ETH on this chain')

const wallet = createWalletClient({ account: deployer, chain: viemChain, transport: http(rpc) })

const deploy = async (name: string, args: unknown[]) => {
  /* `pending`, not the default `latest`.
   *
   * The second deployment of a pair is predicted while the first is a block old at most, and a node
   * answering from the latest block hands back the nonce the first one already used - so the line
   * below announced an address that was never going to be created. Harmless as logging and useless
   * as a check, which is worse than either: an operator comparing this line against the receipt
   * would have found a mismatch and had no idea which number to believe. */
  const nonce = await chain.getTransactionCount({ address: deployer.address, blockTag: 'pending' })
  console.log('')
  console.log(name, 'will create', getContractAddress({ from: deployer.address, nonce: BigInt(nonce) }), `(nonce ${nonce})`)
  const built = artifact(name)
  const hash = await wallet.deployContract({ abi: built.abi as never, bytecode: built.bytecode, args })
  console.log('tx          ', hash)
  const receipt = await chain.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`${name} deployment failed`)
  console.log('gas used    ', receipt.gasUsed.toString())
  return receipt
}

/* Either, or both.
 *
 * The two are independent contracts that happen to be introduced together, and a correction to one
 * is not a reason to replace the other: a redeployed gas sponsor would strand every allowance
 * signature made against the old address for no benefit. `DEPLOY_ONLY=splitter` (or `sponsor`)
 * deploys the one named and leaves the other alone. */
const only = process.env.DEPLOY_ONLY
if (only && only !== 'splitter' && only !== 'sponsor') {
  throw new Error("DEPLOY_ONLY must be 'splitter' or 'sponsor' when set")
}
const splitter =
  only === 'sponsor'
    ? null
    : await deploy('P2FluxSponsoredSplitter', [token, feeWallet, gasTreasury, relayer, FIXED_NETWORK_FEE, HARD_CAP])
const sponsor = only === 'splitter' ? null : await deploy('P2FluxGasSponsor', [token, gasTreasury, relayer, HARD_CAP])

console.log('')
if (splitter) {
  console.log('SPONSORED_SPLITTER_ADDRESS=' + splitter.contractAddress)
  console.log('SPONSORED_SPLITTER_DEPLOY_BLOCK=' + splitter.blockNumber.toString())
}
if (sponsor) {
  console.log('GAS_SPONSOR_ADDRESS=' + sponsor.contractAddress)
/* Recovery does not search the sponsor - it settles allowances, not payments - but an operator
 * reconciling a sponsorship needs a floor to start from, and finding it later means a log scan. */
  console.log('GAS_SPONSOR_DEPLOY_BLOCK=' + sponsor.blockNumber.toString())
}
console.log('SPONSOR_HARD_CAP=' + formatUnits(HARD_CAP, 6))
