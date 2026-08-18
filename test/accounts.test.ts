/**
 * Which accounts may authorize a recurring charge.
 *
 * The rule under test lives in `P2FluxRecurring._isAuthorized` and has three cases, because
 * OpenZeppelin's `SignatureChecker.isValidSignatureNow` gets one of them wrong for our purposes: it
 * branches on `code.length`, so an EIP-7702 delegated EOA - which HAS code - never gets its ECDSA
 * signature tried at all. A customer who upgrades their wallet after subscribing would have every
 * later charge rejected.
 *
 * So: EOA by ECDSA, delegated EOA by ECDSA or ERC-1271, deployed contract wallet by ERC-1271 ONLY,
 * and ERC-6492 wrappers refused before any of it. These tests pin each edge of that, including the
 * ones that must NOT widen: a deployed contract wallet is never authorized by a raw ECDSA signature.
 */
import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import {
  concat,
  encodeAbiParameters,
  maxUint256,
  parseSignature,
  serializeSignature,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { abiAuth, recurringAbi, recurringSubscriptionId } from '../src/recurring.js'
import { KEYS, baseAuth, startHarness, type Harness } from './_anvil.js'

const anvilInstalled = existsSync(`${homedir()}/.foundry/bin/anvil`)

let h: Harness

before(async () => {
  if (!anvilInstalled) return
  h = await startHarness()
  await h.mint(h.payer.account.address, 1_000_000_000n)
  await h.approve(h.payer)
})

after(() => h?.stop())

const t = (name: string, fn: () => Promise<void>) =>
  test(name, { skip: anvilInstalled ? false : 'anvil not installed (foundryup)' }, fn)

const ERC6492_MAGIC = '0x6492649264926492649264926492649264926492649264926492649264926492' as const

/** Fund a contract wallet and give it an allowance, by impersonating it the way anvil allows. */
async function fundAndApprove(walletContract: Address) {
  await h.mint(walletContract, 100_000_000n)
  await h.chain.request({ method: 'anvil_impersonateAccount' as never, params: [walletContract] as never })
  await h.chain.request({
    method: 'anvil_setBalance' as never,
    params: [walletContract, '0x1000000000000000000'] as never,
  })
  const { createWalletClient, http } = await import('viem')
  const impersonated = createWalletClient({ account: walletContract, chain: undefined, transport: http(h.rpc) })
  const hash = await impersonated.writeContract({
    address: h.token,
    abi: [
      {
        type: 'function',
        name: 'approve',
        stateMutability: 'nonpayable',
        inputs: [{ type: 'address' }, { type: 'uint256' }],
        outputs: [{ type: 'bool' }],
      },
    ],
    functionName: 'approve',
    args: [h.recurring, maxUint256],
    chain: null,
    account: walletContract,
  } as never)
  await h.chain.waitForTransactionReceipt({ hash })
  await h.chain.request({ method: 'anvil_stopImpersonatingAccount' as never, params: [walletContract] as never })
}

/** The contract's own answer, which is also what the API is required to gate on. */
const isValid = (auth: Awaited<ReturnType<typeof baseAuth>>, signature: Hex) =>
  h.chain.readContract({
    address: h.recurring,
    abi: recurringAbi,
    functionName: 'isValidAuthorization',
    args: [abiAuth(auth), signature],
  }) as Promise<boolean>

const signAsOwner = async (auth: Awaited<ReturnType<typeof baseAuth>>, key: Hex = KEYS.payer) => {
  const digest = recurringSubscriptionId(auth, h.chainId, h.recurring)
  return serializeSignature(parseSignature(await privateKeyToAccount(key).sign({ hash: digest })))
}

// --- deployed contract wallets: ERC-1271 is the only authority -----------------------------------

t('a deployed contract wallet is NOT authorized by a raw ECDSA signature', async () => {
  /* The narrow-exception test. `AlwaysValidWallet` would accept anything through ERC-1271, so this
   * uses a wallet that refuses, and signs with the key that deployed it. If the validator ever fell
   * back to ECDSA for deployed contracts, some contract wallet somewhere would be authorized by a
   * signature its own code rejected - a weaker rule than the one it opted into. */
  const walletContract = await h.deploy('WrongMagicWallet', [])
  await fundAndApprove(walletContract)

  const auth = await baseAuth(h, { payer: walletContract })
  const signature = await signAsOwner(auth)
  assert.equal(await isValid(auth, signature), false)
  await assert.rejects(() => h.charge(auth, signature))
})

t('ERC-1271 misbehaviour all fails closed: wrong magic, revert, empty and short returndata', async () => {
  for (const mock of ['WrongMagicWallet', 'RevertingWallet', 'EmptyReturnWallet', 'ShortReturnWallet']) {
    const walletContract = await h.deploy(mock, [])
    await fundAndApprove(walletContract)
    const auth = await baseAuth(h, { payer: walletContract })

    assert.equal(await isValid(auth, '0x1234'), false, `${mock} must not validate`)
    await assert.rejects(() => h.charge(auth, '0x1234'), `${mock} must not charge`)
  }
})

t('a validator that accepts everything charges only what was signed', async () => {
  /* The "malicious ERC-1271" case, and it is deliberately allowed. The wallet is authorizing its own
   * funds; the terms still bound the amount, the recipient and the once-per-period rule. */
  const walletContract = await h.deploy('AlwaysValidWallet', [])
  await fundAndApprove(walletContract)

  const auth = await baseAuth(h, { payer: walletContract })
  assert.equal(await isValid(auth, '0x'), true)
  const receipt = await h.charge(auth, '0x')
  assert.equal(receipt.status, 'success')

  // Still exactly one charge per period, even for a wallet that rubber-stamps signatures.
  await assert.rejects(() => h.charge(auth, '0x'))
})

t('a contract signature can stop being valid between periods', async () => {
  /* Why validation is re-asked on every charge rather than snapshotted at setup: for a contract
   * wallet, consent is revocable. Rotating owners or raising a threshold must stop collection. */
  const walletContract = await h.deploy('FlippableWallet', [])
  await fundAndApprove(walletContract)

  const auth = await baseAuth(h, { payer: walletContract })
  assert.equal((await h.charge(auth, '0x')).status, 'success')

  const hash = await h.admin.writeContract({
    address: walletContract,
    abi: [
      {
        type: 'function',
        name: 'setAccept',
        stateMutability: 'nonpayable',
        inputs: [{ type: 'bool' }],
        outputs: [],
      },
    ],
    functionName: 'setAccept',
    args: [false],
  })
  await h.chain.waitForTransactionReceipt({ hash })

  await h.travel(Number(auth.period) + 1)
  assert.equal(await isValid(auth, '0x'), false, 'the wallet withdrew consent')
  await assert.rejects(() => h.charge(auth, '0x'))
})

// --- ERC-6492 -------------------------------------------------------------------------------------

t('ERC-6492 wrapped signatures are refused, deployed payer or not', async () => {
  /* The wrapper carries deploy calldata for an account that does not exist yet. This contract will
   * not execute it, and an authorization replayed monthly must belong to a deployed account. */
  const wrapped = (inner: Hex) =>
    concat([
      encodeAbiParameters(
        [{ type: 'address' }, { type: 'bytes' }, { type: 'bytes' }],
        [h.recurring, '0x', inner],
      ),
      ERC6492_MAGIC,
    ])

  // An undeployed payer, and a deployed wallet that would otherwise accept anything.
  const undeployed = await baseAuth(h, { payer: '0x00000000000000000000000000000000deadbeef' as Address })
  assert.equal(await isValid(undeployed, wrapped('0x1234')), false)

  const walletContract = await h.deploy('AlwaysValidWallet', [])
  await fundAndApprove(walletContract)
  const deployed = await baseAuth(h, { payer: walletContract })
  assert.equal(await isValid(deployed, wrapped('0x1234')), false, 'refused even where 1271 would say yes')
  await assert.rejects(() => h.charge(deployed, wrapped('0x1234')))

  // The same inner signature, unwrapped, is fine - proving it is the wrapper that was refused.
  assert.equal(await isValid(deployed, '0x1234'), true)
})

// --- EIP-7702 --------------------------------------------------------------------------------------

t('EIP-7702: a delegated EOA still charges with its own ECDSA signature', async () => {
  /* The regression this whole change exists to prevent. A plain EOA subscribes, later delegates its
   * account, and must keep paying: under EIP-7702 the key still controls the account outright. */
  const account = privateKeyToAccount(KEYS.attacker) // any key with no other role here
  await h.mint(account.address, 1_000_000_000n)
  await h.approve(h.wallet(KEYS.attacker))

  const auth = await baseAuth(h, { payer: account.address.toLowerCase() as Address })
  const signature = await signAsOwner(auth, KEYS.attacker)

  // Works as an ordinary EOA first.
  assert.equal(await isValid(auth, signature), true)

  // Now delegate the account to a contract that does NOT implement ERC-1271.
  const delegate = await h.deploy('EmptyReturnWallet', [])
  await delegateTo(KEYS.attacker, delegate)

  const code = await h.chain.getCode({ address: account.address })
  assert.ok(code && code.startsWith('0xef0100'), 'anvil applied a real 7702 designator')
  assert.equal((code!.length - 2) / 2, 23, 'designator is 23 bytes')

  // Under the old library rule this would now be false forever.
  assert.equal(await isValid(auth, signature), true, 'the key still authorizes its own account')
  assert.equal((await h.charge(auth, signature)).status, 'success')
})

t('EIP-7702: a delegate implementing ERC-1271 also authorizes', async () => {
  const account = privateKeyToAccount(KEYS.feeWallet)
  await h.mint(account.address, 1_000_000_000n)
  await h.approve(h.wallet(KEYS.feeWallet))

  const delegate = await h.deploy('AlwaysValidWallet', [])
  await delegateTo(KEYS.feeWallet, delegate)

  const auth = await baseAuth(h, { payer: account.address.toLowerCase() as Address })
  // Not a valid ECDSA signature for this account - so only the delegate's ERC-1271 can accept it.
  assert.equal(await isValid(auth, '0x'), true)
  assert.equal((await h.charge(auth, '0x')).status, 'success')
})

/** Sign and submit a real EIP-7702 authorization, so the account gets a genuine designator. */
async function delegateTo(key: Hex, delegate: Address) {
  const account = privateKeyToAccount(key)
  const { createWalletClient, http } = await import('viem')
  const { foundry } = await import('viem/chains')
  const client = createWalletClient({ account, chain: foundry, transport: http(h.rpc) })

  const authorization = await client.signAuthorization({ account, contractAddress: delegate, executor: 'self' })
  /* Sent to a plain EOA, not to the account itself: a self-call would execute the freshly delegated
   * code with empty calldata, which reverts on any delegate without a fallback. The authorization
   * applies regardless of the transaction's target. */
  const hash = await client.sendTransaction({ authorizationList: [authorization], to: h.seller })
  await h.chain.waitForTransactionReceipt({ hash })
}
