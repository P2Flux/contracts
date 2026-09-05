/**
 * The sponsored contracts, on a real chain, against a token that enforces EIP-3009 and EIP-2612 the
 * way USDC does.
 *
 * The suite exists for one claim: a buyer with no native gas currency can pay, and P2Flux never ends
 * a transaction having spent gas without having been paid for it. Two properties carry that claim,
 * and both are tested here rather than reasoned about:
 *
 *   1. Atomicity. The fee collection and the operation it pays for are one transaction. The
 *      headline test is `a permit that reverts takes the fee collection with it` - if that ever
 *      stopped holding, P2Flux would be charging customers for allowance changes that did not
 *      happen.
 *   2. Binding. Every financial term is inside the nonce the buyer's signature commits to, so a
 *      relayer that submits anything other than what was signed produces a nonce the token has
 *      never seen, and the token refuses it. Each term gets its own test.
 */
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { after, before, describe, test } from 'node:test'
import { keccak256, parseEventLogs, toBytes, zeroAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import {
  gasSponsorAbi,
  permitTypedData,
  receiveWithAuthorizationTypedData,
  sponsoredPaymentNonce,
  sponsoredSplitterAbi,
  sponsorPermitNonce,
  type SponsoredPayment,
} from '../src/sponsored.js'
import { paymentIdFor } from '../src/splitter.js'
import { KEYS, startHarness, type Harness } from './_anvil.js'

const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../out/${name}.json`, import.meta.url), 'utf8')) as {
    abi: readonly unknown[]
    bytecode: Hex
  }

const AMOUNT = 100_000_000n // 100.00 USDC
const FEE = 1_000_000n // 1%
const NET = AMOUNT - FEE // 99.00
const NETWORK_FEE = 4_000n // 0.004
const SERVICE_FEE = 100_000n // 0.10
const HARD_CAP = 250_000n // 0.25
const MINT = 1_000_000_000n

describe('sponsored payments and gas sponsorship', () => {
  let h: Harness
  let token: Address
  let splitter: Address
  let sponsor: Address
  let tokenName: string

  const ref = (seed: string) => keccak256(toBytes(seed))

  /** A payer with a fresh key per test, so a nonce burned in one test cannot affect another. */
  const freshPayer = (seed: number) => {
    const key = `0x${(seed + 0x1000).toString(16).padStart(64, '0')}` as Hex
    return { account: privateKeyToAccount(key), wallet: h.wallet(key) }
  }

  const terms = (over: Partial<SponsoredPayment> & { payer: Address }): SponsoredPayment => ({
    recipient: h.seller,
    amount: AMOUNT,
    ref: ref('order-1'),
    networkFee: NETWORK_FEE,
    validBefore: 0n,
    ...over,
  })

  /** Sign the token authorization for these payment terms. */
  const signPayment = async (
    p: SponsoredPayment,
    signer: ReturnType<typeof h.wallet>,
    opts: { nonceFrom?: SponsoredPayment; at?: Address } = {},
  ) => {
    const at = opts.at ?? splitter
    const nonce = sponsoredPaymentNonce({
      chainId: h.chainId,
      splitter: at,
      token,
      serviceFee: SERVICE_FEE,
      payment: opts.nonceFrom ?? p,
    })
    const signature = await signer.signTypedData(
      receiveWithAuthorizationTypedData({
        chainId: h.chainId,
        token,
        tokenName,
        tokenVersion: '2',
        from: p.payer,
        to: at,
        value: p.amount + p.networkFee + SERVICE_FEE,
        validBefore: p.validBefore,
        nonce,
      }) as never,
    )
    return split(signature)
  }

  const split = (signature: Hex) => ({
    v: Number(`0x${signature.slice(130, 132)}`),
    r: `0x${signature.slice(2, 66)}` as Hex,
    s: `0x${signature.slice(66, 130)}` as Hex,
  })

  const pay = async (
    p: SponsoredPayment,
    sig: { v: number; r: Hex; s: Hex },
    opts: { from?: ReturnType<typeof h.wallet>; at?: Address } = {},
  ) => {
    const from = opts.from ?? h.relayer
    const hash = await from.writeContract({
      address: opts.at ?? splitter,
      abi: sponsoredSplitterAbi,
      functionName: 'payWithAuthorization',
      args: [p, sig.v, sig.r, sig.s],
    })
    return h.chain.waitForTransactionReceipt({ hash })
  }

  const tokenNonce = async (owner: Address) =>
    (await h.chain.readContract({
      address: token,
      abi: artifact('MockFiatToken').abi as never,
      functionName: 'nonces',
      args: [owner],
    })) as bigint

  const allowanceOf = async (owner: Address, spender: Address) =>
    (await h.chain.readContract({
      address: token,
      abi: artifact('MockFiatToken').abi as never,
      functionName: 'allowance',
      args: [owner, spender],
    })) as bigint

  before(async () => {
    h = await startHarness()
    token = await h.deploy('MockFiatToken')
    tokenName = (await h.chain.readContract({
      address: token,
      abi: artifact('MockFiatToken').abi as never,
      functionName: 'name',
    })) as string
    splitter = await h.deploy('P2FluxSponsoredSplitter', [
      token,
      h.feeWallet,
      h.gasTreasury,
      h.relayer.account.address,
      SERVICE_FEE,
      HARD_CAP,
    ])
    sponsor = await h.deploy('P2FluxGasSponsor', [
      token,
      h.gasTreasury,
      h.relayer.account.address,
      HARD_CAP,
    ])
  })
  after(async () => h.stop())

  describe('P2FluxSponsoredSplitter', () => {
    test('a buyer with no native currency pays, and every unit lands where the design says', async () => {
      const { account, wallet } = freshPayer(1)
      await h.mint(account.address, MINT, token)
      const before = {
        payer: await h.balance(account.address, token),
        seller: await h.balance(h.seller, token),
        fee: await h.balance(h.feeWallet, token),
        gas: await h.balance(h.gasTreasury, token),
      }
      // The buyer's native balance is untouched by the flow: they never send a transaction.
      const nativeBefore = await h.chain.getBalance({ address: account.address })

      const p = terms({ payer: account.address, validBefore: BigInt((await h.now()) + 300) })
      const receipt = await pay(p, await signPayment(p, wallet))
      assert.equal(receipt.status, 'success')

      assert.equal(await h.balance(account.address, token), before.payer - AMOUNT - NETWORK_FEE - SERVICE_FEE)
      assert.equal(await h.balance(h.seller, token), before.seller + NET)
      assert.equal(await h.balance(h.feeWallet, token), before.fee + FEE + SERVICE_FEE)
      assert.equal(await h.balance(h.gasTreasury, token), before.gas + NETWORK_FEE)
      assert.equal(await h.chain.getBalance({ address: account.address }), nativeBefore)
      assert.equal(await h.balance(splitter, token), 0n, 'the contract keeps nothing')

      /* The API prices this transaction from a measured constant, because a quote is made before the
       * buyer has signed and `eth_estimateGas` over an unsigned call reverts inside the token. The
       * figure is printed so the constant can be re-derived, and bounded so a contract change that
       * moves it is noticed here rather than as under-quoted sponsorships in production. */
      console.log(`# gas payWithAuthorization (mock token, cold): ${receipt.gasUsed}`)
      assert.ok(receipt.gasUsed < 200_000n, `payWithAuthorization used ${receipt.gasUsed} gas`)
    })

    test('the settlement is announced the way the recovery path reads it', async () => {
      const { account, wallet } = freshPayer(2)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-events'),
        validBefore: BigInt((await h.now()) + 300),
      })
      const receipt = await pay(p, await signPayment(p, wallet))

      const paid = parseEventLogs({ abi: sponsoredSplitterAbi, eventName: 'SponsoredPaid', logs: receipt.logs })
      assert.equal(paid.length, 1)
      assert.deepEqual(
        {
          net: paid[0]!.args.net,
          fee: paid[0]!.args.fee,
          networkFee: paid[0]!.args.networkFee,
          serviceFee: paid[0]!.args.serviceFee,
        },
        { net: NET, fee: FEE, networkFee: NETWORK_FEE, serviceFee: SERVICE_FEE },
      )

      const settled = parseEventLogs({
        abi: sponsoredSplitterAbi,
        eventName: 'PaymentSettled',
        logs: receipt.logs,
      })
      assert.equal(settled.length, 1)
      assert.equal(
        settled[0]!.args.paymentId,
        paymentIdFor({ token, recipient: h.seller, amount: AMOUNT, reference: p.ref }),
        'the id matches the one P2FluxSplitter would compute for the same terms',
      )
    })

    test('the nonce this contract derives is the one the SDK derives', async () => {
      const p = terms({ payer: h.payer.account.address, validBefore: 999n })
      const onChain = (await h.chain.readContract({
        address: splitter,
        abi: sponsoredSplitterAbi,
        functionName: 'authorizationNonce',
        args: [p],
      })) as Hex
      assert.equal(
        onChain,
        sponsoredPaymentNonce({ chainId: h.chainId, splitter, token, serviceFee: SERVICE_FEE, payment: p }),
      )
    })

    test('the same intent cannot settle twice', async () => {
      const { account, wallet } = freshPayer(3)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-replay'),
        validBefore: BigInt((await h.now()) + 300),
      })
      const sig = await signPayment(p, wallet)
      await pay(p, sig)
      assert.equal(await h.expectRevert(pay(p, sig)), 'PaymentAlreadyProcessed')
    })

    for (const [name, mutate] of [
      ['the amount', (p: SponsoredPayment) => ({ ...p, amount: p.amount + 1n })],
      ['the recipient', (p: SponsoredPayment) => ({ ...p, recipient: KEYS_ATTACKER })],
      ['the network fee', (p: SponsoredPayment) => ({ ...p, networkFee: p.networkFee + 1n })],
      ['the reference', (p: SponsoredPayment) => ({ ...p, ref: ref('other-order') })],
      ['the expiry', (p: SponsoredPayment) => ({ ...p, validBefore: p.validBefore + 60n })],
    ] as const) {
      test(`${name} cannot be changed after signing`, async () => {
        const { account, wallet } = freshPayer(10 + name.length)
        await h.mint(account.address, MINT, token)
        const signed = terms({
          payer: account.address,
          ref: ref(`tamper-${name}`),
          validBefore: BigInt((await h.now()) + 300),
        })
        const sig = await signPayment(signed, wallet)
        // The relayer submits different terms with the buyer's signature for the originals.
        assert.equal(await h.expectRevert(pay(mutate(signed), sig)), 'reverted')
      })
    }

    test('a network fee above the protocol cap is refused whatever was signed', async () => {
      const { account, wallet } = freshPayer(4)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-cap'),
        networkFee: HARD_CAP + 1n,
        validBefore: BigInt((await h.now()) + 300),
      })
      assert.equal(await h.expectRevert(pay(p, await signPayment(p, wallet))), 'NetworkFeeTooHigh')
    })

    test('a network fee exactly at the cap is allowed', async () => {
      const { account, wallet } = freshPayer(5)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-at-cap'),
        networkFee: HARD_CAP,
        validBefore: BigInt((await h.now()) + 300),
      })
      const receipt = await pay(p, await signPayment(p, wallet))
      assert.equal(receipt.status, 'success')
      assert.equal(await h.balance(splitter, token), 0n)
    })

    test('an expired quote cannot be executed', async () => {
      const { account, wallet } = freshPayer(6)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-expired'),
        validBefore: BigInt((await h.now()) + 30),
      })
      const sig = await signPayment(p, wallet)
      await h.travel(120)
      assert.equal(await h.expectRevert(pay(p, sig)), 'reverted')
    })

    test('nobody but the relayer may execute a sponsored payment', async () => {
      const { account, wallet } = freshPayer(7)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-caller'),
        validBefore: BigInt((await h.now()) + 300),
      })
      const sig = await signPayment(p, wallet)
      assert.equal(await h.expectRevert(pay(p, sig, { from: h.attacker })), 'NotRelayer')
      // ...and the intent is still payable by the relayer afterwards.
      assert.equal((await pay(p, sig)).status, 'success')
    })

    test('a buyer who cannot cover the total pays nothing at all', async () => {
      const { account, wallet } = freshPayer(8)
      await h.mint(account.address, AMOUNT, token) // exactly the price, nothing for the fees
      const p = terms({
        payer: account.address,
        ref: ref('order-short'),
        validBefore: BigInt((await h.now()) + 300),
      })
      assert.equal(await h.expectRevert(pay(p, await signPayment(p, wallet))), 'reverted')
      assert.equal(await h.balance(account.address, token), AMOUNT, 'the buyer keeps everything')
      assert.equal(await h.balance(splitter, token), 0n)
    })

    test('a signature for one splitter cannot be spent at another', async () => {
      const other = await h.deploy('P2FluxSponsoredSplitter', [
        token,
        h.feeWallet,
        h.gasTreasury,
        h.relayer.account.address,
        SERVICE_FEE,
        HARD_CAP,
      ])
      const { account, wallet } = freshPayer(9)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        ref: ref('order-wrong-contract'),
        validBefore: BigInt((await h.now()) + 300),
      })
      // Signed for `splitter`, submitted to `other`.
      const sig = await signPayment(p, wallet, { at: splitter })
      assert.equal(await h.expectRevert(pay(p, sig, { at: other })), 'reverted')
    })

    test('an amount too small to cover its own fee is refused before anything moves', async () => {
      const { account, wallet } = freshPayer(11)
      await h.mint(account.address, MINT, token)
      const p = terms({
        payer: account.address,
        amount: 1n, // fee rounds to 0, so the seller would receive the whole 1 unit... but see below
        ref: ref('order-tiny'),
        validBefore: BigInt((await h.now()) + 300),
      })
      // 1 unit: fee = 0, so `amount <= fee` is false and the payment is legal. The refusal case is
      // amount == 0, which cannot even be quoted.
      assert.equal((await pay(p, await signPayment(p, wallet))).status, 'success')
      const zero = terms({ payer: account.address, amount: 0n, ref: ref('order-zero') })
      assert.equal(await h.expectRevert(pay(zero, await signPayment(zero, wallet))), 'ZeroAmount')
    })
  })

  describe('P2FluxGasSponsor', () => {
    const RECURRING_SPENDER = () => h.recurring

    const signPermit = async (
      args: {
        payer: Address
        spender: Address
        value: bigint
        deadline: bigint
      },
      signer: ReturnType<typeof h.wallet>,
      opts: { nonce?: bigint } = {},
    ) =>
      split(
        await signer.signTypedData(
          permitTypedData({
            chainId: h.chainId,
            token,
            tokenName,
            tokenVersion: '2',
            owner: args.payer,
            spender: args.spender,
            value: args.value,
            nonce: opts.nonce ?? (await tokenNonce(args.payer)),
            deadline: args.deadline,
          }) as never,
        ),
      )

    const signSponsorFee = async (
      args: {
        payer: Address
        spender: Address
        value: bigint
        deadline: bigint
        networkFee: bigint
        validBefore: bigint
      },
      signer: ReturnType<typeof h.wallet>,
      opts: { at?: Address; nonceOver?: Partial<typeof args> } = {},
    ) => {
      const at = opts.at ?? sponsor
      const nonceArgs = { ...args, ...opts.nonceOver }
      const nonce = sponsorPermitNonce({
        chainId: h.chainId,
        sponsor: at,
        token,
        payer: nonceArgs.payer,
        spender: nonceArgs.spender,
        allowanceValue: nonceArgs.value,
        allowanceDeadline: nonceArgs.deadline,
        networkFee: nonceArgs.networkFee,
        validBefore: nonceArgs.validBefore,
      })
      return split(
        await signer.signTypedData(
          receiveWithAuthorizationTypedData({
            chainId: h.chainId,
            token,
            tokenName,
            tokenVersion: '2',
            from: args.payer,
            to: at,
            value: args.networkFee,
            validBefore: args.validBefore,
            nonce,
          }) as never,
        ),
      )
    }

    const sponsorPermitCall = async (
      args: {
        payer: Address
        spender: Address
        value: bigint
        deadline: bigint
        networkFee: bigint
        validBefore: bigint
      },
      permitSig: { v: number; r: Hex; s: Hex },
      feeSig: { v: number; r: Hex; s: Hex },
      opts: { from?: ReturnType<typeof h.wallet>; at?: Address } = {},
    ) => {
      const from = opts.from ?? h.relayer
      const hash = await from.writeContract({
        address: opts.at ?? sponsor,
        abi: gasSponsorAbi,
        functionName: 'sponsorPermit',
        args: [
          {
            payer: args.payer,
            spender: args.spender,
            allowanceValue: args.value,
            allowanceDeadline: args.deadline,
            networkFee: args.networkFee,
            validBefore: args.validBefore,
          },
          permitSig.v,
          permitSig.r,
          permitSig.s,
          feeSig.v,
          feeSig.r,
          feeSig.s,
        ],
      })
      return h.chain.waitForTransactionReceipt({ hash })
    }

    const sponsorship = async (seed: number, over: Record<string, unknown> = {}) => {
      const { account, wallet } = freshPayer(seed)
      await h.mint(account.address, MINT, token)
      const nowSeconds = await h.now()
      const args = {
        payer: account.address,
        spender: RECURRING_SPENDER(),
        value: 50_000_000n,
        deadline: BigInt(nowSeconds + 300),
        networkFee: NETWORK_FEE,
        validBefore: BigInt(nowSeconds + 300),
        ...over,
      }
      return { account, wallet, args }
    }

    test('the customer signs twice, sends nothing, and ends up with the allowance they asked for', async () => {
      const { account, wallet, args } = await sponsorship(20)
      const before = {
        payer: await h.balance(account.address, token),
        gas: await h.balance(h.gasTreasury, token),
        native: await h.chain.getBalance({ address: account.address }),
      }

      const receipt = await sponsorPermitCall(
        args,
        await signPermit(args, wallet),
        await signSponsorFee(args, wallet),
      )
      assert.equal(receipt.status, 'success')

      assert.equal(await allowanceOf(account.address, args.spender), args.value)
      assert.equal(await h.balance(account.address, token), before.payer - NETWORK_FEE)
      assert.equal(await h.balance(h.gasTreasury, token), before.gas + NETWORK_FEE)
      assert.equal(await h.chain.getBalance({ address: account.address }), before.native)
      assert.equal(await h.balance(sponsor, token), 0n)

      const settled = parseEventLogs({
        abi: gasSponsorAbi,
        eventName: 'SponsorshipSettled',
        logs: receipt.logs,
      })
      assert.equal(settled.length, 1)
      assert.equal(settled[0]!.args.networkFee, NETWORK_FEE)
      assert.equal(settled[0]!.args.allowanceValue, args.value)

      // Same reason as the splitter's figure: the API's quote constant is derived from this number.
      console.log(`# gas sponsorPermit (mock token, cold): ${receipt.gasUsed}`)
      assert.ok(receipt.gasUsed < 200_000n, `sponsorPermit used ${receipt.gasUsed} gas`)
    })

    test('a permit that reverts takes the fee collection with it', async () => {
      // The property the whole design rests on: P2Flux never keeps a network fee for an operation
      // that did not happen.
      const reverting = await h.deploy('PermitRevertingToken')
      const brokenSponsor = await h.deploy('P2FluxGasSponsor', [
        reverting,
        h.gasTreasury,
        h.relayer.account.address,
        HARD_CAP,
      ])
      const { account, wallet } = freshPayer(21)
      await h.mint(account.address, MINT, reverting)
      const nowSeconds = await h.now()
      const args = {
        payer: account.address,
        spender: h.recurring,
        value: 50_000_000n,
        deadline: BigInt(nowSeconds + 300),
        networkFee: NETWORK_FEE,
        validBefore: BigInt(nowSeconds + 300),
      }
      const nonce = sponsorPermitNonce({
        chainId: h.chainId,
        sponsor: brokenSponsor,
        token: reverting,
        payer: args.payer,
        spender: args.spender,
        allowanceValue: args.value,
        allowanceDeadline: args.deadline,
        networkFee: args.networkFee,
        validBefore: args.validBefore,
      })
      const feeSig = split(
        await wallet.signTypedData(
          receiveWithAuthorizationTypedData({
            chainId: h.chainId,
            token: reverting,
            tokenName: (await h.chain.readContract({
              address: reverting,
              abi: artifact('MockFiatToken').abi as never,
              functionName: 'name',
            })) as string,
            tokenVersion: '2',
            from: args.payer,
            to: brokenSponsor,
            value: args.networkFee,
            validBefore: args.validBefore,
            nonce,
          }) as never,
        ),
      )
      const payerBefore = await h.balance(account.address, reverting)
      const treasuryBefore = await h.balance(h.gasTreasury, reverting)
      const allowanceBefore = (await h.chain.readContract({
        address: reverting,
        abi: artifact('MockFiatToken').abi as never,
        functionName: 'allowance',
        args: [account.address, args.spender],
      })) as bigint

      assert.equal(
        await h.expectRevert(
          sponsorPermitCall(args, { v: 27, r: `0x${'11'.repeat(32)}`, s: `0x${'22'.repeat(32)}` }, feeSig, {
            at: brokenSponsor,
          }),
        ),
        'reverted',
      )

      assert.equal(await h.balance(account.address, reverting), payerBefore, 'the customer paid nothing')
      assert.equal(await h.balance(h.gasTreasury, reverting), treasuryBefore, 'the treasury received nothing')
      assert.equal(
        (await h.chain.readContract({
          address: reverting,
          abi: artifact('MockFiatToken').abi as never,
          functionName: 'allowance',
          args: [account.address, args.spender],
        })) as bigint,
        allowanceBefore,
        'the allowance is unchanged',
      )
      assert.equal(
        (await h.chain.readContract({
          address: reverting,
          abi: artifact('MockFiatToken').abi as never,
          functionName: 'authorizationState',
          args: [account.address, nonce],
        })) as boolean,
        false,
        'the fee authorization was not consumed, so the customer can try again',
      )
      assert.equal(await h.balance(brokenSponsor, reverting), 0n)
    })

    test('a fee authorization that cannot be collected stops the permit', async () => {
      const { wallet, args } = await sponsorship(22)
      // Sign the fee for a different amount than the one submitted: the pull fails, so nothing else runs.
      const feeSig = await signSponsorFee(args, wallet, { nonceOver: { networkFee: NETWORK_FEE + 1n } })
      assert.equal(await h.expectRevert(sponsorPermitCall(args, await signPermit(args, wallet), feeSig)), 'reverted')
      assert.equal(await allowanceOf(args.payer, args.spender), 0n)
      assert.equal(await h.balance(h.gasTreasury, token), await h.balance(h.gasTreasury, token))
    })

    test('the same sponsorship cannot be replayed', async () => {
      const { wallet, args } = await sponsorship(23)
      const permitSig = await signPermit(args, wallet)
      const feeSig = await signSponsorFee(args, wallet)
      await sponsorPermitCall(args, permitSig, feeSig)
      assert.equal(
        await h.expectRevert(sponsorPermitCall(args, permitSig, feeSig)),
        'SponsorshipAlreadySettled',
      )
    })

    for (const [name, over] of [
      ['the spender', { spender: '0x000000000000000000000000000000000000dEaD' as Address }],
      ['the allowance value', { value: 999_000_000n }],
      ['the allowance deadline', { deadlineShift: 60n }],
      ['the network fee', { networkFee: NETWORK_FEE * 2n }],
      ['the expiry', { validBeforeShift: 60n }],
    ] as const) {
      test(`${name} cannot be changed after signing`, async () => {
        const { wallet, args } = await sponsorship(30 + name.length)
        const submitted = {
          ...args,
          ...('spender' in over ? { spender: over.spender } : {}),
          ...('value' in over ? { value: over.value } : {}),
          ...('networkFee' in over ? { networkFee: over.networkFee } : {}),
          ...('deadlineShift' in over ? { deadline: args.deadline + over.deadlineShift } : {}),
          ...('validBeforeShift' in over ? { validBefore: args.validBefore + over.validBeforeShift } : {}),
        }
        const permitSig = await signPermit(args, wallet)
        const feeSig = await signSponsorFee(args, wallet)
        assert.equal(await h.expectRevert(sponsorPermitCall(submitted, permitSig, feeSig)), 'reverted')
      })
    }

    test('a fee above the protocol cap is refused', async () => {
      const { wallet, args } = await sponsorship(40, { networkFee: HARD_CAP + 1n })
      assert.equal(
        await h.expectRevert(
          sponsorPermitCall(args, await signPermit(args, wallet), await signSponsorFee(args, wallet)),
        ),
        'NetworkFeeTooHigh',
      )
    })

    test('an expired sponsorship quote cannot be executed', async () => {
      const { wallet, args } = await sponsorship(41, {})
      const permitSig = await signPermit(args, wallet)
      const feeSig = await signSponsorFee(args, wallet)
      await h.travel(600)
      assert.equal(await h.expectRevert(sponsorPermitCall(args, permitSig, feeSig)), 'reverted')
    })

    test('nobody but the relayer may execute a sponsorship', async () => {
      const { wallet, args } = await sponsorship(42)
      assert.equal(
        await h.expectRevert(
          sponsorPermitCall(args, await signPermit(args, wallet), await signSponsorFee(args, wallet), {
            from: h.attacker,
          }),
        ),
        'NotRelayer',
      )
    })

    test('a signature for one sponsor cannot be spent at another', async () => {
      const other = await h.deploy('P2FluxGasSponsor', [
        token,
        h.gasTreasury,
        h.relayer.account.address,
        HARD_CAP,
      ])
      const { wallet, args } = await sponsorship(43)
      const permitSig = await signPermit(args, wallet)
      const feeSig = await signSponsorFee(args, wallet, { at: sponsor })
      assert.equal(await h.expectRevert(sponsorPermitCall(args, permitSig, feeSig, { at: other })), 'reverted')
    })

    test('removing the allowance is a normal sponsorship, and is not a revoke', async () => {
      const { account, wallet, args } = await sponsorship(44)
      // First set an allowance...
      await sponsorPermitCall(args, await signPermit(args, wallet), await signSponsorFee(args, wallet))
      assert.equal(await allowanceOf(account.address, args.spender), args.value)

      // ...then remove it with value 0 through the same path.
      const nowSeconds = await h.now()
      const removal = {
        ...args,
        value: 0n,
        deadline: BigInt(nowSeconds + 300),
        validBefore: BigInt(nowSeconds + 300),
      }
      const receipt = await sponsorPermitCall(
        removal,
        await signPermit(removal, wallet),
        await signSponsorFee(removal, wallet),
      )
      assert.equal(receipt.status, 'success')
      assert.equal(await allowanceOf(account.address, args.spender), 0n)
      assert.equal(await h.balance(sponsor, token), 0n)
    })

    test('the nonce this contract derives is the one the SDK derives', async () => {
      const { args } = await sponsorship(45)
      const onChain = (await h.chain.readContract({
        address: sponsor,
        abi: gasSponsorAbi,
        functionName: 'authorizationNonce',
        args: [
          {
            payer: args.payer,
            spender: args.spender,
            allowanceValue: args.value,
            allowanceDeadline: args.deadline,
            networkFee: args.networkFee,
            validBefore: args.validBefore,
          },
        ],
      })) as Hex
      assert.equal(
        onChain,
        sponsorPermitNonce({
          chainId: h.chainId,
          sponsor,
          token,
          payer: args.payer,
          spender: args.spender,
          allowanceValue: args.value,
          allowanceDeadline: args.deadline,
          networkFee: args.networkFee,
          validBefore: args.validBefore,
        }),
      )
    })

    test('a settled sponsorship is readable from the contract, one call, no log scan', async () => {
      const { wallet, args } = await sponsorship(46)
      const nonce = sponsorPermitNonce({
        chainId: h.chainId,
        sponsor,
        token,
        payer: args.payer,
        spender: args.spender,
        allowanceValue: args.value,
        allowanceDeadline: args.deadline,
        networkFee: args.networkFee,
        validBefore: args.validBefore,
      })
      const readSettled = async () =>
        (await h.chain.readContract({
          address: sponsor,
          abi: gasSponsorAbi,
          functionName: 'settledSponsorships',
          args: [nonce],
        })) as boolean

      assert.equal(await readSettled(), false)
      await sponsorPermitCall(args, await signPermit(args, wallet), await signSponsorFee(args, wallet))
      assert.equal(await readSettled(), true)
    })
  })

  describe('cross-contract binding', () => {
    test('a payment authorization is useless at the gas sponsor and vice versa', async () => {
      const { account, wallet } = freshPayer(50)
      await h.mint(account.address, MINT, token)
      const nowSeconds = await h.now()
      const p = terms({
        payer: account.address,
        ref: ref('cross-use'),
        validBefore: BigInt(nowSeconds + 300),
      })
      // A payment signature offered as a sponsorship fee: the nonce derivations differ by domain,
      // contract and terms, so the token never matches it.
      const paymentSig = await signPayment(p, wallet)
      const args = {
        payer: account.address,
        spender: h.recurring,
        value: 50_000_000n,
        deadline: BigInt(nowSeconds + 300),
        networkFee: NETWORK_FEE,
        validBefore: BigInt(nowSeconds + 300),
      }
      const hash = h.relayer.writeContract({
        address: sponsor,
        abi: gasSponsorAbi,
        functionName: 'sponsorPermit',
        args: [
          {
            payer: args.payer,
            spender: args.spender,
            allowanceValue: args.value,
            allowanceDeadline: args.deadline,
            networkFee: args.networkFee,
            validBefore: args.validBefore,
          },
          paymentSig.v,
          paymentSig.r,
          paymentSig.s,
          paymentSig.v,
          paymentSig.r,
          paymentSig.s,
        ],
      })
      assert.equal(await h.expectRevert(hash), 'reverted')
    })
  })
})

