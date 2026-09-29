/**
 * x402 settlement on a real chain, driven exactly the way the API will drive it: viem, the exported
 * ABI and typed data, a signature from an x402-shaped client, a relayer transaction.
 *
 * The Foundry suites prove the contract's properties; this one proves the TypeScript surface the API
 * builds on is the contract's - the generated ABI, the fee mirror, the typed data, the payment id
 * and the ERC-20 read the facilitator uses to refuse replays before paying gas.
 */
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { after, before, describe, test } from 'node:test'
import { BaseError, ContractFunctionRevertedError, keccak256, parseEventLogs, toBytes, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { erc20Abi } from '../src/abi.js'
import { paymentIdFor } from '../src/splitter.js'
import { p2fluxX402SplitterAbi, transferWithAuthorizationTypedData, x402MaxFee } from '../src/x402.js'
import { startHarness, type Harness } from './_anvil.js'

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../out/${name}.json`, import.meta.url), 'utf8')) as {
    abi: readonly unknown[]
    bytecode: Hex
  }

const MIN_FEE = 3_000n

describe('x402 settlement', () => {
  let h: Harness
  let token: Address
  let splitter: Address

  before(async () => {
    h = await startHarness()
    token = await h.deploy('MockFiatToken')
    const proxy = await h.deploy('MockUptoPermit2Proxy')
    splitter = await h.deploy('P2FluxX402Splitter', [token, h.feeWallet, h.relayer.account.address, proxy, MIN_FEE])
  })
  after(() => h?.stop())

  const read = <T>(functionName: string, args: unknown[] = [], address = splitter, abi: unknown = p2fluxX402SplitterAbi) =>
    h.chain.readContract({ address, abi: abi as never, functionName, args } as never) as Promise<T>

  const balance = (who: Address) => read<bigint>('balanceOf', [who], token, erc20Abi)

  /** An x402 `exact` payment as the agent's client produces it, for `seller`'s vault. */
  const agentPays = async (seller: Address, value: bigint, seed: string) => {
    const key = keccak256(toBytes(`agent ${seed}`))
    const agent = privateKeyToAccount(key)
    await h.mint(agent.address, value, token)
    const vault = await read<Address>('vaultOf', [seller])
    const nonce = keccak256(toBytes(`nonce ${seed}`))
    const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600)
    const signature = await h.wallet(key).signTypedData(
      transferWithAuthorizationTypedData({
        chainId: h.chainId,
        token,
        tokenName: await read<string>('name', [], token, erc20Abi),
        tokenVersion: '2',
        from: agent.address,
        to: vault,
        value,
        validBefore,
        nonce,
      }) as never,
    )
    const authorization = { from: agent.address, value, validAfter: 0n, validBefore, nonce }
    return { agent: agent.address, vault, nonce, authorization, signature }
  }

  test('the exported ABI is exactly the compiled contract', () => {
    assert.deepEqual(p2fluxX402SplitterAbi, artifact('P2FluxX402Splitter').abi)
  })

  test('x402MaxFee mirrors the contract', async () => {
    for (const amount of [0n, 1n, 10_000n, 199_999n, 200_000n, 300_000n, 123_456_789n]) {
      assert.equal(x402MaxFee(amount, MIN_FEE), await read<bigint>('maxFee', [amount]), `amount ${amount}`)
    }
  })

  test('an agent pays a seller; the relayer settles; the events identify the payment', async () => {
    const seller = h.seller
    const p = await agentPays(seller, 1_000_000n, 'first')
    const hash = await h.relayer.writeContract({
      address: splitter,
      abi: p2fluxX402SplitterAbi,
      functionName: 'settleWithAuthorization',
      args: [seller, 10_000n, p.authorization, p.signature],
    })
    const receipt = await h.chain.waitForTransactionReceipt({ hash })
    assert.equal(receipt.status, 'success')

    const [paid] = parseEventLogs({ abi: p2fluxX402SplitterAbi, eventName: 'Paid', logs: receipt.logs })
    const [settled] = parseEventLogs({ abi: p2fluxX402SplitterAbi, eventName: 'PaymentSettled', logs: receipt.logs })
    assert.ok(paid && settled, 'Paid and PaymentSettled emitted')
    assert.equal(paid.args.ref, p.nonce, 'reference is the authorization nonce')
    assert.equal(paid.args.recipient.toLowerCase(), seller.toLowerCase())
    assert.equal(paid.args.net + paid.args.fee, 1_000_000n)
    assert.equal(
      settled.args.paymentId,
      paymentIdFor({ token, recipient: seller, amount: 1_000_000n, reference: p.nonce }),
      'same payment id as P2FluxSplitter',
    )
    assert.equal(await balance(p.agent), 0n)
    assert.equal(await balance(p.vault), 0n)
    assert.equal(await read<boolean>('authorizationState', [p.agent, p.nonce], token, erc20Abi), true)
  })

  test('a replay is refused in simulation, with a decodable reason, before any gas is spent', async () => {
    const p = await agentPays(h.seller, 500_000n, 'replay')
    await h.relayer.writeContract({
      address: splitter,
      abi: p2fluxX402SplitterAbi,
      functionName: 'settleWithAuthorization',
      args: [h.seller, 0n, p.authorization, p.signature],
    })
    await assert.rejects(
      h.chain.simulateContract({
        account: h.relayer.account,
        address: splitter,
        abi: p2fluxX402SplitterAbi,
        functionName: 'settleWithAuthorization',
        args: [h.seller, 0n, p.authorization, p.signature],
      }),
      (err: unknown) => {
        const revert = (err as BaseError).walk((e) => e instanceof ContractFunctionRevertedError)
        assert.ok(revert instanceof ContractFunctionRevertedError)
        assert.equal(revert.data?.errorName, 'PaymentAlreadyProcessed')
        return true
      },
    )
  })

  test('the relayer cannot settle an agent signature to another seller', async () => {
    const p = await agentPays(h.seller, 700_000n, 'redirect')
    await assert.rejects(
      h.chain.simulateContract({
        account: h.relayer.account,
        address: splitter,
        abi: p2fluxX402SplitterAbi,
        functionName: 'settleWithAuthorization',
        args: [h.attacker.account.address, 0n, p.authorization, p.signature],
      }),
      /invalid authorization signature/,
    )
    assert.equal(await balance(p.agent), 700_000n)
  })
})
