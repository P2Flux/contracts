import { createPublicClient, http, formatEther, formatUnits, getAddress, type Address } from 'viem'
import { baseSepolia } from 'viem/chains'
import { erc20Abi } from '../src/abi.js'

const chain = createPublicClient({ chain: baseSepolia, transport: http('https://sepolia.base.org') })
const USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e' as Address
const RECURRING = '0x394c3fe285168f333ebf29e8f3585039328f2a73' as Address
const SPONSORED_SPLITTER = '0xe5dd4bdfbfdf1b8e40c7b6abffcb6712b12d02b3' as Address
const GAS_SPONSOR = '0x2dc51643040d7c396f1199a0664ac095d4b89ec5' as Address

const P = {
  buyer: getAddress('0x04b74CCD0FE75521A8039f74cA6a062dDb73eFf0'),
  merchant: getAddress('0xb4e43f3fba5add75395adad366627e7d74141fa9'),
  feeWallet: getAddress('0x1A8BFc5a38C264425dc373c635aD0b30B3550deF'),
  gasTreasury: getAddress('0xeC58ad20A0a85EE7a6C80263C43f64551Afc974f'),
  relayer: getAddress('0xC6bec1306F4FA2a81e41945f739829DAfD5908EC'),
}

const usdcOf = (a: Address) =>
  chain.readContract({ address: USDC, abi: erc20Abi, functionName: 'balanceOf', args: [a] }) as Promise<bigint>

const head = await chain.getBlockNumber()
const [bEth, bUsdc, bNonce, mUsdc, fUsdc, gUsdc, rEth, allowance, splitterResid, sponsorResid] = await Promise.all([
  chain.getBalance({ address: P.buyer }),
  usdcOf(P.buyer),
  chain.getTransactionCount({ address: P.buyer }),
  usdcOf(P.merchant),
  usdcOf(P.feeWallet),
  usdcOf(P.gasTreasury),
  chain.getBalance({ address: P.relayer }),
  chain.readContract({ address: USDC, abi: erc20Abi, functionName: 'allowance', args: [P.buyer, RECURRING] }) as Promise<bigint>,
  usdcOf(SPONSORED_SPLITTER),
  usdcOf(GAS_SPONSOR),
])

const u = (v: bigint) => formatUnits(v, 6).padStart(14)
console.log(`--- snapshot @ block ${head}  ${new Date().toISOString()}`)
console.log(`buyer ETH          ${formatEther(bEth)}   (wei ${bEth})`)
console.log(`buyer nonce        ${bNonce}`)
console.log(`buyer USDC        ${u(bUsdc)}`)
console.log(`merchant USDC     ${u(mUsdc)}`)
console.log(`feeWallet USDC    ${u(fUsdc)}`)
console.log(`gasTreasury USDC  ${u(gUsdc)}`)
console.log(`relayer ETH        ${formatEther(rEth)}   (wei ${rEth})`)
console.log(`buyer→recurring allowance  ${allowance === (1n << 256n) - 1n ? 'UNLIMITED (2^256-1)' : formatUnits(allowance, 6) + ' USDC'}`)
console.log(`residual: sponsoredSplitter ${u(splitterResid)}   gasSponsor ${u(sponsorResid)}`)
