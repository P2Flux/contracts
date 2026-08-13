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
  recurringSubscriptionId,
  recurringTypedData,
} from '../../packages/base/src/recurring.js'
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
    assert.equal(error, 'InvalidSignature', `${label}: ${error}`)
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
  const other = await h.deploy('P2FluxRecurring', [
    h.admin.account.address,
    h.relayer.account.address,
    h.feeWallet,
  ])
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

t('exactly 2% fee: seller 98%, feeWallet 2%, and rounding favours the seller', async () => {
  for (const amount of [10_000_000n, 999_999n, 33n, 1n]) {
    const auth = await baseAuth(h, { amount, period: 3600 })
    const signature = await h.sign(auth)

    const sellerBefore = await h.balance(h.seller)
    const feeBefore = await h.balance(h.feeWallet)
    const payerBefore = await h.balance(auth.payer)

    await h.charge(auth, signature)

    const fee = recurringFee(amount)
    assert.equal(await h.balance(h.seller) - sellerBefore, amount - fee, `net for ${amount}`)
    assert.equal(await h.balance(h.feeWallet) - feeBefore, fee, `fee for ${amount}`)
    assert.equal(payerBefore - (await h.balance(auth.payer)), amount, `debit for ${amount}`)
  }
})

t('zero amount is rejected outright', async () => {
  const auth = await baseAuth(h, { amount: 0n })
  assert.equal(await h.expectRevert(h.charge(auth, await h.sign(auth))), 'ZeroAmount')
})

// --- gas reimbursement -----------------------------------------------------------

t('relayer reimbursement works within both caps; buyer debit is exactly bounded', async () => {
  const auth = await baseAuth(h, { period: 3600, maxGasReimbursement: 30_000n })
  const signature = await h.sign(auth)

  const relayerBefore = await h.balance(h.relayer.account.address)
  const payerBefore = await h.balance(auth.payer)

  await h.charge(auth, signature, { gasReimbursement: 2_000n })

  assert.equal(await h.balance(h.relayer.account.address) - relayerBefore, 2_000n)
  assert.equal(payerBefore - (await h.balance(auth.payer)), auth.amount + 2_000n, 'amount + gas, nothing else')
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
  const payerBefore = await h.balance(auth.payer)

  // Attacker asks for the full signed cap. Charge succeeds - execution is public - but the
  // reimbursement is forced to zero, so the attacker pays gas for the privilege of paying the seller.
  const receipt = await h.charge(auth, signature, { from: h.attacker, gasReimbursement: 50_000n })
  assert.equal(receipt.status, 'success')

  assert.equal(await h.balance(h.attacker.account.address) - attackerBefore, 0n, 'attacker extracted nothing')
  assert.equal(payerBefore - (await h.balance(auth.payer)), auth.amount, 'payer debited the amount only')
})

// --- front-running ---------------------------------------------------------------

t('a public signature enables exactly the signed payment, nothing else', async () => {
  const auth = await baseAuth(h, { period: 3600 })
  const signature = await h.sign(auth) // consider it leaked

  const sellerBefore = await h.balance(h.seller)
  await h.charge(auth, signature, { from: h.attacker })

  // Funds went to the buyer-signed recipient regardless of who called.
  assert.equal(await h.balance(h.seller) - sellerBefore, auth.amount - recurringFee(auth.amount))

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
  await h.mint(h.payer.account.address, 100_000_000n, evil)
  await h.approve(h.payer, maxUint256, evil)

  const auth = await baseAuth(h, { token: evil, period: 3600 })
  const signature = await h.sign(auth)

  const evilAbi = JSON.parse(readFileSync(new URL('../../out/ReentrantToken.json', import.meta.url), 'utf8')).abi
  const arm = await h.admin.writeContract({
    address: evil,
    abi: evilAbi,
    functionName: 'arm',
    args: [h.recurring, abiAuth(auth), signature],
  })
  await h.chain.waitForTransactionReceipt({ hash: arm })

  // The inner re-entrant charge reverts on the guard, which reverts the whole outer charge.
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted')
  const id = await h.read<Hex>('subscriptionId', [auth])
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id]), 0n, 'state fully rolled back')
})

t('a false-returning token is treated as failure by SafeERC20, with rollback', async () => {
  const falsy = await h.deploy('FalseReturnToken')
  await h.mint(h.payer.account.address, 100_000_000n, falsy)
  await h.approve(h.payer, maxUint256, falsy)

  const abi = JSON.parse(readFileSync(new URL('../../out/FalseReturnToken.json', import.meta.url), 'utf8')).abi
  const set = await h.admin.writeContract({ address: falsy, abi, functionName: 'setFailTransfers', args: [true] })
  await h.chain.waitForTransactionReceipt({ hash: set })

  const auth = await baseAuth(h, { token: falsy, period: 3600 })
  const signature = await h.sign(auth)
  assert.equal(await h.expectRevert(h.charge(auth, signature)), 'reverted')

  const id = await h.read<Hex>('subscriptionId', [auth])
  assert.equal(await h.read<bigint>('lastChargedPeriodPlusOne', [id]), 0n)

  const unset = await h.admin.writeContract({ address: falsy, abi, functionName: 'setFailTransfers', args: [false] })
  await h.chain.waitForTransactionReceipt({ hash: unset })
  assert.equal((await h.charge(auth, signature)).status, 'success', 'recovers once the token behaves')
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
    readFileSync(new URL('../../out/P2FluxRecurring.json', import.meta.url), 'utf8'),
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