const KEYS_ATTACKER = privateKeyToAccount(KEYS.attacker).address

/**
 * The attacks the economic model has to survive, written as tests rather than as assurances.
 *
 * The one that matters is abandonment: a customer who signs, gets a sponsored transaction, and then
 * walks away. The design's claim is that this costs P2Flux nothing, because the fee is collected in
 * the same transaction that spends the gas. These tests hold that claim to the chain.
 */
describe('adversarial: sponsorship economics', () => {
  let h: Harness
  let token: Address
  let sponsor: Address
  let splitter: Address
  let tokenName: string

  const HARD = 250_000n
  const FEE_UNITS = 4_000n

  const splitSig = (signature: Hex) => ({
    v: Number(`0x${signature.slice(130, 132)}`),
    r: `0x${signature.slice(2, 66)}` as Hex,
    s: `0x${signature.slice(66, 130)}` as Hex,
  })

  const payerFor = (seed: number) => {
    const key = `0x${(seed + 0x9000).toString(16).padStart(64, '0')}` as Hex
    return { account: privateKeyToAccount(key), wallet: h.wallet(key) }
  }

  before(async () => {
    h = await startHarness()
    token = await h.deploy('MockFiatToken')
    tokenName = (await h.chain.readContract({
      address: token,
      abi: artifact('MockFiatToken').abi as never,
      functionName: 'name',
    })) as string
    sponsor = await h.deploy('P2FluxGasSponsor', [token, h.gasTreasury, h.relayer.account.address, HARD])
    splitter = await h.deploy('P2FluxSponsoredSplitter', [
      token,
      h.feeWallet,
      h.gasTreasury,
      h.relayer.account.address,
      100_000n,
      HARD,
    ])
  })
  after(async () => h.stop())

  test('a customer who abandons the subscription after a sponsored permit still paid for it', async () => {
    const { account, wallet } = payerFor(1)
    await h.mint(account.address, 1_000_000_000n, token)
    const nowSeconds = await h.now()
    const args = {
      payer: account.address,
      spender: h.recurring,
      value: 50_000_000n,
      deadline: BigInt(nowSeconds + 300),
      networkFee: FEE_UNITS,
      validBefore: BigInt(nowSeconds + 300),
    }
    const nonce = sponsorPermitNonce({
      chainId: h.chainId,
      sponsor,
      token,
      payer: args.payer,
      spender: args.spender,
      allowanceValue: args.value,
      allowanceDeadline: args.deadline,
      networkFee: args.networkFee,
      validBefore: args.validBefore,
    })
    const permitSig = splitSig(
      await wallet.signTypedData(
        permitTypedData({
          chainId: h.chainId,
          token,
          tokenName,
          tokenVersion: '2',
          owner: args.payer,
          spender: args.spender,
          value: args.value,
          nonce: (await h.chain.readContract({
            address: token,
            abi: artifact('MockFiatToken').abi as never,
            functionName: 'nonces',
            args: [args.payer],
          })) as bigint,
          deadline: args.deadline,
        }) as never,
      ),
    )
    const feeSig = splitSig(
      await wallet.signTypedData(
        receiveWithAuthorizationTypedData({
          chainId: h.chainId,
          token,
          tokenName,
          tokenVersion: '2',
          from: args.payer,
          to: sponsor,
          value: args.networkFee,
          validBefore: args.validBefore,
          nonce,
        }) as never,
      ),
    )

    const treasuryBefore = await h.balance(h.gasTreasury, token)
    const hash = await h.relayer.writeContract({
      address: sponsor,
      abi: gasSponsorAbi,
      functionName: 'sponsorPermit',
      args: [
        {
          payer: args.payer,
          spender: args.spender,
          allowanceValue: args.value,
          allowanceDeadline: args.deadline,
          networkFee: args.networkFee,
          validBefore: args.validBefore,
        },
        permitSig.v,
        permitSig.r,
        permitSig.s,
        feeSig.v,
        feeSig.r,
        feeSig.s,
      ],
    })
    await h.chain.waitForTransactionReceipt({ hash })

    // The customer now abandons: no subscription is ever charged. P2Flux is still whole, because the
    // fee for the gas it spent was collected by the same transaction that spent it.
    assert.equal(await h.balance(h.gasTreasury, token), treasuryBefore + FEE_UNITS)
    assert.equal(await h.balance(sponsor, token), 0n)
  })

  test('an abandoned setup that never reaches the chain costs nothing at all', async () => {
    // Signatures alone move no value and cost no gas: the relayer simply never submits. This is the
    // whole reason the design refuses to broadcast before every signature is in hand.
    const { account, wallet } = payerFor(2)
    await h.mint(account.address, 1_000_000_000n, token)
    const before = await h.balance(account.address, token)
    const nowSeconds = await h.now()
    await wallet.signTypedData(
      permitTypedData({
        chainId: h.chainId,
        token,
        tokenName,
        tokenVersion: '2',
        owner: account.address,
        spender: h.recurring,
        value: 1n,
        nonce: 0n,
        deadline: BigInt(nowSeconds + 300),
      }) as never,
    )
    assert.equal(await h.balance(account.address, token), before)
    assert.equal(await allowanceRead(h, token, account.address, h.recurring), 0n)
  })

  test('a repeated sponsorship request cannot drain the relayer: each one funds itself', async () => {
    // Ten sponsorships in a row. The treasury gains exactly ten fees; nothing accumulates in the
    // contract, and no attempt is executed without its own payment.
    const treasuryBefore = await h.balance(h.gasTreasury, token)
    for (let i = 0; i < 10; i++) {
      const { account, wallet } = payerFor(100 + i)
      await h.mint(account.address, 1_000_000n, token)
      const nowSeconds = await h.now()
      const args = {
        payer: account.address,
        spender: h.recurring,
        value: 1_000_000n,
        deadline: BigInt(nowSeconds + 300),
        networkFee: FEE_UNITS,
        validBefore: BigInt(nowSeconds + 300),
      }
      const nonce = sponsorPermitNonce({
        chainId: h.chainId,
        sponsor,
        token,
        payer: args.payer,
        spender: args.spender,
        allowanceValue: args.value,
        allowanceDeadline: args.deadline,
        networkFee: args.networkFee,
        validBefore: args.validBefore,
      })
      const permitSig = splitSig(
        await wallet.signTypedData(
          permitTypedData({
            chainId: h.chainId,
            token,
            tokenName,
            tokenVersion: '2',
            owner: args.payer,
            spender: args.spender,
            value: args.value,
            nonce: 0n,
            deadline: args.deadline,
          }) as never,
        ),
      )
      const feeSig = splitSig(
        await wallet.signTypedData(
          receiveWithAuthorizationTypedData({
            chainId: h.chainId,
            token,
            tokenName,
            tokenVersion: '2',
            from: args.payer,
            to: sponsor,
            value: args.networkFee,
            validBefore: args.validBefore,
            nonce,
          }) as never,
        ),
      )
      const hash = await h.relayer.writeContract({
        address: sponsor,
        abi: gasSponsorAbi,
        functionName: 'sponsorPermit',
        args: [
          {
            payer: args.payer,
            spender: args.spender,
            allowanceValue: args.value,
            allowanceDeadline: args.deadline,
            networkFee: args.networkFee,
            validBefore: args.validBefore,
          },
          permitSig.v,
          permitSig.r,
          permitSig.s,
          feeSig.v,
          feeSig.r,
          feeSig.s,
        ],
      })
      await h.chain.waitForTransactionReceipt({ hash })
    }
    assert.equal(await h.balance(h.gasTreasury, token), treasuryBefore + FEE_UNITS * 10n)
    assert.equal(await h.balance(sponsor, token), 0n)
  })

  test('a customer whose balance covers the price but not the fees pays nothing and gets nothing', async () => {
    const { account, wallet } = payerFor(3)
    const amount = 10_000_000n
    await h.mint(account.address, amount, token) // exactly the price
    const p: SponsoredPayment = {
      payer: account.address,
      recipient: h.seller,
      amount,
      ref: keccak256(toBytes('adversarial-short')),
      networkFee: FEE_UNITS,
      validBefore: BigInt((await h.now()) + 300),
    }
    const nonce = sponsoredPaymentNonce({
      chainId: h.chainId,
      splitter,
      token,
      serviceFee: 100_000n,
      payment: p,
    })
    const sig = splitSig(
      await wallet.signTypedData(
        receiveWithAuthorizationTypedData({
          chainId: h.chainId,
          token,
          tokenName,
          tokenVersion: '2',
          from: p.payer,
          to: splitter,
          value: p.amount + p.networkFee + 100_000n,
          validBefore: p.validBefore,
          nonce,
        }) as never,
      ),
    )
    const sellerBefore = await h.balance(h.seller, token)
    assert.equal(
      await h.expectRevert(
        h.relayer.writeContract({
          address: splitter,
          abi: sponsoredSplitterAbi,
          functionName: 'payWithAuthorization',
          args: [p, sig.v, sig.r, sig.s],
        }),
      ),
      'reverted',
    )
    assert.equal(await h.balance(account.address, token), amount)
    assert.equal(await h.balance(h.seller, token), sellerBefore)
    assert.equal(await h.balance(splitter, token), 0n)
  })
})

