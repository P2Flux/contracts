/**
 * Deploy P2FluxBatchVaults - per-seller vaults for x402 batch settlement (97% seller, 3% P2Flux).
 *
 * Additive: nothing already deployed changes. No roles, no admin: the two constructor arguments are
 * everything, and both are immutable.
 *
 *   npx tsx scripts/deploy-batch-vaults.ts          # Base Sepolia only (FEE_WALLET, ADMIN_PK from the env file)
 *
 * Base Mainnet is refused until an approved manifest exists, as for every other contract.
 * DRY_RUN=1 checks everything and sends nothing. Prints no keys.
 */
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, getContractAddress, http, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { baseSepolia } from 'viem/chains'
import { batchVaultAddress, p2fluxBatchVaultsAbi } from '../src/x402.js'

for (const line of readFileSync(process.env.ENV_FILE || '../p2flux_payment/.env', 'utf8').split('\n')) {
  const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim())
  if (match && !process.env[match[1]!]) process.env[match[1]!] = match[2]!.replace(/^["']|["']$/g, '')
}
const need = (name: string): string => {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}
if (Number(process.env.CHAIN_ID || 84532) !== baseSepolia.id) throw new Error('Base Sepolia only: Mainnet needs an approved manifest')

const chain = createPublicClient({ chain: baseSepolia, transport: http(process.env.RPC_URL_DEPLOY || 'https://sepolia.base.org') })
if ((await chain.getChainId()) !== baseSepolia.id) throw new Error('RPC is not Base Sepolia')
const deployer = privateKeyToAccount((process.env.DEPLOYER_PK || need('ADMIN_PK')) as Hex)
const token = (process.env.USDC_ADDRESS || '0x036CbD53842c5426634e7929541eC2318f3dCF7e') as Address
const feeWallet = need('FEE_WALLET') as Address
if ((await chain.getCode({ address: token })) === undefined) throw new Error(`no contract at USDC ${token}`)

const { abi, bytecode } = JSON.parse(readFileSync(new URL('../out/P2FluxBatchVaults.json', import.meta.url), 'utf8')) as { abi: unknown[]; bytecode: Hex }
const nonce = await chain.getTransactionCount({ address: deployer.address, blockTag: 'pending' })
const predicted = getContractAddress({ from: deployer.address, nonce: BigInt(nonce) })
console.log(`deployer ${deployer.address} (${formatEther(await chain.getBalance({ address: deployer.address }))} ETH), nonce ${nonce}`)
console.log(`token ${token}\nfee wallet ${feeWallet}\npredicted address ${predicted}`)
if (process.env.DRY_RUN) process.exit(0)

const wallet = createWalletClient({ account: deployer, chain: baseSepolia, transport: http(process.env.RPC_URL_DEPLOY || 'https://sepolia.base.org') })
const hash = await wallet.deployContract({ abi, bytecode, args: [token, feeWallet] })
const receipt = await chain.waitForTransactionReceipt({ hash })
if (receipt.status !== 'success' || receipt.contractAddress?.toLowerCase() !== predicted.toLowerCase()) throw new Error(`deploy failed: ${hash}`)
const address = receipt.contractAddress as Address

// Read back at the deploy block: a lagging RPC node must not make a good deploy look bad.
const read = async <T>(functionName: string, args: unknown[] = []): Promise<T> => {
  for (let i = 0; ; i++) {
    try {
      return (await chain.readContract({ address, abi: p2fluxBatchVaultsAbi, functionName, args, blockNumber: receipt.blockNumber } as never)) as T
    } catch (err) {
      if (i >= 5) throw err
      await new Promise((r) => setTimeout(r, 2000))
    }
  }
}
const probe = '0x00000000000000000000000000000000000c0ffe' as Address
const checks: [string, boolean][] = [
  ['supportedToken', (await read<Address>('supportedToken')).toLowerCase() === token.toLowerCase()],
  ['feeWallet', (await read<Address>('feeWallet')).toLowerCase() === feeWallet.toLowerCase()],
  ['FEE_BPS 300', Number(await read<number>('FEE_BPS')) === 300],
  ['vaultOf matches batchVaultAddress', (await read<Address>('vaultOf', [probe])) === batchVaultAddress(address, probe)],
]
for (const [name, ok] of checks) console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`)
if (!checks.every(([, ok]) => ok)) process.exit(1)
console.log(`\nP2FluxBatchVaults ${address}\ndeploy block ${receipt.blockNumber}\ntx ${hash}`)
