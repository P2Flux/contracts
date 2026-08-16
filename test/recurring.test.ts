/**
 * P2FluxRecurring security suite, against a real EVM (anvil) with time travel.
 *
 * The contract holds unlimited token allowances, so the burden of proof is on it: nothing but the
 * exact signed payment may ever move, once per period, until revoked.
 *
 * Run: part of `npm test` (skipped with a clear message if anvil is not installed).
 */
import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { maxUint256, parseSignature, serializeSignature, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { readFileSync } from 'node:fs'
import {
  abiAuth,
  recurringAbi,
  recurringFee,
  recurringNet,
  recurringSubscriptionId,
  recurringTypedData,
} from '../src/recurring.js'
import { KEYS, baseAuth, startHarness, type Harness } from './_anvil.js'

const anvilInstalled = existsSync(`${homedir()}/.foundry/bin/anvil`)

let h: Harness

before(async () => {
  if (!anvilInstalled) return
  h = await startHarness()
  // Rich payer by default; individual tests override with fresh wallets where balance matters.
  await h.mint(h.payer.account.address, 1_000_000_000n) // 1000 USDC
  await h.approve(h.payer)
})

after(() => h?.stop())

const t = (name: string, fn: () => Promise<void>) =>
  test(name, { skip: anvilInstalled ? false : 'anvil not installed (foundryup)' }, fn)

// --- signature and identity --------------------------------------------------

t('TS hashTypedData equals the contract subscriptionId, field for field', async () => {
  const auth = await baseAuth(h, { end: (await h.now()) + 900_000, salt: 123456789n })
  const onchain = await h.read<Hex>('subscriptionId', [auth])
  const offchain = recurringSubscriptionId(auth, h.chainId, h.recurring)
  assert.equal(offchain.toLowerCase(), onchain.toLowerCase())
})

t('a valid EOA signature charges; every tampered field is rejected', async () => {
  const auth = await baseAuth(h)
  const signature = await h.sign(auth)

  // Tamper each field individually - the signature must die with it.
  const tampered: [string, Partial<typeof auth>][] = [
    ['payer', { payer: h.attacker.account.address.toLowerCase() as Address }],
    ['recipient', { recipient: h.attacker.account.address.toLowerCase() as Address }],
    ['token', { token: h.recurring }],
    ['amount up', { amount: auth.amount + 1n }],
    ['period shortened', { period: 60 }],
    ['start', { start: auth.start - 1000 }],
    ['end -> indefinite', { end: 0, start: auth.start }],
    ['salt', { salt: auth.salt + 1n }],
    ['gas cap up', { maxGasReimbursement: auth.maxGasReimbursement + 1n }],
  ]
  for (const [label, over] of tampered) {
    const changed = { ...auth, ...over }
    if (label === 'end -> indefinite') changed.end = 999_999_999_999 % 2 ** 40 // some different end
    const error = await h.expectRevert(h.charge(changed, signature))
    // Swapping the token is refused before the signature is even recovered: comparing one address
    // is cheap and ecrecover is not, so that check comes first. Every other tampered field gets as
    // far as signature verification and dies there. Both are refusals; only the reason differs.
    const expected = label === 'token' ? 'TokenNotSupported' : 'InvalidSignature'
    assert.equal(error, expected, `${label}: ${error}`)
  }

  // The untampered original still works.
  const receipt = await h.charge(auth, signature)
  assert.equal(receipt.status, 'success')
})

t('wrong signer is rejected even with correct terms', async () => {
  const auth = await baseAuth(h)
  const forged = await h.sign(auth, h.attacker)
  assert.equal(await h.expectRevert(h.charge(auth, forged)), 'InvalidSignature')
})

t('a signature is unusable against another deployment (verifyingContract binding)', async () => {
  const other = await h.deployRecurring(h.token)
  const auth = await baseAuth(h)
  const signature = await h.sign(auth) // signed for h.recurring

  const hash = await h.relayer.writeContract({
    address: other,
    abi: recurringAbi,
    functionName: 'charge',
    args: [abiAuth(auth), signature, 0n],
  }).catch((err) => err)
  assert.match(String(hash), /InvalidSignature/)
})

t('a signature over another chainId does not verify', async () => {
  const auth = await baseAuth(h)
  const wrongChain = recurringTypedData(auth, h.chainId + 1, h.recurring)
  const signature = await h.payer.signTypedData(wrongChain as never)
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'InvalidSignature')
})