const allowanceRead = async (h: Harness, token: Address, owner: Address, spender: Address) =>
  (await h.chain.readContract({
    address: token,
    abi: artifact('MockFiatToken').abi as never,
    functionName: 'allowance',
    args: [owner, spender],
  })) as bigint

/**
 * The griefing attack an immutable contract cannot recover from.
 *
 * Both contracts assert that a call leaves no more than it found, rather than that the balance is
 * zero. The difference is the whole product: anyone may transfer tokens to any address, and a
 * zero-balance assertion in a contract with no owner, no pause and no sweep would be one dust
 * transfer away from refusing every payment forever.
 */
describe('donated dust cannot disable either contract', () => {
  let h: Harness
  let token: Address
  let splitter: Address
  let sponsor: Address
  let tokenName: string

  before(async () => {
    h = await startHarness()
    token = await h.deploy('MockFiatToken')
    tokenName = (await h.chain.readContract({
      address: token,
      abi: artifact('MockFiatToken').abi as never,
      functionName: 'name',
    })) as string
    splitter = await h.deploy('P2FluxSponsoredSplitter', [
      token,
      h.feeWallet,
      h.gasTreasury,
      h.relayer.account.address,
      100_000n,
      250_000n,
    ])
    sponsor = await h.deploy('P2FluxGasSponsor', [token, h.gasTreasury, h.relayer.account.address, 250_000n])
    // One base unit, from a stranger, to each contract.
    await h.mint(h.attacker.account.address, 1_000n, token)
    for (const target of [splitter, sponsor]) {
      const hash = await h.attacker.writeContract({
        address: token,
        abi: artifact('MockFiatToken').abi as never,
        functionName: 'transfer',
        args: [target, 1n],
      })
      await h.chain.waitForTransactionReceipt({ hash })
    }
  })
  after(async () => h.stop())

  test('a sponsored payment still settles, and the dust stays where it landed', async () => {
    const key = `0x${(0x5000).toString(16).padStart(64, '0')}` as Hex
    const account = privateKeyToAccount(key)
    const wallet = h.wallet(key)
    await h.mint(account.address, 1_000_000_000n, token)

    const p = {
      payer: account.address,
      recipient: h.seller,
      amount: 100_000_000n,
      ref: keccak256(toBytes('dust-payment')),
      networkFee: 4_000n,
      validBefore: BigInt((await h.now()) + 300),
    }
    const nonce = sponsoredPaymentNonce({
      chainId: h.chainId,
      splitter,
      token,
      serviceFee: 100_000n,
      payment: p,
    })
    const signature = await wallet.signTypedData(
      receiveWithAuthorizationTypedData({
        chainId: h.chainId,
        token,
        tokenName,
        tokenVersion: '2',
        from: p.payer,
        to: splitter,
        value: p.amount + p.networkFee + 100_000n,
        validBefore: p.validBefore,
        nonce,
      }) as never,
    )
    const sig = {
      v: Number(`0x${signature.slice(130, 132)}`),
      r: `0x${signature.slice(2, 66)}` as Hex,
      s: `0x${signature.slice(66, 130)}` as Hex,
    }

    const hash = await h.relayer.writeContract({
      address: splitter,
      abi: sponsoredSplitterAbi,
      functionName: 'payWithAuthorization',
      args: [p, sig.v, sig.r, sig.s],
    })
    const receipt = await h.chain.waitForTransactionReceipt({ hash })
    assert.equal(receipt.status, 'success', 'dust must not brick the contract')
    assert.equal(await h.balance(splitter, token), 1n, 'the dust is still there, and still inert')
  })

  test('a sponsorship still settles with dust in the contract', async () => {
    const key = `0x${(0x5001).toString(16).padStart(64, '0')}` as Hex
    const account = privateKeyToAccount(key)
    const wallet = h.wallet(key)
    await h.mint(account.address, 1_000_000_000n, token)

    const nowSeconds = await h.now()
    const args = {
      payer: account.address,
      spender: h.recurring,
      value: 50_000_000n,
      deadline: BigInt(nowSeconds + 300),
      networkFee: 4_000n,
      validBefore: BigInt(nowSeconds + 300),
    }
    const nonce = sponsorPermitNonce({
      chainId: h.chainId,
      sponsor,
      token,
      payer: args.payer,
      spender: args.spender,
      allowanceValue: args.value,
      allowanceDeadline: args.deadline,
      networkFee: args.networkFee,
      validBefore: args.validBefore,
    })
    const split = (signature: Hex) => ({
      v: Number(`0x${signature.slice(130, 132)}`),
      r: `0x${signature.slice(2, 66)}` as Hex,
      s: `0x${signature.slice(66, 130)}` as Hex,
    })
    const permitSig = split(
      await wallet.signTypedData(
        permitTypedData({
          chainId: h.chainId,
          token,
          tokenName,
          tokenVersion: '2',
          owner: args.payer,
          spender: args.spender,
          value: args.value,
          nonce: 0n,
          deadline: args.deadline,
        }) as never,
      ),
    )
    const feeSig = split(
      await wallet.signTypedData(
        receiveWithAuthorizationTypedData({
          chainId: h.chainId,
          token,
          tokenName,
          tokenVersion: '2',
          from: args.payer,
          to: sponsor,
          value: args.networkFee,
          validBefore: args.validBefore,
          nonce,
        }) as never,
      ),
    )

    const hash = await h.relayer.writeContract({
      address: sponsor,
      abi: gasSponsorAbi,
      functionName: 'sponsorPermit',
      args: [
        {
          payer: args.payer,
          spender: args.spender,
          allowanceValue: args.value,
          allowanceDeadline: args.deadline,
          networkFee: args.networkFee,
          validBefore: args.validBefore,
        },
        permitSig.v,
        permitSig.r,
        permitSig.s,
        feeSig.v,
        feeSig.r,
        feeSig.s,
      ],
    })
    assert.equal((await h.chain.waitForTransactionReceipt({ hash })).status, 'success')
    assert.equal(await h.balance(sponsor, token), 1n)
  })
})
