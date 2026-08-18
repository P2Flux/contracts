/**
 * Deploy P2FluxRecurring.
 *
 * Deliberately dumb and explicit: it prints every constructor argument, asks the chain what it is
 * about to deploy to, and refuses to run against a chain it was not told to expect. A recurring
 * deployment's address is embedded in every customer signature and allowance, so deploying to the
 * wrong place or with the wrong immutables is not something to discover later.
 *
 *   CHAIN_ID=84532 npx tsx scripts/deploy.ts
 *
 * Reads ADMIN_PK, RELAYER_PK (address only), FEE_WALLET, GAS_TREASURY and the token from the
 * environment. Prints no keys.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
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

const expectedChain = Number(process.env.CHAIN_ID || 84532)
if (expectedChain !== baseSepolia.id) throw new Error(`This script only targets Base Sepolia (${baseSepolia.id})`)

const rpc = process.env.RPC_URL || 'https://sepolia.base.org'
const chain = createPublicClient({ chain: baseSepolia, transport: http(rpc) })

const onChainId = await chain.getChainId()
if (onChainId !== expectedChain) throw new Error(`RPC is chain ${onChainId}, expected ${expectedChain}`)

const admin = privateKeyToAccount(need('ADMIN_PK') as Hex)
const relayer = privateKeyToAccount(need('RELAYER_PK') as Hex).address
const feeWallet = need('FEE_WALLET') as Address
const gasTreasury = need('GAS_TREASURY') as Address
const token = (process.env.USDC_ADDRESS || '0x036CbD53842c5426634e7929541eC2318f3dCF7e') as Address

const balance = await chain.getBalance({ address: admin.address })
console.log('chain       ', onChainId)
console.log('deployer    ', admin.address, formatEther(balance), 'ETH')
console.log('admin       ', admin.address)
console.log('relayer     ', relayer)
console.log('feeWallet   ', feeWallet)
console.log('gasTreasury ', gasTreasury)
console.log('token       ', token)

if (balance === 0n) throw new Error('deployer has no ETH on this chain')

const wallet = createWalletClient({ account: admin, chain: baseSepolia, transport: http(rpc) })
const hash = await wallet.deployContract({
  abi: artifact.abi as never,
  bytecode: artifact.bytecode,
  args: [admin.address, relayer, feeWallet, gasTreasury, token],
})
console.log('tx          ', hash)

const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error('deployment failed')

console.log('')
console.log('RECURRING_ADDRESS=' + receipt.contractAddress)
console.log('gas used    ', receipt.gasUsed.toString())