t('identical terms with different salts are independent subscriptions', async () => {
  const start = await h.now()
  const a = await baseAuth(h, { start, salt: 1000n })
  const b = { ...a, salt: 1001n }

  assert.notEqual(
    await h.read<Hex>('subscriptionId', [a]),
    await h.read<Hex>('subscriptionId', [b]),
  )

  assert.equal((await h.charge(a, await h.sign(a))).status, 'success')
  assert.equal((await h.charge(b, await h.sign(b))).status, 'success', 'second salt charges independently')
})

t('ERC-1271: a contract wallet payer validates through its isValidSignature', async () => {
  const owner = privateKeyToAccount(KEYS.payer)
  const walletContract = await h.deploy('Mock1271Wallet', [owner.address])
  await h.mint(walletContract, 100_000_000n)

  // The wallet contract must approve the recurring contract itself.
  const approveData = {
    address: h.token,
    abi: [{ type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] }],
    functionName: 'approve',
    args: [h.recurring, maxUint256],
  }
  // Mock1271Wallet has no execute; instead give allowance by impersonation via anvil.
  await h.chain.request({ method: 'anvil_impersonateAccount' as never, params: [walletContract] as never })
  await h.chain.request({ method: 'anvil_setBalance' as never, params: [walletContract, '0x1000000000000000000'] as never })
  const impersonated = await import('viem').then(({ createWalletClient, http }) =>
    createWalletClient({ account: walletContract, chain: undefined, transport: http(h.rpc) }),
  )
  const approveHash = await impersonated.writeContract({ ...approveData, chain: null, account: walletContract } as never)
  await h.chain.waitForTransactionReceipt({ hash: approveHash })
  await h.chain.request({ method: 'anvil_stopImpersonatingAccount' as never, params: [walletContract] as never })

  const auth = await baseAuth(h, { payer: walletContract })
  // Owner signs the digest; the wallet's isValidSignature accepts it.
  const digest = recurringSubscriptionId(auth, h.chainId, h.recurring)
  const rawSig = await owner.sign({ hash: digest })
  const signature = serializeSignature(parseSignature(rawSig))

  const receipt = await h.charge(auth, signature)
  assert.equal(receipt.status, 'success')
})

// --- indefinite and fixed lifetimes ------------------------------------------

t('end = 0 runs indefinitely: many periods, no lifetime limit', async () => {
  const auth = await baseAuth(h, { period: 3600, end: 0 })
  const signature = await h.sign(auth)

  for (let i = 0; i < 24; i++) {
    assert.equal((await h.charge(auth, signature)).status, 'success', `period ${i}`)
    await h.travel(3600)
  }
})

t('end > 0 stops charging at expiry', async () => {
  const start = await h.now()
  const auth = await baseAuth(h, { period: 3600, end: start + 2 * 3600 })
  const signature = await h.sign(auth)

  assert.equal((await h.charge(auth, signature)).status, 'success')
  await h.travel(3 * 3600) // past end
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'Expired')
})

t('charging before start reverts', async () => {
  const auth = await baseAuth(h, { start: (await h.now()) + 86_400 })
  assert.equal(await h.expectRevert(h.charge(auth, await h.sign(auth))), 'NotStarted')
})

// --- period rules -------------------------------------------------------------

t('one charge per period: duplicate reverts, next period succeeds, across many periods', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth)

  assert.equal((await h.charge(auth, signature)).status, 'success')
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'AlreadyChargedThisPeriod')

  for (let i = 0; i < 5; i++) {
    await h.travel(3600)
    assert.equal((await h.charge(auth, signature)).status, 'success', `period ${i + 1}`)
    assert.equal(await h.expectRevert(h.charge(auth, signature)), 'AlreadyChargedThisPeriod')
  }
})

