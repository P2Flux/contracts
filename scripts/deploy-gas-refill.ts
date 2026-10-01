/**
 * Deploy P2FluxGasRefill on Base Sepolia - the automatic relayer top-up from the gas treasury's USDC.
 *
 *   npx tsx scripts/deploy-gas-refill.ts      # Base Sepolia only (ADMIN_PK deploys; env file as the others)
 *
 * Test parameters: the treasury is the test admin wallet (it approves the contract itself afterwards),
 * the relayer is the api-test relayer, 1 USDC per refill, at most 3 a day, 3 % price allowance against
 * Chainlink, price at most 3 h old, Uniswap v3 USDC/WETH 0.3 % pool (the deepest on Sepolia).
 * GAS_REFILL_BELOW_WEI sets the threshold (default 0.003 ETH). Base Mainnet: a manifest, like every
 * other contract - not this script. DRY_RUN=1 checks and sends nothing. Prints no keys.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, getContractAddress, http, parseEther, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'

for (const line of readFileSync(process.env.ENV_FILE || '../p2flux_payment/.env', 'utf8').split('\n')) {
  const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
  if (match && !process.env[match[1]!]) process.env[match[1]!] = match[2]!.replace(/^["']|["']$/g, '')
}
const need = (name: string): string => {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}
if (Number(process.env.CHAIN_ID || 84532) !== baseSepolia.id) throw new Error('this script deploys on Base Sepolia only; Base Mainnet goes through an approved manifest')

const SEPOLIA = {
  usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
  weth: '0x4200000000000000000000000000000000000006',
  router: '0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4',
  feed: '0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1',
  poolFee: 3000,
} as const

const chain = createPublicClient({ chain: baseSepolia, transport: http(process.env.RPC_URL_DEPLOY || 'https://sepolia.base.org') })
const deployer = privateKeyToAccount(need('ADMIN_PK') as Hex)
const treasury = (process.env.GAS_REFILL_TREASURY || deployer.address) as Address
const relayer = privateKeyToAccount(need('RELAYER_PK') as Hex).address
const below = BigInt(process.env.GAS_REFILL_BELOW_WEI || parseEther('0.003').toString())
const args = [SEPOLIA.usdc, SEPOLIA.weth, treasury, relayer, SEPOLIA.router, SEPOLIA.poolFee, SEPOLIA.feed, 1_000_000n, below, 3n, 300n, 3n * 3600n] as const

for (const [name, address] of [['USDC', SEPOLIA.usdc], ['WETH', SEPOLIA.weth], ['router', SEPOLIA.router], ['feed', SEPOLIA.feed]] as const) {
  const code = await chain.getCode({ address })
  if (!code || code === '0x') throw new Error(`no contract at ${name} ${address}`)
}
const { abi, bytecode } = JSON.parse(readFileSync(new URL('../out/P2FluxGasRefill.json', import.meta.url), 'utf8')) as { abi: unknown[]; bytecode: Hex }
const nonce = await chain.getTransactionCount({ address: deployer.address })
const predicted = getContractAddress({ from: deployer.address, nonce: BigInt(nonce) })
console.log(`deployer  ${deployer.address} (${formatEther(await chain.getBalance({ address: deployer.address }))} ETH)`)
console.log(`treasury  ${treasury}\nrelayer   ${relayer}\nthreshold ${formatEther(below)} ETH\npredicted ${predicted}`)
if (process.env.DRY_RUN) process.exit(0)

const wallet = createWalletClient({ account: deployer, chain: baseSepolia, transport: http(process.env.RPC_URL_DEPLOY || 'https://sepolia.base.org') })
const hash = await wallet.deployContract({ abi, bytecode, args: args as never })
const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || receipt.contractAddress?.toLowerCase() !== predicted.toLowerCase()) throw new Error(`deploy failed: ${hash}`)
console.log(`P2FluxGasRefill ${receipt.contractAddress}\nblock ${receipt.blockNumber}\ntx ${hash}`)
