/**
 * Deploy P2FluxRecurring.
 *
 * Deliberately dumb and explicit: it prints every constructor argument, asks the chain what it is
 * about to deploy to, and refuses to run against a chain it was not told to expect. A recurring
 * deployment's address is embedded in every customer signature and allowance, so deploying to the
 * wrong place or with the wrong immutables is not something to discover later.
 *
 *   CHAIN_ID=84532 npx tsx scripts/deploy.ts        # Base Sepolia
 *   CHAIN_ID=8453  npx tsx scripts/deploy.ts        # Base Mainnet - real money, no second chance
 *
 * The DEPLOYER signs; the ADMIN merely becomes an immutable address inside the contract. They are
 * deliberately separate inputs: the admin's one power is rotating the relayer, which is exactly the
 * profile of a cold key - and a cold key must never have to sign a deployment from a workstation.
 * So DEPLOYER_PK is a funded throwaway, and ADMIN_ADDRESS is just an address, checked and echoed
 * but never a secret here. (ADMIN_PK is still accepted as the deployer for the old single-key
 * Sepolia workflow.)
 *
 * Reads DEPLOYER_PK (or ADMIN_PK), ADMIN_ADDRESS, RELAYER_PK (address only), FEE_WALLET,
 * GAS_TREASURY and the token from the environment. Prints no keys.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { base, baseSepolia } from 'viem/chains'
/* Read the env file directly rather than adding a dependency: this repo is the canonical protocol
 * source and stays free of tooling it does not need to compile or test contracts. */
for (const line of readFileSync(process.env.ENV_FILE || '../p2flux_payment/.env', 'utf8').split('\n')) {
  const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
  if (match && !process.env[match[1]!]) process.env[match[1]!] = match[2]!.replace(/^["']|["']$/g, '')
}

const need = (name: string): string => {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

const artifact = JSON.parse(readFileSync(new URL('../out/P2FluxRecurring.json', import.meta.url), 'utf8')) as {
  abi: unknown[]
  bytecode: Hex
}

/* The chain is an explicit choice from a closed set - never inferred from the RPC, which is the
 * thing being verified. Anything else is refused by name. */
const expectedChain = Number(process.env.CHAIN_ID || 84532)
const viemChain = { [baseSepolia.id]: baseSepolia, [base.id]: base }[expectedChain]
if (!viemChain) throw new Error(`CHAIN_ID must be ${baseSepolia.id} (Base Sepolia) or ${base.id} (Base Mainnet)`)

const rpc = process.env.RPC_URL || (expectedChain === base.id ? 'https://mainnet.base.org' : 'https://sepolia.base.org')
const chain = createPublicClient({ chain: viemChain, transport: http(rpc) })

const onChainId = await chain.getChainId()
if (onChainId !== expectedChain) throw new Error(`RPC is chain ${onChainId}, expected ${expectedChain}`)

/* DEPLOYER_PK signs. ADMIN_ADDRESS becomes the immutable admin. The old ADMIN_PK path still works
 * for Sepolia rehearsals, but on Mainnet the two must be different things: the admin is cold. */
const deployerKey = process.env.DEPLOYER_PK || process.env.ADMIN_PK
if (!deployerKey) throw new Error('DEPLOYER_PK (or ADMIN_PK) is required')
const deployer = privateKeyToAccount(deployerKey as Hex)
const adminAddress = (process.env.ADMIN_ADDRESS || deployer.address) as Address
if (!/^0x[0-9a-fA-F]{40}$/.test(adminAddress)) throw new Error('ADMIN_ADDRESS is not an address')
if (/^0x0{40}$/.test(adminAddress)) throw new Error('ADMIN_ADDRESS is the zero address')
if (expectedChain === base.id && adminAddress.toLowerCase() === deployer.address.toLowerCase()) {
  /* On Mainnet the admin is immutable forever and its key belongs in cold storage. A deployment
   * where the deployer IS the admin means a hot workstation key holds that role for the life of
   * the contract - refuse it rather than let convenience decide something permanent. */
  throw new Error('On Base Mainnet, ADMIN_ADDRESS must differ from the deployer (cold admin, hot deployer)')
}
const relayer = privateKeyToAccount(need('RELAYER_PK') as Hex).address
const feeWallet = need('FEE_WALLET') as Address
const gasTreasury = need('GAS_TREASURY') as Address
const token = (process.env.USDC_ADDRESS ||
  (expectedChain === base.id
    ? '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
    : '0x036CbD53842c5426634e7929541eC2318f3dCF7e')) as Address

const balance = await chain.getBalance({ address: deployer.address })
console.log('chain       ', onChainId)
console.log('deployer    ', deployer.address, formatEther(balance), 'ETH')
console.log('admin       ', adminAddress)
console.log('relayer     ', relayer)
console.log('feeWallet   ', feeWallet)
console.log('gasTreasury ', gasTreasury)
console.log('token       ', token)

if (balance === 0n) throw new Error('deployer has no ETH on this chain')

const wallet = createWalletClient({ account: deployer, chain: viemChain, transport: http(rpc) })
const hash = await wallet.deployContract({
  abi: artifact.abi as never,
  bytecode: artifact.bytecode,
  args: [adminAddress, relayer, feeWallet, gasTreasury, token],
})
console.log('tx          ', hash)

const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('deployment failed')

console.log('')
console.log('RECURRING_ADDRESS=' + receipt.contractAddress)
console.log('deploy block', receipt.blockNumber.toString())
console.log('gas used    ', receipt.gasUsed.toString())