t('never-charged is distinct from charged-period-0', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const id = await h.read<Hex>('subscriptionId', [auth])

  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id]), 0n, 'never charged = 0')
  await h.charge(auth, await h.sign(auth))
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id]), 1n, 'period 0 charged = 1')
})

t('missed periods are not caught up - only the current period charges', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth)

  await h.charge(auth, signature)
  const payerBefore = await h.balance(auth.payer)

  await h.travel(5 * 3600) // skip 4 periods entirely
  await h.charge(auth, signature)
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'AlreadyChargedThisPeriod')

  const payerAfter = await h.balance(auth.payer)
  assert.equal(payerBefore - payerAfter, auth.amount, 'exactly one charge despite four missed periods')
})

t('no caller input can select a period - the timestamp alone decides', async () => {
  // The ABI simply has no period parameter; assert the derived index moves only with time.
  const auth = await baseAuth(h, { period: 3600 })
  const before = await h.read<bigint>('currentPeriod', [auth])
  await h.travel(3600)
  assert.equal(await h.read<bigint>('currentPeriod', [auth]), before + 1n)
})

// --- allowance states ---------------------------------------------------------

t('zero allowance fails; unlimited allowance charges repeatedly with no re-authorization', async () => {
  const fresh = h.wallet(KEYS.seller) // reuse seller key as a payer with no allowance
  await h.mint(fresh.account.address, 100_000_000n)

  const auth = await baseAuth(h, { payer: fresh.account.address.toLowerCase() as Address, period: 3600 })
  const signature = await h.sign(auth, fresh)

  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted', 'zero allowance')

  await h.approve(fresh, maxUint256)
  for (let i = 0; i < 3; i++) {
    assert.equal((await h.charge(auth, signature)).status, 'success')
    await h.travel(3600)
  }
})

t('finite insufficient allowance fails; approve(0) is the global stop', async () => {
  const fresh = h.wallet(KEYS.attacker)
  await h.mint(fresh.account.address, 100_000_000n)
  await h.approve(fresh, 5_000_000n) // less than the 10 USDC charge

  const auth = await baseAuth(h, { payer: fresh.account.address.toLowerCase() as Address, period: 3600 })
  const signature = await h.sign(auth, fresh)
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted', 'insufficient allowance')

  await h.approve(fresh, maxUint256)
  assert.equal((await h.charge(auth, signature)).status, 'success')

  // Global emergency stop: allowance to zero blocks every subscription on this token.
  const second = await baseAuth(h, { payer: fresh.account.address.toLowerCase() as Address, period: 3600, salt: 777n })
  const secondSig = await h.sign(second, fresh)
  await h.approve(fresh, 0n)
  await h.travel(3600)
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted', 'blocked after approve(0)')
  assert.equal(await h.expectRevert(h.charge(second, secondSig)), 'reverted', 'all subscriptions blocked')
})

// --- balance failure and retry -------------------------------------------------

t('insufficient balance reverts, rolls back the period marker, and a refill retries in-period', async () => {
  const poor = h.wallet(KEYS.feeWallet)
  await h.approve(poor, maxUint256)
  // no mint: zero balance

  const auth = await baseAuth(h, { payer: poor.account.address.toLowerCase() as Address, period: 3600 })
  const signature = await h.sign(auth, poor)
  const id = await h.read<Hex>('subscriptionId', [auth])

  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted', 'insufficient balance')
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id]), 0n, 'marker rolled back')
  assert.equal(await h.read<boolean>('revoked', [id]), false, 'NOT auto-revoked')

  await h.mint(poor.account.address, 50_000_000n)
  assert.equal((await h.charge(auth, signature)).status, 'success', 'retry in the same period works')
})

// --- revocation -----------------------------------------------------------------

