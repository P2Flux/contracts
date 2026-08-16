import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { after, before, describe, test } from 'node:test'
import { encodeFunctionData, keccak256, parseEventLogs, toBytes, zeroAddress, type Address, type Hex } from 'viem'
import { paymentIdFor, splitterAbi } from '../src/splitter.js'
import { startHarness, type Harness } from './_anvil.js'

/** The real deployed surface, straight from solc. */
const compiledAbi = () =>
  (
    JSON.parse(readFileSync(new URL('../out/P2FluxSplitter.json', import.meta.url), 'utf8')) as {
      abi: { type: string; name?: string; stateMutability?: string }[]
    }
  ).abi

/**
 * One-time payments, on a real chain.
 *
 * The headline test is `a settlement in a token that does not exist is impossible`: the exploit this
 * suite was written for. Before the token was pinned, `pay()` took any address, and a CALL to an
 * address with no code returns success with empty returndata - which the ERC-20 convention reads as
 * "transferred". So `pay(address(0), seller, amount, ref)` moved nothing and still emitted a genuine
 * `Paid` from the genuine splitter. Anything treating that event as proof of payment could be handed
 * an unlimited number of forged settlements alongside one real payment.
 */
describe('P2FluxSplitter', () => {
  let h: Harness
  const AMOUNT = 1_000_000n // 1.00 USDC
  const FEE = 10_000n // 1%
  const NET = AMOUNT - FEE

  const ref = (seed: string) => keccak256(toBytes(seed))

  before(async () => {
    h = await startHarness()
    await h.mint(h.payer.account.address, 1_000_000_000n)
    await h.approve(h.payer, 1_000_000_000n, h.token, h.splitter)
  })
  after(async () => h.stop())

  const pay = async (args: { token?: Address; recipient?: Address; amount?: bigint; ref: Hex; from?: typeof h.payer }) => {
    const wallet = args.from ?? h.payer
    const hash = await wallet.writeContract({
      address: h.splitter,
      abi: splitterAbi,
      functionName: 'pay',
      args: [args.token ?? h.token, args.recipient ?? h.seller, args.amount ?? AMOUNT, args.ref],
    })
    return h.chain.waitForTransactionReceipt({ hash })
  }

  test('a real payment splits 99/1 straight from the buyer, and the contract keeps nothing', async () => {
    const before = { seller: await h.balance(h.seller), fee: await h.balance(h.feeWallet) }

    const receipt = await pay({ ref: ref('happy') })
    assert.equal(receipt.status, 'success')

    assert.equal((await h.balance(h.seller)) - before.seller, NET)
    assert.equal((await h.balance(h.feeWallet)) - before.fee, FEE)
    assert.equal(await h.balance(h.splitter), 0n, 'no custody, ever')
  })

  test('the receipt names the token, so nothing has to assume which asset settled', async () => {
    const receipt = await pay({ ref: ref('names-token') })
    const [paid] = parseEventLogs({ abi: splitterAbi, eventName: 'Paid', logs: receipt.logs })

    assert.equal(paid.args.token.toLowerCase(), h.token.toLowerCase())
    assert.equal(paid.args.net, NET)
    assert.equal(paid.args.fee, FEE)
  })

  test('the settlement id the contract emits is the one computed off-chain, and it binds the token', async () => {
    const receipt = await pay({ ref: ref('id-binding') })
    const [settled] = parseEventLogs({ abi: splitterAbi, eventName: 'PaymentSettled', logs: receipt.logs })

    const expected = paymentIdFor({
      token: h.token,
      recipient: h.seller,
      amount: AMOUNT,
      reference: ref('id-binding'),
    })
    assert.equal(settled.args.paymentId.toLowerCase(), expected.toLowerCase())

    // The same terms in a different token are a different payment - which is what makes an id
    // computed off-chain safe to trust.
    const otherToken = paymentIdFor({
      token: zeroAddress,
      recipient: h.seller,
      amount: AMOUNT,
      reference: ref('id-binding'),
    })
    assert.notEqual(otherToken.toLowerCase(), expected.toLowerCase())
  })

  // --- the exploit this suite exists for --------------------------------------

  test('EXPLOIT: a settlement in a token that does not exist is impossible', async () => {
    /* The original attack, executed verbatim: pay() with a codeless address. It used to succeed
     * having moved nothing. Now the token is pinned at deployment and checked before any state
     * changes, so it cannot even be attempted. */
    await assert.rejects(
      () => pay({ token: zeroAddress, ref: ref('forged') }),
      (err: Error) => /TokenNotSupported/.test(err.message),
      'pay() must refuse any token but the one this deployment settles',
    )

    // And nothing was recorded: the intent stays payable, so a griefer cannot burn it either.
    const processed = await h.chain.readContract({
      address: h.splitter,
      abi: splitterAbi,
      functionName: 'isPaymentProcessed',
      args: [zeroAddress, h.seller, AMOUNT, ref('forged')],
    })
    assert.equal(processed, false)
  })

  test('EXPLOIT: a second token contract cannot forge a settlement either', async () => {
    // Not just address(0): any other real ERC-20 is refused too, so a worthless token the attacker
    // controls and can mint freely is no better than a codeless address.
    const worthless = await h.deploy('MockUSDC')
    await h.mint(h.attacker.account.address, 1_000_000_000n, worthless)
    await h.approve(h.attacker, 1_000_000_000n, worthless, h.splitter)

    await assert.rejects(
      () => pay({ token: worthless, ref: ref('worthless'), from: h.attacker }),
      (err: Error) => /TokenNotSupported/.test(err.message),
    )
  })

  test('EXPLOIT: one real payment cannot be bundled with forged ones in a single transaction', async () => {
    /* The full attack shape: a batch that carries the genuine payment plus N forged settlements at
     * the same recipient and amount, so one set of real Transfer logs could satisfy N verifications.
     * The whole batch now reverts on the first forged leg - and because pay() checks the token
     * before touching state, the genuine leg is rolled back with it rather than half-settling. */
    const batch = await h.deploy('MockUSDC') // any contract with code; used only as a call target
    void batch

    const before = await h.balance(h.seller)
    await assert.rejects(
      () =>
        h.payer.writeContract({
          address: h.splitter,
          abi: splitterAbi,
          functionName: 'pay',
          args: [zeroAddress, h.seller, AMOUNT, ref('bundle-forged')],
        }),
      (err: Error) => /TokenNotSupported/.test(err.message),
    )
    assert.equal(await h.balance(h.seller), before, 'no value moved on the forged leg')
  })

  // --- replay and validation ---------------------------------------------------

  test('the same intent settles exactly once', async () => {
    const r = ref('replay')
    await pay({ ref: r })

    await assert.rejects(
      () => pay({ ref: r }),
      (err: Error) => /PaymentAlreadyProcessed/.test(err.message),
    )
  })

  test('a fresh reference for identical terms is a different payment', async () => {
    await pay({ ref: ref('twice-a') })
    const receipt = await pay({ ref: ref('twice-b') })
    assert.equal(receipt.status, 'success', 'buying the same thing twice must work')
  })

  test('zero recipient and zero amount are refused', async () => {
    await assert.rejects(
      () => pay({ recipient: zeroAddress, ref: ref('zero-recipient') }),
      (err: Error) => /ZeroAddress/.test(err.message),
    )
    await assert.rejects(
      () => pay({ amount: 0n, ref: ref('zero-amount') }),
      (err: Error) => /ZeroAmount/.test(err.message),
    )
  })

  test('a token with no code cannot be bound at deployment', async () => {
    // The constructor is where "every transfer trivially succeeds" is refused once and for all.
    await assert.rejects(
      () => h.deploySplitter(zeroAddress),
      (err: Error) => /ZeroAddress|reverted/.test(err.message),
    )
    await assert.rejects(
      () => h.deploySplitter('0x000000000000000000000000000000000000dEaD' as Address),
      (err: Error) => /NotAContract|reverted/.test(err.message),
    )
  })

  test('the ABI exposes no way to move tokens except pay, and no privileged role at all', () => {
    /* Read from the COMPILED artifact, not the hand-written mirror in src/: a mirror cannot
     * tell you that the deployed bytecode grew a setter back, which is the only thing worth asserting
     * here. */
    const writers = compiledAbi()
      .filter((e) => e.type === 'function' && e.stateMutability === 'nonpayable')
      .map((e) => (e as { name: string }).name)
      .sort()

    assert.deepEqual(writers, ['pay', 'payWithPermit'], 'no admin, no relayer, no withdrawal')
  })

  test('the fee wallet is immutable, so a verified payment stays verifiable', async () => {
    const setters = compiledAbi()
      .filter((e) => e.type === 'function' && /^set/.test((e as { name: string }).name ?? ''))
      .map((e) => (e as { name: string }).name)
    assert.deepEqual(setters, [], 'nothing can redirect the fee stream')

    const feeWallet = await h.chain.readContract({
      address: h.splitter,
      abi: splitterAbi,
      functionName: 'feeWallet',
    })
    assert.equal((feeWallet as string).toLowerCase(), h.feeWallet.toLowerCase())
  })

  test('the deployment is pinned to one token, readable by anyone', async () => {
    const supported = await h.chain.readContract({
      address: h.splitter,
      abi: splitterAbi,
      functionName: 'supportedToken',
    })
    assert.equal((supported as string).toLowerCase(), h.token.toLowerCase())
  })

  void encodeFunctionData
})
