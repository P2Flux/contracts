/**
 * AUDIT — adversarial money-flow tests for the sponsored contracts. Not part of `npm test`.
 * Run: node --import tsx --test test/audit/*.audit.ts
 *
 * Tests marked "documents" are expected to PASS while demonstrating a property that is a finding
 * (e.g. a griefing cost); their assertions describe what happens today, not what should.
 */
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { after, before, describe, test } from 'node:test'
import { keccak256, parseEventLogs, toBytes, type Abi, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import {
  gasSponsorAbi,
  permitTypedData,
  receiveWithAuthorizationTypedData,
  sponsoredPaymentNonce,
  sponsoredSplitterAbi,
  sponsorPermitNonce,
  type SponsoredPayment,
} from '../../src/sponsored.js'
import { recurringAbi } from '../../src/recurring.js'
import { startHarness, type Harness } from '../_anvil.js'

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../../out/${name}.json`, import.meta.url), 'utf8')) as { abi: Abi; bytecode: Hex }

const FIXED = 100_000n
const CAP = 250_000n
const MINT = 1_000_000_000n
const split = (sig: Hex) => ({ v: Number(`0x${sig.slice(130, 132)}`), r: `0x${sig.slice(2, 66)}` as Hex, s: `0x${sig.slice(66, 130)}` as Hex })

describe('AUDIT: sponsored contracts money flow', () => {
  let h: Harness
  let token: Address
  let splitter: Address
  let sponsor: Address
  let tokenName: string
  let seed = 0x9000

  const fresh = () => {
    const key = `0x${(seed++).toString(16).padStart(64, '0')}` as Hex
    return { account: privateKeyToAccount(key), wallet: h.wallet(key) }
  }
  const tokenAbi = () => artifact('MockFiatToken').abi
  const bal = (a: Address) => h.balance(a, token)
  const allowance = async (o: Address, s: Address) =>
    (await h.chain.readContract({ address: token, abi: tokenAbi(), functionName: 'allowance', args: [o, s] })) as bigint
  const permitNonce = async (o: Address) =>
    (await h.chain.readContract({ address: token, abi: tokenAbi(), functionName: 'nonces', args: [o] })) as bigint

  const signPayment = (p: SponsoredPayment, signer: ReturnType<typeof h.wallet>, over: { at?: Address; chainId?: number; token?: Address; fixed?: bigint; nonceFrom?: SponsoredPayment; value?: bigint } = {}) =>
    signer
      .signTypedData(
        receiveWithAuthorizationTypedData({
          chainId: over.chainId ?? h.chainId,
          token: over.token ?? token,
          tokenName,
          tokenVersion: '2',
          from: p.payer,
          to: over.at ?? splitter,
          value: over.value ?? p.amount + p.networkFee,
          validBefore: p.validBefore,
          nonce: sponsoredPaymentNonce({ chainId: over.chainId ?? h.chainId, splitter: over.at ?? splitter, token: over.token ?? token, fixedNetworkFee: over.fixed ?? FIXED, payment: over.nonceFrom ?? p }),
        }) as never,
      )
      .then(split)

  const pay = async (p: SponsoredPayment, sig: { v: number; r: Hex; s: Hex }, from = h.relayer) => {
    const hash = await from.writeContract({ address: splitter, abi: sponsoredSplitterAbi, functionName: 'payWithAuthorization', args: [p, sig.v, sig.r, sig.s] })
    return h.chain.waitForTransactionReceipt({ hash })
  }

  type Sp = { payer: Address; spender: Address; allowanceValue: bigint; allowanceDeadline: bigint; networkFee: bigint; validBefore: bigint }
  const signPermit = (s: Sp, signer: ReturnType<typeof h.wallet>, nonce: bigint) =>
    signer.signTypedData(permitTypedData({ chainId: h.chainId, token, tokenName, tokenVersion: '2', owner: s.payer, spender: s.spender, value: s.allowanceValue, nonce, deadline: s.allowanceDeadline }) as never).then(split)
  const signFee = (s: Sp, signer: ReturnType<typeof h.wallet>, at = sponsor) =>
    signer
      .signTypedData(
        receiveWithAuthorizationTypedData({
          chainId: h.chainId, token, tokenName, tokenVersion: '2', from: s.payer, to: at, value: s.networkFee, validBefore: s.validBefore,
          nonce: sponsorPermitNonce({ chainId: h.chainId, sponsor: at, token, ...s }),
        }) as never,
      )
      .then(split)
  const sponsorCall = async (s: Sp, permit: ReturnType<typeof split>, fee: ReturnType<typeof split>, from = h.relayer) => {
    const hash = await from.writeContract({ address: sponsor, abi: gasSponsorAbi, functionName: 'sponsorPermit', args: [s, permit.v, permit.r, permit.s, fee.v, fee.r, fee.s] })
    return h.chain.waitForTransactionReceipt({ hash })
  }

  before(async () => {
    h = await startHarness()
    token = await h.deploy('MockFiatToken')
    tokenName = (await h.chain.readContract({ address: token, abi: tokenAbi(), functionName: 'name' })) as string
    splitter = await h.deploy('P2FluxSponsoredSplitter', [token, h.feeWallet, h.gasTreasury, h.relayer.account.address, FIXED, CAP])
    sponsor = await h.deploy('P2FluxGasSponsor', [token, h.gasTreasury, h.relayer.account.address, CAP])
  })
  after(async () => h.stop())

  // ---------------------------------------------------------------------------------------------
  test('A1 conservation holds at every boundary and under dust, in integer units', async () => {
    const minimum = (await h.chain.readContract({ address: splitter, abi: sponsoredSplitterAbi, functionName: 'minimumAmount' })) as bigint
    assert.equal(minimum, 101_011n)
    // Donated dust must ride through untouched.
    await h.mint(splitter, 7n, token) // donated dust, straight onto the contract
    const dustBefore = await bal(splitter)
    assert.equal(dustBefore, 7n)

    const amounts = [minimum - 1n, minimum, minimum + 1n, 500_000n, 1_000_000n, 9_999_999n, 10_000_001n, 123_456_789n]
    const fees = [0n, 1n, 4_078n, CAP]
    let n = 0
    for (const amount of amounts) for (const networkFee of fees) {
      const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
      const p: SponsoredPayment = { payer: account.address, recipient: h.seller, amount, ref: keccak256(toBytes(`a1-${n++}`)), networkFee, validBefore: BigInt((await h.now()) + 600) }
      const before = { p: await bal(account.address), m: await bal(h.seller), f: await bal(h.feeWallet), g: await bal(h.gasTreasury), c: await bal(splitter) }
      const sig = await signPayment(p, wallet)
      if (amount <= amount * 100n / 10_000n + FIXED) {
        assert.equal(await h.expectRevert(pay(p, sig)), 'AmountTooSmall', `${amount} must be refused`)
        assert.equal(await bal(account.address), before.p, 'refusal moves nothing')
        continue
      }
      const receipt = await pay(p, sig)
      assert.equal(receipt.status, 'success')
      const fee = (amount * 100n) / 10_000n
      const after = { p: await bal(account.address), m: await bal(h.seller), f: await bal(h.feeWallet), g: await bal(h.gasTreasury), c: await bal(splitter) }
      assert.equal(before.p - after.p, amount + networkFee, 'buyer debit == amount + networkFee')
      assert.equal(after.m - before.m, amount - fee - FIXED, 'merchant == amount - 1% - fixed')
      assert.equal(after.f - before.f, fee, 'feeWallet == 1% only')
      assert.equal(after.g - before.g, networkFee + FIXED, 'gasTreasury == networkFee + fixed')
      assert.equal((after.m - before.m) + (after.f - before.f) + (after.g - before.g), before.p - after.p, 'sum(out) == pulled')
      assert.equal(after.c, before.c, 'residual unchanged (dust preserved, none created)')
      assert.ok(amount - fee - FIXED > 0n, 'merchant net strictly positive')
    }
  })

  test('A2 signature cross-use matrix: every substitution fails', async () => {
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const vb = BigInt((await h.now()) + 600)
    const p: SponsoredPayment = { payer: account.address, recipient: h.seller, amount: 1_000_000n, ref: keccak256(toBytes('a2')), networkFee: 4_078n, validBefore: vb }
    const good = await signPayment(p, wallet)

    // One-time signature presented at the gas sponsor as a fee authorization (same payer, same value).
    const sp: Sp = { payer: account.address, spender: h.recurring, allowanceValue: 550_000n, allowanceDeadline: vb, networkFee: 4_078n, validBefore: vb }
    const permit = await signPermit(sp, wallet, await permitNonce(account.address))
    assert.match(await h.expectRevert(sponsorCall(sp, permit, good)), /reverted|invalid/i, 'one-time sig unusable at sponsor')

    // Tampered submissions by the relayer against an honest signature — each field.
    for (const [label, bad] of [
      ['recipient', { ...p, recipient: h.attacker.account.address }],
      ['amount up', { ...p, amount: p.amount + 1n }],
      ['amount down', { ...p, amount: p.amount - 1n }],
      ['networkFee up', { ...p, networkFee: p.networkFee + 1n }],
      ['networkFee down', { ...p, networkFee: p.networkFee - 1n }],
      ['ref', { ...p, ref: keccak256(toBytes('other')) }],
      ['payer', { ...p, payer: h.attacker.account.address }],
      ['validBefore', { ...p, validBefore: vb + 1n }],
    ] as [string, SponsoredPayment][]) {
      assert.match(await h.expectRevert(pay(bad, good)), /reverted|invalid/i, `tampered ${label} must fail`)
    }
    // Signature for another chain / another token / another contract / different fixed fee.
    for (const [label, over] of [
      ['chain 8453', { chainId: 8453 }],
      ['other token', { token: h.token }],
      ['other splitter address', { at: sponsor }],
      ['other fixed fee in nonce', { fixed: FIXED + 1n }],
      ['value excluding fee', { value: p.amount }],
    ] as [string, Parameters<typeof signPayment>[2]][]) {
      const sig = await signPayment(p, wallet, over)
      assert.match(await h.expectRevert(pay(p, sig)), /reverted|invalid/i, `${label} must fail`)
    }
    // Non-relayer with a perfectly good signature.
    assert.equal(await h.expectRevert(pay(p, good, h.attacker)), 'NotRelayer')
    assert.equal(await bal(account.address), MINT, 'nothing moved through any of the above')
  })

  test('A3 replay: second use of any authorization moves no money', async () => {
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const vb = BigInt((await h.now()) + 600)
    const p: SponsoredPayment = { payer: account.address, recipient: h.seller, amount: 1_000_000n, ref: keccak256(toBytes('a3')), networkFee: 4_078n, validBefore: vb }
    const sig = await signPayment(p, wallet)
    await pay(p, sig)
    const after1 = await bal(account.address)
    assert.equal(await h.expectRevert(pay(p, sig)), 'PaymentAlreadyProcessed')
    assert.equal(await bal(account.address), after1, 'replay moved nothing')

    // Same ref, new nonce (different networkFee) - still refused: processedPayments keys on (token, recipient, amount, ref).
    const p2 = { ...p, networkFee: 4_079n }
    assert.equal(await h.expectRevert(pay(p2, await signPayment(p2, wallet))), 'PaymentAlreadyProcessed')

    // Permit + fee replay at the sponsor.
    const sp: Sp = { payer: account.address, spender: h.recurring, allowanceValue: 550_000n, allowanceDeadline: vb, networkFee: 3_730n, validBefore: vb }
    const permit = await signPermit(sp, wallet, await permitNonce(account.address))
    const fee = await signFee(sp, wallet)
    await sponsorCall(sp, permit, fee)
    const after2 = await bal(account.address)
    assert.equal(await h.expectRevert(sponsorCall(sp, permit, fee)), 'SponsorshipAlreadySettled')
    assert.equal(await bal(account.address), after2)
    assert.equal(await allowance(account.address, h.recurring), 550_000n)
  })

  test('A4 restore <-> removal cross-use and the setup/restore nonce collision', async () => {
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const vb = BigInt((await h.now()) + 600)
    const restore: Sp = { payer: account.address, spender: h.recurring, allowanceValue: 550_000n, allowanceDeadline: vb, networkFee: 3_736n, validBefore: vb }
    const removal: Sp = { ...restore, allowanceValue: 0n, networkFee: 3_742n }
    const n0 = await permitNonce(account.address)
    const permitRestore = await signPermit(restore, wallet, n0)
    const feeRestore = await signFee(restore, wallet)
    // Restore signatures presented as a removal (relayer swaps allowanceValue to 0): permit fails on value.
    assert.match(await h.expectRevert(sponsorCall(removal, permitRestore, feeRestore)), /reverted|invalid/i)
    // And the reverse.
    const permitRemoval = await signPermit(removal, wallet, n0)
    const feeRemoval = await signFee(removal, wallet)
    assert.match(await h.expectRevert(sponsorCall(restore, permitRemoval, feeRemoval)), /reverted|invalid/i)
    assert.equal(await allowance(account.address, h.recurring), 0n, 'nothing changed')

    // The collision: setup and restore to the SAME value with identical terms share a nonce -> second
    // is SponsorshipAlreadySettled (liveness only; a fresh fee/expiry avoids it). Documents C-01/#3.
    await sponsorCall(restore, permitRestore, feeRestore)
    const permitAgain = await signPermit(restore, wallet, await permitNonce(account.address))
    assert.equal(await h.expectRevert(sponsorCall(restore, permitAgain, feeRestore)), 'SponsorshipAlreadySettled')
  })

  test('A5 documents C-01: a front-run permit reverts the sponsorship; simulation catches it before gas is spent', async () => {
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const vb = BigInt((await h.now()) + 600)
    const sp: Sp = { payer: account.address, spender: h.recurring, allowanceValue: 550_000n, allowanceDeadline: vb, networkFee: 3_730n, validBefore: vb }
    const permit = await signPermit(sp, wallet, await permitNonce(account.address))
    const fee = await signFee(sp, wallet)
    // Attacker (anyone with ETH) lands the permit directly, ahead of the relayer.
    const front = await h.attacker.writeContract({ address: token, abi: tokenAbi(), functionName: 'permit', args: [sp.payer, sp.spender, sp.allowanceValue, sp.allowanceDeadline, permit.v, permit.r, permit.s] })
    await h.chain.waitForTransactionReceipt({ hash: front })
    assert.equal(await allowance(account.address, h.recurring), 550_000n, 'customer got the allowance')
    const relayerEth = await h.chain.getBalance({ address: h.relayer.account.address })
    const buyerUsdc = await bal(account.address)
    assert.match(await h.expectRevert(sponsorCall(sp, permit, fee)), /reverted|invalid/i, 'relayer call reverts on the consumed permit nonce')
    assert.equal(await bal(account.address), buyerUsdc, 'fee was NOT collected: customer paid nothing, kept the allowance')
    /* viem simulates before broadcasting, exactly as the API's preflight does - so a front-run that lands
     * BEFORE preflight costs the relayer nothing. The loss window is only a front-run that lands between
     * preflight and inclusion (one block), and on Base there is no public mempool to observe it from. */
    assert.equal(await h.chain.getBalance({ address: h.relayer.account.address }), relayerEth, 'caught at simulation: no gas spent')
  })

  test('A6 constructor hazards (C-11): gasTreasury == address(this) is a permanent brick', async () => {
    // Predict the address, deploy with gasTreasury = itself.
    const nonce = await h.chain.getTransactionCount({ address: h.admin.account.address })
    const { getContractAddress } = await import('viem')
    const predicted = getContractAddress({ from: h.admin.account.address, nonce: BigInt(nonce) })
    const bricked = await h.deploy('P2FluxSponsoredSplitter', [token, h.feeWallet, predicted, h.relayer.account.address, FIXED, CAP])
    assert.equal(bricked.toLowerCase(), predicted.toLowerCase())
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const p: SponsoredPayment = { payer: account.address, recipient: h.seller, amount: 1_000_000n, ref: keccak256(toBytes('a6')), networkFee: 4_078n, validBefore: BigInt((await h.now()) + 600) }
    const sig = await signPayment(p, wallet, { at: bricked })
    const hash = h.relayer.writeContract({ address: bricked, abi: sponsoredSplitterAbi, functionName: 'payWithAuthorization', args: [p, sig.v, sig.r, sig.s] }).then((x) => h.chain.waitForTransactionReceipt({ hash: x }))
    assert.equal(await h.expectRevert(hash), 'ResidualBalance', 'every payment reverts forever; no owner, no setter')
  })

  test('A7 documents C-09: validBefore has no upper bound at the contract', async () => {
    const { account, wallet } = fresh(); await h.mint(account.address, MINT, token)
    const p: SponsoredPayment = { payer: account.address, recipient: h.seller, amount: 1_000_000n, ref: keccak256(toBytes('a7')), networkFee: 4_078n, validBefore: BigInt((await h.now()) + 10 * 365 * 24 * 3600) }
    const receipt = await pay(p, await signPayment(p, wallet))
    assert.equal(receipt.status, 'success', 'a ten-year authorization settles; the API (120-300s TTL) is the only bound')
  })

  test('A8 recurring: adjacent-second period boundary bills twice within one second (C-07, intended)', async () => {
    // The funded anvil payer: fresh keys hold no ETH and cannot send approve().
    const account = h.payer.account; const wallet = h.payer
    await h.mint(account.address, MINT, token)
    // The shared harness recurring is bound to h.token, not our FiatToken - deploy one on ours.
    const rec = await h.deployRecurring(token)
    await h.approve(wallet, undefined, token, rec)
    const start = await h.now()
    const auth = { payer: account.address, recipient: h.seller, token, amount: 1_000_000n, period: 3600, start, end: 0, salt: 7n, maxGasReimbursement: 50_000n }
    const sig = await h.sign(auth as never, wallet, rec)
    // Charge at the last second of period 0.
    await h.travel(3600 - 2)
    const r0 = await h.charge(auth as never, sig, { at: rec })
    assert.equal(r0.status, 'success')
    const p0 = parseEventLogs({ abi: recurringAbi, eventName: 'SubscriptionCharged', logs: r0.logs })[0]!.args as { periodIndex: bigint }
    await h.travel(2)
    const r1 = await h.charge(auth as never, sig, { at: rec })
    const p1 = parseEventLogs({ abi: recurringAbi, eventName: 'SubscriptionCharged', logs: r1.logs })[0]!.args as { periodIndex: bigint }
    assert.equal(p1.periodIndex - p0.periodIndex, 1n, 'two legitimate debits, consecutive periods, ~2 seconds apart')
    assert.equal(await h.expectRevert(h.charge(auth as never, sig, { at: rec })), 'AlreadyChargedThisPeriod')
  })
})