t('only the payer can revoke; revocation is permanent and per-subscription', async () => {
  const start = await h.now()
  const a = await baseAuth(h, { start, period: 3600, salt: 42n })
  const b = await baseAuth(h, { start, period: 3600, salt: 43n })
  const sigA = await h.sign(a)
  const sigB = await h.sign(b)

  // Neither the seller nor an attacker can revoke someone else's authorization.
  for (const outsider of [h.attacker, h.wallet(KEYS.seller)]) {
    const err = await h.expectRevert(
      outsider
        .writeContract({ address: h.recurring, abi: recurringAbi, functionName: 'revoke', args: [abiAuth(a)] })
        .then((hash) => h.chain.waitForTransactionReceipt({ hash })),
    )
    assert.equal(err, 'NotPayer')
  }

  // Payer revokes A. B keeps working.
  const revokeHash = await h.payer.writeContract({
    address: h.recurring,
    abi: recurringAbi,
    functionName: 'revoke',
    args: [abiAuth(a)],
  })
  await h.chain.waitForTransactionReceipt({ hash: revokeHash })

  assert.equal(await h.expectRevert(h.charge(a, sigA)), 'Revoked')
  assert.equal((await h.charge(b, sigB)).status, 'success', 'sibling subscription unaffected')

  // Revoke is permanent - later periods too.
  await h.travel(2 * 3600)
  assert.equal(await h.expectRevert(h.charge(a, sigA)), 'Revoked')

  // Repeated revoke rejects cleanly.
  const again = await h.expectRevert(
    h.payer
      .writeContract({ address: h.recurring, abi: recurringAbi, functionName: 'revoke', args: [abiAuth(a)] })
      .then((hash) => h.chain.waitForTransactionReceipt({ hash })),
  )
  assert.equal(again, 'AlreadyRevoked')
})

// --- fees -----------------------------------------------------------------------

/** Every balance a charge can touch, so a test can assert the whole picture at once. */
async function ledger(payer: Address) {
  return {
    payer: await h.balance(payer),
    seller: await h.balance(h.seller),
    profit: await h.balance(h.feeWallet),
    treasury: await h.balance(h.gasTreasury),
    relayer: await h.balance(h.relayer.account.address),
  }
}

type Ledger = Awaited<ReturnType<typeof ledger>>
const delta = (before: Ledger, after: Ledger): Ledger => ({
  payer: after.payer - before.payer,
  seller: after.seller - before.seller,
  profit: after.profit - before.profit,
  treasury: after.treasury - before.treasury,
  relayer: after.relayer - before.relayer,
})

t('the worked example: 10.00 with 0.03 gas splits exactly and reconciles', async () => {
  const auth = await baseAuth(h, { amount: 10_000_000n, period: 3600 })
  const signature = await h.sign(auth)

  const before = await ledger(auth.payer)
  await h.charge(auth, signature, { gasReimbursement: 30_000n })
  const moved = delta(before, await ledger(auth.payer))

  assert.equal(moved.payer, -10_030_000n, 'customer pays the price plus gas, nothing else')
  assert.equal(moved.seller, 9_700_000n, 'merchant: 10.00 less 2% profit less the 0.10 network fee')
  assert.equal(moved.profit, 200_000n, 'profit wallet: exactly 2%, never any gas')
  assert.equal(moved.treasury, 130_000n, 'gas treasury: the 0.10 network fee plus the 0.03 gas')
  assert.equal(moved.relayer, 0n, 'the hot relayer accumulates nothing')

  // Nothing appears or disappears: what left the payer arrived somewhere.
  assert.equal(moved.seller + moved.profit + moved.treasury, -moved.payer)
  // And the commercial amount alone is what the three parties divide.
  assert.equal(moved.seller + moved.profit + (moved.treasury - 30_000n), auth.amount)
})

