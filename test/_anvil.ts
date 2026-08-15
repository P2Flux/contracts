/**
 * Local-chain harness for the P2FluxRecurring security suite: boots anvil, deploys the contract and
 * a mock token, and hands tests typed helpers. Time travel via evm_increaseTime.
 */
import { readFileSync } from 'node:fs'
import { spawn, type ChildProcess } from 'node:child_process'
import { homedir } from 'node:os'
import {
  createPublicClient,
  createWalletClient,
  http,
  maxUint256,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import {
  abiAuth,
  recurringAbi,
  recurringTypedData,
  type RecurringAuthorization,
} from '../../packages/base/src/recurring.js'

const ANVIL = `${homedir()}/.foundry/bin/anvil`

/* One anvil per harness, on its own port. `node --test` runs test files in PARALLEL PROCESSES, so a
 * fixed port means the second suite to start either attaches to the first one's chain or fails to
 * bind and takes the suite down with it - which is exactly what happened when the splitter tests
 * were added alongside the recurring ones. A module-level counter is not enough for the same reason:
 * each file gets its own module instance. The pid separates the processes, the counter separates
 * multiple harnesses within one. */
let nextPort = 8600 + (process.pid % 400) * 4

// anvil's deterministic accounts
export const KEYS = {
  admin: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  relayer: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  payer: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
  seller: '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
  attacker: '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a',
  feeWallet: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba',
  gasTreasury: '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e',
} as const

export type Harness = Awaited<ReturnType<typeof startHarness>>

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../../out/${name}.json`, import.meta.url), 'utf8')) as {
    abi: Abi
    bytecode: Hex
  }

export async function startHarness() {
  const port = nextPort++
  const RPC = `http://127.0.0.1:${port}`
  const proc: ChildProcess = spawn(ANVIL, ['--port', String(port), '--silent'], { stdio: 'ignore' })

  const chain = createPublicClient({ chain: foundry, transport: http(RPC) })
  // wait for RPC
  for (let i = 0; i < 60; i++) {
    try {
      await chain.getChainId()
      break
    } catch {
      await new Promise((r) => setTimeout(r, 250))
    }
  }

  const wallet = (key: Hex) =>
    createWalletClient({ account: privateKeyToAccount(key), chain: foundry, transport: http(RPC) })

  const admin = wallet(KEYS.admin)
  const relayer = wallet(KEYS.relayer)
  const payer = wallet(KEYS.payer)
  const attacker = wallet(KEYS.attacker)

  const deploy = async (name: string, args: unknown[] = [], from = admin) => {
    const { abi, bytecode } = artifact(name)
    const hash = await from.deployContract({ abi, bytecode, args })
    const receipt = await chain.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`${name} deploy failed`)
    return receipt.contractAddress
  }

  const feeWallet = privateKeyToAccount(KEYS.feeWallet).address.toLowerCase() as Address
  const gasTreasury = privateKeyToAccount(KEYS.gasTreasury).address.toLowerCase() as Address
  const seller = privateKeyToAccount(KEYS.seller).address.toLowerCase() as Address

  /**
   * A recurring contract bound to one token. Most tests want the shared instance below, but the
   * token is immutable and enforced in `charge`, so anything that must be charged in a *different*
   * token - the reentrancy and false-return attacks, which need the malicious token to be the one
   * being transferred - deploys its own instance bound to that token.
   */
  const deployRecurring = (supportedToken: Address, relayerAddress: Address = relayer.account.address) =>
    deploy('P2FluxRecurring', [admin.account.address, relayerAddress, feeWallet, gasTreasury, supportedToken])

  // The token first now: the contract is bound to it at construction.
  const token = await deploy('MockUSDC')
  const recurring = await deployRecurring(token)

  /** A splitter bound to a token, for the one-time suite. */
  const deploySplitter = (supportedToken: Address = token) =>
    deploy('P2FluxSplitter', [supportedToken, feeWallet])

  const splitter = await deploySplitter(token)

  const chainId = await chain.getChainId()

  const helpers = {
    rpc: RPC,
    chain,
    chainId,
    recurring,
    splitter,
    deploySplitter,
    token,
    feeWallet,
    gasTreasury,
    seller,
    admin,
    relayer,
    payer,
    attacker,
    wallet,
    deploy,
    deployRecurring,

    async mint(to: Address, amount: bigint, tokenAddress: Address = token) {
      const hash = await admin.writeContract({
        address: tokenAddress,
        abi: artifact('MockUSDC').abi,
        functionName: 'mint',
        args: [to, amount],
      })
      await chain.waitForTransactionReceipt({ hash })
    },

    async approve(
      owner: ReturnType<typeof wallet>,
      amount: bigint = maxUint256,
      tokenAddress: Address = token,
      spender: Address = recurring,
    ) {
      const hash = await owner.writeContract({
        address: tokenAddress,
        abi: artifact('MockUSDC').abi,
        functionName: 'approve',
        args: [spender, amount],
      })
      await chain.waitForTransactionReceipt({ hash })
    },

    async balance(of: Address, tokenAddress: Address = token) {
      return (await chain.readContract({
        address: tokenAddress,
        abi: artifact('MockUSDC').abi,
        functionName: 'balanceOf',
        args: [of],
      })) as bigint
    },

    async now() {
      return Number((await chain.getBlock({ blockTag: 'latest' })).timestamp)
    },

    async travel(seconds: number) {
      await chain.request({ method: 'evm_increaseTime' as never, params: [seconds] as never })
      await chain.request({ method: 'evm_mine' as never, params: [] as never })
    },

    /** Sign an authorization with the payer's key (or any other account's). */
    async sign(auth: RecurringAuthorization, signer = payer, verifyingContract: Address = recurring) {
      return signer.signTypedData(recurringTypedData(auth, chainId, verifyingContract) as never)
    },

    async charge(
      auth: RecurringAuthorization,
      signature: Hex,
      opts: { from?: ReturnType<typeof wallet>; gasReimbursement?: bigint; at?: Address } = {},
    ) {
      const from = opts.from ?? relayer
      const hash = await from.writeContract({
        address: opts.at ?? recurring,
        abi: recurringAbi,
        functionName: 'charge',
        args: [abiAuth(auth), signature, opts.gasReimbursement ?? 0n],
      })
      return chain.waitForTransactionReceipt({ hash })
    },

    /** Expect a charge (or any write) to revert; returns the custom error name when decodable. */
    async expectRevert(promise: Promise<unknown>): Promise<string> {
      try {
        await promise
      } catch (err) {
        const message = String((err as Error).message ?? '')
        // Custom errors decode to a name; string require() reverts just report 'reverted'.
        return /Error: (\w+)\(/.exec(message)?.[1] ?? 'reverted'
      }
      throw new Error('expected revert, call succeeded')
    },

    async read<T>(functionName: string, args: unknown[] = [], at: Address = recurring): Promise<T> {
      const mapped = args.map((a) =>
        a && typeof a === 'object' && 'salt' in (a as object) ? abiAuth(a as RecurringAuthorization) : a,
      )
      return (await chain.readContract({
        address: at,
        abi: recurringAbi,
        functionName,
        args: mapped,
      } as never)) as T
    },

    stop() {
      proc.kill()
    },
  }

  return helpers
}

/** A fresh, valid authorization anchored at the current chain time. */
export async function baseAuth(h: Harness, over: Partial<RecurringAuthorization> = {}): Promise<RecurringAuthorization> {
  return {
    payer: h.payer.account.address.toLowerCase() as Address,
    recipient: h.seller,
    token: h.token,
    amount: 10_000_000n, // 10 USDC
    period: 30 * 24 * 3600,
    start: await h.now(),
    end: 0,
    salt: BigInt(Math.floor(Math.random() * 1e12)),
    maxGasReimbursement: 50_000n, // 0.05 USDC, the hard cap
    ...over,
  }
}