t('a 1.00 subscription: the fixed fee bites, the percentage does not change', async () => {
  const auth = await baseAuth(h, { amount: 1_000_000n, period: 3600 })
  const signature = await h.sign(auth)

  const before = await ledger(auth.payer)
  await h.charge(auth, signature, { gasReimbursement: 30_000n })
  const moved = delta(before, await ledger(auth.payer))

  assert.equal(moved.payer, -1_030_000n)
  assert.equal(moved.seller, 880_000n, '1.00 less 0.02 profit less 0.10 network')
  assert.equal(moved.profit, 20_000n, 'still exactly 2% - the fixed fee is not profit')
  assert.equal(moved.treasury, 130_000n)
  assert.equal(moved.seller + moved.profit + moved.treasury, -moved.payer)
})

t('rounding on the profit fee favours the merchant', async () => {
  // 2% of 149999 is 2999.98; the merchant keeps the fraction.
  const auth = await baseAuth(h, { amount: 149_999n, period: 3600 })

  const before = await ledger(auth.payer)
  await h.charge(auth, await h.sign(auth))
  const moved = delta(before, await ledger(auth.payer))

  assert.equal(moved.profit, 2_999n, 'truncated down')
  assert.equal(moved.seller, 149_999n - 2_999n - 100_000n)
  assert.equal(moved.treasury, 100_000n, 'the network fee alone when no gas is claimed')
})

t('an amount too small to leave the merchant anything is refused', async () => {
  // The floor: amount - floor(amount/50) - 100000 must be at least one base unit.
  for (const amount of [1n, 33n, 100_000n, 102_040n]) {
    const auth = await baseAuth(h, { amount, period: 3600 })
    assert.equal(
      await h.expectRevert(h.charge(auth, await h.sign(auth))),
      'AmountTooSmall',
      `${amount} leaves the merchant nothing`,
    )
  }

  // One unit more, and the merchant keeps exactly one unit.
  const auth = await baseAuth(h, { amount: 102_041n, period: 3600 })
  const before = await ledger(auth.payer)
  assert.equal((await h.charge(auth, await h.sign(auth))).status, 'success')
  const moved = delta(before, await ledger(auth.payer))
  assert.equal(moved.seller, 1n, 'the smallest chargeable subscription')
  assert.equal(moved.profit, 2_040n)
  assert.equal(moved.treasury, 100_000n)
})

t('zero amount is rejected outright', async () => {
  const auth = await baseAuth(h, { amount: 0n })
  assert.equal(await h.expectRevert(h.charge(auth, await h.sign(auth))), 'ZeroAmount')
})

t('only the deployment token can be charged', async () => {
  // A second, perfectly ordinary ERC-20. The fee constants are quantities of a 6-decimal token, so
  // an arbitrary token must never reach the fee math - the contract enforces that, not policy.
  const other = await h.deploy('MockUSDC')
  await h.mint(h.payer.account.address, 1_000_000_000n, other)
  await h.approve(h.payer, maxUint256, other)

  const auth = await baseAuth(h, { token: other, period: 3600 })
  assert.equal(await h.expectRevert(h.charge(auth, await h.sign(auth))), 'TokenNotSupported')
  assert.equal((await h.read<Address>('supportedToken')).toLowerCase(), h.token.toLowerCase())
})

// --- gas reimbursement -----------------------------------------------------------

t('relayer reimbursement works within both caps; buyer debit is exactly bounded', async () => {
  const auth = await baseAuth(h, { period: 3600, maxGasReimbursement: 30_000n })
  const signature = await h.sign(auth)

  const before = await ledger(auth.payer)
  await h.charge(auth, signature, { gasReimbursement: 2_000n })
  const moved = delta(before, await ledger(auth.payer))

  assert.equal(moved.treasury, 100_000n + 2_000n, 'the reimbursement joins the network fee')
  assert.equal(moved.relayer, 0n, 'and never reaches the key that signs transactions')
  assert.equal(moved.payer, -(auth.amount + 2_000n), 'amount + gas, nothing else')
})

t('reimbursement above the SIGNED cap reverts', async () => {
  const auth = await baseAuth(h, { period: 3600, maxGasReimbursement: 1_000n })
  const signature = await h.sign(auth)
  assert.equal(
    await h.expectRevert(h.charge(auth, signature, { gasReimbursement: 1_001n })),
    'GasReimbursementTooHigh',
  )
})

t('reimbursement above the PROTOCOL HARD CAP reverts even with an absurd signed cap', async () => {
  // The API-mistake scenario: a signed cap of 1000 USDC. The contract still refuses > 0.05.
  const auth = await baseAuth(h, { period: 3600, maxGasReimbursement: 1_000_000_000n })
  const signature = await h.sign(auth)
  assert.equal(
    await h.expectRevert(h.charge(auth, signature, { gasReimbursement: 50_001n })),
    'GasReimbursementTooHigh',
  )
  // At the cap exactly: allowed.
  assert.equal((await h.charge(auth, signature, { gasReimbursement: 50_000n })).status, 'success')
})

t('a NON-relayer caller gets zero reimbursement no matter what it passes', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth)

  const attackerBefore = await h.balance(h.attacker.account.address)
  const before = await ledger(auth.payer)

  // Attacker asks for the full signed cap. Charge succeeds - execution is public - but the
  // reimbursement is forced to zero, so the attacker pays gas for the privilege of paying the seller.
  const receipt = await h.charge(auth, signature, { from: h.attacker, gasReimbursement: 50_000n })
  assert.equal(receipt.status, 'success')
  const moved = delta(before, await ledger(auth.payer))

  assert.equal(await h.balance(h.attacker.account.address) - attackerBefore, 0n, 'attacker extracted nothing')
  assert.equal(moved.payer, -auth.amount, 'payer debited the amount only')
  assert.equal(moved.treasury, 100_000n, 'the network fee is owed on any successful charge')
})

// --- front-running ---------------------------------------------------------------

t('a public signature enables exactly the signed payment, nothing else', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth) // consider it leaked

  const sellerBefore = await h.balance(h.seller)
  await h.charge(auth, signature, { from: h.attacker })

  // Funds went to the buyer-signed recipient regardless of who called.
  assert.equal(await h.balance(h.seller) - sellerBefore, recurringNet(auth.amount))

  // And a modified payment with the same signature is impossible (covered field-by-field above);
  // spot-check the most valuable redirect:
  const redirect = { ...auth, recipient: h.attacker.account.address.toLowerCase() as Address }
  assert.equal(await h.expectRevert(h.charge(redirect, signature, { from: h.attacker })), 'InvalidSignature')
})

t('two racing identical charges: exactly one lands', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth)

  // Disable automine to put both transactions in the same block.
  await h.chain.request({ method: 'evm_setAutomine' as never, params: [false] as never })
  const tx1 = await h.relayer.writeContract({
    address: h.recurring, abi: recurringAbi, functionName: 'charge', args: [abiAuth(auth), signature, 0n], gas: 300_000n,
  })
  const tx2 = await h.attacker.writeContract({
    address: h.recurring, abi: recurringAbi, functionName: 'charge', args: [abiAuth(auth), signature, 0n], gas: 300_000n,
  })
  await h.chain.request({ method: 'evm_mine' as never, params: [] as never })
  await h.chain.request({ method: 'evm_setAutomine' as never, params: [true] as never })

  const receipts = await Promise.all([tx1, tx2].map((hash) => h.chain.getTransactionReceipt({ hash })))
  assert.equal(receipts.filter((r) => r.status === 'success').length, 1, 'exactly one winner')
})

// --- reentrancy and token behaviour ----------------------------------------------

t('reentrancy through a malicious token is stopped', async () => {
  const evil = await h.deploy('ReentrantToken')
  // The token under test has to be the one being transferred, and a deployment only charges its own
  // token - so this attack gets an instance bound to the malicious token.
  const target = await h.deployRecurring(evil)
  await h.mint(h.payer.account.address, 100_000_000n, evil)
  await h.approve(h.payer, maxUint256, evil, target)

  const auth = await baseAuth(h, { token: evil, period: 3600 })
  const signature = await h.sign(auth, h.payer, target)

  const evilAbi = JSON.parse(readFileSync(new URL('../out/ReentrantToken.json', import.meta.url), 'utf8')).abi
  const arm = await h.admin.writeContract({
    address: evil,
    abi: evilAbi,
    functionName: 'arm',
    args: [target, abiAuth(auth), signature],
  })
  await h.chain.waitForTransactionReceipt({ hash: arm })

  // The inner re-entrant charge reverts on the guard, which reverts the whole outer charge.
  assert.equal(await h.expectRevert(h.charge(auth, signature, { at: target })), 'reverted')
  const id = await h.read<Hex>('subscriptionId', [auth], target)
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id], target), 0n, 'state fully rolled back')
})

t('a false-returning token is treated as failure by SafeERC20, with rollback', async () => {
  const falsy = await h.deploy('FalseReturnToken')
  const target = await h.deployRecurring(falsy)
  await h.mint(h.payer.account.address, 100_000_000n, falsy)
  await h.approve(h.payer, maxUint256, falsy, target)

  const abi = JSON.parse(readFileSync(new URL('../out/FalseReturnToken.json', import.meta.url), 'utf8')).abi
  const set = await h.admin.writeContract({ address: falsy, abi, functionName: 'setFailTransfers', args: [true] })
  await h.chain.waitForTransactionReceipt({ hash: set })

  const auth = await baseAuth(h, { token: falsy, period: 3600 })
  const signature = await h.sign(auth, h.payer, target)
  assert.equal(await h.expectRevert(h.charge(auth, signature, { at: target })), 'reverted')

  const id = await h.read<Hex>('subscriptionId', [auth], target)
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id], target), 0n)

  const unset = await h.admin.writeContract({ address: falsy, abi, functionName: 'setFailTransfers', args: [false] })
  await h.chain.waitForTransactionReceipt({ hash: unset })
  assert.equal((await h.charge(auth, signature, { at: target })).status, 'success', 'recovers once the token behaves')
})

// --- invariants -------------------------------------------------------------------

t('the contract itself never holds tokens', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  await h.charge(auth, await h.sign(auth), { gasReimbursement: 1_000n })
  assert.equal(await h.balance(h.recurring), 0n)
})

t('no signature, no movement: garbage and empty signatures are rejected', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  assert.equal(await h.expectRevert(h.charge(auth, '0x')), 'InvalidSignature')
  assert.equal(await h.expectRevert(h.charge(auth, `0x${'11'.repeat(65)}`)), 'InvalidSignature')
})

t('the ABI has no path that moves tokens except charge', async () => {
  const artifact = JSON.parse(
    readFileSync(new URL('../out/P2FluxRecurring.json', import.meta.url), 'utf8'),
  ) as { abi: { type: string; name?: string; stateMutability?: string }[] }

  const writers = artifact.abi
    .filter((f) => f.type === 'function' && f.stateMutability !== 'view' && f.stateMutability !== 'pure')
    .map((f) => f.name)
    .sort()

  // charge (the only token mover), revoke, setRelayer. Nothing else - no execute, no withdraw,
  // no drain, no admin transferFrom.
  assert.deepEqual(writers, ['charge', 'revoke', 'setRelayer'])
})

t('admin can rotate the relayer; nothing else, and never funds', async () => {
  const err = await h.expectRevert(
    h.attacker
      .writeContract({ address: h.recurring, abi: recurringAbi, functionName: 'setRelayer', args: [h.attacker.account.address] })
      .then((hash) => h.chain.waitForTransactionReceipt({ hash })),
  )
  assert.equal(err, 'NotAdmin')

  const rotate = await h.admin.writeContract({
    address: h.recurring, abi: recurringAbi, functionName: 'setRelayer', args: [h.attacker.account.address],
  })
  await h.chain.waitForTransactionReceipt({ hash: rotate })
  assert.equal(((await h.read<Address>('relayer')) as string).toLowerCase(), h.attacker.account.address.toLowerCase())

  // restore
  const restore = await h.admin.writeContract({
    address: h.recurring, abi: recurringAbi, functionName: 'setRelayer', args: [h.relayer.account.address],
  })
  await h.chain.waitForTransactionReceipt({ hash: restore })
})
