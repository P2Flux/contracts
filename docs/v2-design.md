# P2Flux contracts v2: design

Status: **draft on branch `feat/contracts-v2`, not deployed anywhere, no third-party audit.**
Written 2026-11-23 for the prices the owner agreed that day; updated 2026-11-24 after the internal
review (`docs/v2-review-2026-11-24.md`, fixes in §13). v1 (`main` = `eda94d7`, live on Base) stays
exactly as it is.

## 1. Goals

1. New prices: one-time 1% (partners 0.75%), subscription renewal 1.5% (partners 1.25%), fixed fee
   0.05 USDC paid by the merchant (replaces 0.10), buyer still pays the real gas on top when relayed.
   **Owner rule: no fixed fee when the payer pays their own gas** - the 0.05 applies only when
   P2Flux's relayer sends the transaction.
2. A new **Send** tool: 0.1% on top, plus 0.05 USDC only when relayed (and no separate gas quote:
   owner decision 2026-11-24); the receiver gets the exact amount; minimum 1 USDC; no maximum.
3. Fees adjustable **without redeploying**, but only under hard caps written in the code and only
   after a public 48-hour waiting period.
4. A partner (white-label) tier that a merchant can never give themselves.
5. One code base for Base, Arc, Polygon, Arbitrum and Optimism; only constructor parameters differ.
6. Keep every v1 security property: pinned USDC, immutable fee wallet and gas treasury, replay
   protection by reference, network-fee hard cap, relayer-only sponsored paths, EIP-3009 / EIP-2612
   flows, "leave no more than found" balance guard, no custody, no upgrade, no withdrawal.

## 2. The contracts

All new files are in `contracts/v2/`. v1 files are not modified.

| Contract | What it does | Replaces |
|---|---|---|
| `P2FluxFeeRegistry` | One per chain. Holds the three rates, the partner list, the caps and the timelock. Moves no money. | the `ONE_TIME_BPS` / `FEE_BPS` / `NETWORK_FEE` constants |
| `P2FluxV2Base` (abstract) | Shared by the four payment contracts: pinned token (must have code and 6 decimals), immutable fee wallet, immutable registry, the one line of fee math. | - |
| `P2FluxSplitterV2` | One-time payment, buyer pays own gas. | `P2FluxSplitter` |
| `P2FluxSponsoredSplitterV2` | One-time payment, buyer has no gas: EIP-3009 signature, relayer submits. | `P2FluxSponsoredSplitter` |
| `P2FluxRecurringV2` | Subscriptions. Same signature, period, revoke, EIP-7702 and ERC-1271 logic as v1, line for line; only the fee terms changed. EIP-712 domain version `"2"`. | `P2FluxRecurring` |
| `P2FluxSend` | New. Send USDC to anyone, fees on top; direct or relayed. | - |

Not changed in v2 (keep using v1): `P2FluxGasSponsor`, `P2FluxGasRefill`, `P2FluxX402Splitter`,
`P2FluxBatchVaults`. The x402 rates (1% with a floor, 3% batch) are not part of this price change.

Why a **registry contract** rather than a base contract that stores rates in each payment contract:
a price change or a partner listing is then one admin action per chain instead of four, all four
contracts can never disagree about a rate, and the timelock exists once. Cost: one external call per
payment (measured below). The base contract still exists, but only for what is truly per-contract.

## 3. Fee paths, exact math, rounding

Notation: `bps` and `fixed` are read from the registry **at execution time** (the value effective
at `block.timestamp`); `bps` is the partner rate when `registry.isPartner(recipient)`. Each payment
contract re-checks the hard caps on what the registry returns (`bps <= 200`, partner `<=` standard,
`fixed <= 0.20`) and reverts `RateAboveCap` otherwise. `fixed` is charged **only on relayed paths**.
Every path refuses a recipient equal to the contract itself (`InvalidRecipient`; funds sent there
could never leave). All amounts are USDC base units (6 decimals).

```
fee = floor(amount * bps / 10_000)
```

The percentage fee always **rounds down**. P2Flux never takes more than the exact rate; the
sub-unit remainder (the "dust", < 1 base unit = < 0.000001 USDC) stays with whoever funds the fee:
the merchant on payments and subscriptions, the sender on sends. Every transfer is an exact amount,
so no dust is ever left in a contract.

### 3.1 One-time, buyer pays gas: `P2FluxSplitterV2.pay`

| Who | Amount |
|---|---|
| buyer debited | `amount` |
| recipient | `amount - fee` |
| fee wallet | `fee` (1% or 0.75%) |

No fixed fee on this path: the buyer pays their own gas (owner rule). Example: 100 USDC → merchant 99.00,
P2Flux 1.00; partner → 99.25 / 0.75.

### 3.2 One-time, relayed: `P2FluxSponsoredSplitterV2.payWithAuthorization`

| Who | Amount |
|---|---|
| buyer debited (signs exactly this) | `amount + networkFee` |
| recipient | `amount - fee - fixed` |
| fee wallet | `fee` |
| gas treasury | `fixed + networkFee` |

`networkFee` is the quoted real gas, signed by the buyer, `<= MAX_NETWORK_FEE_HARD_CAP` (per chain,
constructor, never above 1 USDC). Refused unless `amount > fee + fixed` (merchant always gets
something). `minimumAmount(recipient) = floor(fixed * 10_000 / (10_000 - bps)) + 1` (closed form,
fuzz-checked as the exact boundary). Example: 10 USDC, quoted gas 0.02 → buyer 10.02, merchant
9.85, P2Flux 0.10, gas treasury 0.07.

The buyer's EIP-3009 nonce binds chain, contract, token, payer, recipient, amount, ref, networkFee,
validBefore. Unlike v1 it does **not** bind the fixed fee: the buyer's debit never depends on P2Flux
fees, and a merchant-side fee change is public 48 h before it applies. If a rate changes between
quote and execution only the merchant's split changes (test `test_rateChangeDoesNotTouchBuyerDebit`).

### 3.3 Subscription renewal: `P2FluxRecurringV2.charge`

| Who | Amount |
|---|---|
| payer debited | `amount + reimbursement` |
| recipient | `amount - fee - fixed` |
| fee wallet | `fee` (1.5% or 1.25%) |
| gas treasury | `fixed + reimbursement` |

`fixed` and `reimbursement` only when the **relayer** runs the charge; when the payer, the merchant or
anyone else runs it (and pays the gas), both are 0 and the merchant gets `amount - fee`.
`reimbursement <= auth.maxGasReimbursement` (payer-signed) and `<= GAS_REIMBURSEMENT_HARD_CAP` (per
chain, constructor, never above 1 USDC). Refused unless `amount > fee + fixed`. Example: 10 USDC →
merchant 9.80 (partner 9.825), or 9.85 when self-executed. A rate change applies to the next charge
of an existing subscription, after the timelock; the payer's debit never changes. Trade-off: a
merchant can self-execute a due charge to skip the 0.05, but then pays the gas itself.

`isChargeable` also returns false when `amount <= fee + fixed` at the **current** rates (counted as
a relayer charge), so the relayer's scheduler sees a subscription that a fee increase made
uncoverable instead of wasting gas on reverts.

**Recommended minimum subscription amount (API rule):** at the caps (2% + 0.20) the smallest amount
that stays chargeable is `floor(0.20e6 * 10_000 / 9_800) + 1 = 204_082` base units (0.204082 USDC;
fuzz-tested at every legal rate). The API should refuse subscriptions below **1 USDC** (simple, far
above that bound), and never below 0.21 USDC.

### 3.4 Send, direct: `P2FluxSend.send(to, amount, maxFee, ref)`

| Who | Amount |
|---|---|
| sender debited | `amount + fee` |
| receiver | `amount` exactly |
| fee wallet | `fee` (0.1%) |

`amount >= 1 USDC`. Reverts `FeeAboveMax` if `fee > maxFee`, so a rate change landing in the same
block can never take more than the sender agreed to. `sendWithPermit` does a permit for
`amount + maxFee` then `send`. Example: 100 USDC → sender pays 100.10, receiver gets 100.00.

### 3.5 Send, relayed: `P2FluxSend.sendWithAuthorization`

| Who | Amount |
|---|---|
| sender debited (signs exactly this) | `amount + fee + fixed` |
| receiver | `amount` exactly |
| fee wallet | `fee` |
| gas treasury | `fixed` |

The sender signs the exact total, so any different fee makes the token reject the signature; no
`maxFee` is needed (test `test_relayed_rateChangeInvalidatesSignature`). Replay: the token burns the
nonce, which binds every term including `ref`. There is no gas-quote field at all (R-07b): 0.05 is
the whole relay charge. Example: 100 USDC → sender 100.15.

### 3.6 Rounding and tiny amounts

- Below 100 base units a 1% fee is 0; splitting a payment into sub-cent pieces to dodge the fee
  costs far more gas than it saves. Sends are at least 1 USDC, so their fee is at least 0.001 USDC.
- Overflow: Solidity 0.8 checked math; `amount * bps` only overflows above ~5.8e74 base units.
  Fuzzed up to 1e18 (one trillion USDC).

## 4. Caps and timelock (`P2FluxFeeRegistry`)

| Item | Value | Where |
|---|---|---|
| Max percentage fee (any kind, any tier) | 200 bps = 2% | `MAX_BPS`, constant in code |
| Partner rate | `<= ` standard rate of the same kind | checked on every change |
| Max fixed fee | 0.20 USDC | `MAX_FIXED_FEE`, constant in code |
| Delay | 48 h | `DELAY`, constant |
| Effective time | exactly schedule time + 48 h, automatically | no execute call exists |
| Max per-chain gas cap (sponsored network fee / recurring reimbursement) | 1 USDC | constructor check |
| Caps re-checked by every payment contract | same values | `P2FluxV2Base._rate` |
| Registry sanity at construction | `MAX_BPS == 200`, `MAX_FIXED_FEE == 0.20`, `DELAY == 48 h`, `rates()` answers | `P2FluxV2Base` constructor |

**Auto-effective timelock (R-05, R-09).** Each rate kind and each partner address has one slot:
`current`, `next`, `eta`. Every read returns `next` once `block.timestamp >= eta`, otherwise
`current`. So a change takes effect exactly at its ETA, by itself; nobody chooses the moment and
there is no execute call (and no batch that one stale entry could block).

Flow: `scheduleRate(kind, rate)` / `schedulePartners(list, bool)` (admin only; checks caps; emits
`RateScheduled` / `PartnerScheduled` with `effectiveAt`) → visible on chain via `pendingRate(kind)` /
`pendingPartner(addr)` → `cancelRate` / `cancelPartner` (admin) **before** the ETA; from the ETA on
the change is live and undoing it means scheduling the old value (another 48 h). Scheduling again
first keeps whatever is already effective, then replaces the pending value and restarts the clock.
Initial rates are set in the constructor (emitted as `RateScheduled` with `effectiveAt = deploy
time`) and checked against the same caps.

Ops: the API should stop quoting relayed sends at the old rate shortly before a known ETA (a relayed
send signed at the old total fails once the new rate is live; the sender re-signs).

Initial values (owner, 23 Nov 2026): OneTime `{100, 75, 50_000}`, Recurring `{150, 125, 50_000}`,
Send `{10, 10, 50_000}`.

## 5. Partner rates: registry (a) vs signed quote (b)

| | (a) on-chain registry, recipient → partner | (b) P2Flux-signed EIP-712 quote per payment |
|---|---|---|
| Can a merchant pick a lower fee? | No: tier is looked up by recipient in a registry only the admin changes. | No, if the quote is bound to the exact payment; yes if binding is wrong (extra attack surface). |
| Key at risk | Admin (cold / multisig, rarely used). Compromise: timelocked, visible, bounded by caps. | Quote signer must be **hot** (signs every payment). Compromise: instant 0% for anyone, invisible until noticed. |
| Gas | registry reads, about +15k gas per payment (measured, see §9). | ecrecover + 65 bytes + struct hashing, similar or more. |
| Simplicity | ~180 lines, no signatures. | Signer rotation, nonce/expiry, binding into buyer signature or recurring charge, all paths need the API. |
| Self-pay and direct users | Work without the API. | Every payment needs an API quote, even `pay` from a wallet. |
| Ops | Listing a partner wallet = one admin tx, effective 48 h later; batched (`schedulePartners(list)`). | Instant changes in the API database. |
| Transparency | Anyone can check a merchant's rate on chain. | Only in each payment's quote. |

**Decision: (a), implemented.** It keeps the only fee-changing key cold and timelocked, keeps every
contract usable without the API, and is the simplest. Cost: partner onboarding takes 48 h and an
admin signature per batch of wallets. Unlisting a partner is a fee increase for that merchant, so it
is timelocked too. More than two tiers is not built (YAGNI); it would become `recipient → tier id`.

## 6. Roles and keys

| Role | Holds | Can | Cannot |
|---|---|---|---|
| Admin | Multisig (recommended) or cold key; **never** the relayer, never on a server | Schedule / cancel rate and partner changes (caps + 48 h); rotate `P2FluxRecurringV2.relayer` | Move, redirect or freeze funds; exceed caps; skip the delay; change fee wallet, gas treasury, token, registry |
| Relayer | Hot key on the API server, one per chain | Submit payer-signed sponsored payments, relayed sends, recurring charges with a reimbursement | Change any signed term; take more than the signed network fee / reimbursement or the per-chain cap |
| Fee wallet | P2Flux | Receive percentage fees | Anything on the contracts |
| Gas treasury | Cold wallet | Receive fixed fees + gas | Anything on the contracts |
| Deployer | Fresh key per deployment, unfunded after | Nothing after deployment | - |
| Anyone | - | Call `charge` for a due subscription; gets no reimbursement and no fixed fee is taken (as v1, plus R-04) | Change or apply any registry value |

**`setRelayer` is instant on purpose (R-08, accepted).** If the relayer key leaks, the admin must be
able to swap it in the same block; a timelock would leave the leaked key live for 48 h. The cost is
bounded: a malicious relayer (or a compromised admin who installs one) can only attach up to
`min(signed maxGasReimbursement, GAS_REIMBURSEMENT_HARD_CAP)` per due charge, and that money goes to
the immutable gas treasury, not to the attacker. Watchdog alerts on `RelayerChanged`.

The admin is immutable (no transfer function). With a multisig, signer rotation happens inside the
multisig. If a cold EOA admin is lost, rates freeze at their current values (safe, but a price
change would then need a new registry and new payment contracts). Hence: use a multisig.

## 7. Threat model

| Threat | Result in v2 |
|---|---|
| **Malicious merchant** calls contracts directly to get a lower fee | Impossible: rate comes from the registry, keyed by recipient. Paying to a partner's address pays the partner. Test `test_nonPartnerPaysStandardEvenIfCallingDirectly`. |
| Malicious merchant sets a wallet that cannot receive (blacklisted) | That merchant's payments revert; nothing else affected. |
| **Compromised relayer** | Same bounds as v1: only signed payments; network fee ≤ signed and ≤ per-chain cap; reimbursement ≤ signed and ≤ cap. Admin rotates the recurring relayer; sponsored/send relayers are immutable, so a compromise means redeploying those two (no long-lived state in them). |
| **Compromised admin** | Can raise rates up to 2% + 0.20 USDC, or (un)list partners, each only after 48 h in public. Cannot touch payer debits (except send fees, which the sender signs or caps). Can point the recurring relayer at itself → bounded as a compromised relayer. Defence: multisig; watchdog alert on `RateScheduled` / `PartnerScheduled` / `RelayerChanged`; publish changes to merchants. Because the admin is immutable, a compromised admin stays able to re-schedule; the recovery is new contracts. |
| **Front-running** a rate change | There is no execute call to front-run: a change is live exactly at its public ETA. Payers never see a different debit (merchant-funded fees; relayed sends signed exactly; direct sends `maxFee`). Merchants had 48 h notice. |
| Payment to the contract itself | Refused on every path (`InvalidRecipient`, R-01); funds there could never leave. |
| Wrong registry address in a manifest / registry bug | Constructor sanity read (caps, delay, `rates()`); every payment re-checks the caps on what the registry returns (R-02). Worst case is bounded by 2% + 0.20, never 100%. |
| Front-running a permit | Swallowed (try/catch), as v1. |
| Front-running a sponsored payment / relayed send | Relayer-only, as v1. A stranger cannot call `receiveWithAuthorization` for our contract (token requires `to == msg.sender`). |
| **Replay** | One-time: per-contract `processedPayments[paymentId]`. Sponsored / relayed send: token-burned EIP-3009 nonce binding chain + contract + all terms. Recurring: one charge per period per subscription id; v1 signatures cannot charge v2 (domain version "2", different contract; test `test_v1SignatureRefused`). |
| **Griefing** | Dust donated to a contract cannot brick it ("leave no more than found", not "hold zero"). Nobody but the admin can create, apply or cancel a change; effective time is fixed at scheduling. Unbounded partner list is never iterated on chain. |
| **ERC-20 quirks** | Token pinned at deploy and must have code and `decimals() == 6`. False-returning or reverting transfers revert the payment (SafeERC20). A blacklisted fee wallet or gas treasury makes payments revert (as v1); since both are immutable, that would need a redeploy. Fee-on-transfer / rebasing tokens are not supported (USDC is neither); the residual-balance check would catch an over-delivery. |
| Reentrancy | USDC has no hooks; sponsored, recurring and relayed send are `nonReentrant` anyway; effects before interactions. |
| Registry bug | Affects all four contracts on that chain. Mitigated by size (~190 lines), tests and fuzzing, and the caps re-checked in every payment contract; it moves no funds, so a bug can at worst mis-price within caps or block payments. |

Tools run: Foundry unit, fuzz (1000 runs) and stateful invariant suites; Slither (findings are the
same by-design patterns as v1: signature-gated `transferFrom` from the payer, intentional balance
comparison around the token call, timestamp use for periods and the timelock).

## 8. Multi-chain

### 8.1 One code base

Nothing in the contracts depends on the chain except `block.chainid`, which is part of the EIP-712
domains and EIP-3009 nonces (replay across chains impossible). Per chain only the constructor
parameters change.

| Parameter | Base | Arbitrum One | Optimism | Polygon PoS | Arc |
|---|---|---|---|---|---|
| USDC (native, verify vs Circle docs at deploy) | `0x8335…2913` | `0xaf88…5831` | `0x0b2C…Ff85` | `0x3c49…3359` | `0x3600…0000` (ERC-20 interface of native USDC) |
| Fee wallet | per chain or same | | | | |
| Gas treasury | per chain or same | | | | |
| Relayer | per chain hot key | | | | |
| Admin | multisig (same address everywhere if possible) | | | | |
| `MAX_NETWORK_FEE_HARD_CAP` (sponsored only; Send has no gas quote) | 0.25 USDC (as v1) | measure | measure | measure | measure |
| `GAS_REIMBURSEMENT_HARD_CAP` (recurring) | 0.05 USDC (as v1) | measure | measure | measure | measure |
| Initial rates | §4 | §4 | §4 | §4 | §4 |

Native USDC only, never bridged USDC.e. Before each chain: verify the token has 6 decimals and
supports EIP-2612 `permit` and EIP-3009 `receiveWithAuthorization` (FiatToken v2.x on Base,
Arbitrum, Optimism and Polygon do).

### 8.2 Arc

On Arc, USDC is the native gas token; the ERC-20 interface uses 6 decimals while native balances use
18. The contracts only use the ERC-20 interface and none of them is `payable`, so the design holds:
the relayer pays gas in native USDC and is reimbursed in USDC to the gas treasury (no ETH swap, so
`P2FluxGasRefill` is not needed there). Relaying is less necessary on Arc because every USDC holder
can pay gas, but it still helps wallets that do not support Arc gas natively. **To verify before
deploying on Arc:** that its USDC ERC-20 interface implements `permit` and `receiveWithAuthorization`
(if not, only `pay`, `send` and `charge` work there), its decimals, its blocklist behaviour, and that
the CREATE2 deployer below exists.

### 8.3 Deterministic addresses (CREATE2)

Deploy through the standard deterministic deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`,
present on Base, Arbitrum, Optimism, Polygon; verify on Arc) with a fixed salt. None of the
constructors reads `msg.sender`, so deploying through a factory is safe. Order: registry first (its
address is a constructor argument of the other four), then the four payment contracts.

Honest limit: the address is a hash of the constructor arguments, and the USDC address differs on
every chain, so **payment contracts get different addresses per chain** (predictable, recorded in the
manifest before deploying). The registry can have the **same address on every chain** if the admin
address and initial rates are identical. Identical payment-contract addresses would need an
initializer after deployment, which adds a front-running and misconfiguration risk; not worth it.

## 9. Gas (measured, Foundry, mock USDC, after the review fixes)

| Call | v1 | v2 |
|---|---|---|
| Sponsored one-time | 187.6k | 202.2k (+14.6k: registry reads + cap re-check + partner lookup) |
| Recurring charge (relayer) | 168.9k | 183.6k (+14.7k) |
| Send direct | - | 102.8k |
| Send relayed | - | 173.9k |

## 10. Migration

1. Deploy v2 next to v1 per chain (after review, audit, manifests, owner approval). Nothing on v1
   changes; v1 has no admin that could change it anyway.
2. **Existing subscriptions stay on `P2FluxRecurring` v1** at the old price (2% + 0.10) until they end
   or the payer re-subscribes; a payer's signature and allowance are bound to the v1 address, and
   moving them would need a new signature and approval from every payer. New subscriptions go to v2.
   Optionally offer merchants a "re-subscribe at the new price" flow later.
3. New one-time payments go to v2 as soon as it is live; v1 splitters keep working for anyone who
   calls them directly (old SDKs, self-hosted checkouts).
4. The API, checkout and indexers must accept **both** v1 and v2 contracts per chain for verifying
   payments, reading events and recovery, forever (historical payments stay on v1).
5. Keep a historical contracts list in `manifests/` and the npm package `addresses`: per chain, per
   contract, version, address, deploy block, status (`active` / `legacy-accepting` / `retired`).

## 11. What changes later in API, checkout, SDKs (list only)

- Price tables: read rates from the registry (`feeFor`, `rates`, `isPartner`) instead of constants;
  show pending changes (`pendingRate`, `pendingPartner`, `effectiveAt`) to merchants.
- Sponsored v2 nonce: new domain tag, no fixed fee in it (new `authorizationNonce` layout).
- Recurring v2 EIP-712 domain version `"2"`; new contract address in typed data.
- Send product: quote endpoint (`quote(amount)`), `maxFee` for direct sends, relayed send with
  `amount + fee + fixed` (no gas quote); stop quoting the old rate shortly before a known ETA.
- Partner admin flow: list of partner wallets → `schedulePartners` batch prepared for the multisig;
  live 48 h later with no further transaction.
- Recurring: subscription minimum 1 USDC (§3.3); scheduler uses `isChargeable`; merchant net is
  `amount - fee` when a charge is not relayer-run.
- Refuse P2Flux contract addresses as merchant / receiver wallets (also enforced on chain).
- Watchdog: alert on `RateScheduled`, `RateCancelled`, `PartnerScheduled`, `RelayerChanged`.
- Multi-chain: per-chain contract sets, relayers, gas caps, RPCs; chain id in every quote.
- Contract allow-list in checkout and self-hosted checkout: add v2 addresses, keep v1.
- Events: `Paid` and `SponsoredPaid` keep their v1 shapes; `SubscriptionCharged.networkFee` now
  carries the registry fixed fee; new `Sent` event.
- ABIs and `dist/` entries for the v2 contracts; manifest scripts and manifest tests for v2; SDK
  backward compatibility test (old SDKs must keep working against v1).
- Changes feed / docs / terms with the new prices and the 48 h fee-change notice.

## 12. Open questions for the owner

- ~~Q1~~ Decided 2026-11-24: no fixed fee whenever the payer pays their own gas (all paths).
- **Q2** The fixed fee goes to the **gas treasury** (as today's 0.10 does). Should it be revenue
  (fee wallet) instead?
- ~~Q3~~ Decided 2026-11-24: relayed Send = 0.1% + 0.05, no gas quote (field removed from the contract).
- **Q4** Caps: 2% and 0.20 USDC (today's recurring price as ceiling). Enough headroom?
- **Q5** Delay 48 h (auto-effective, no grace any more): OK? Longer (7 days) would give merchants more
  notice.
- **Q6** Admin: which multisig (Safe, how many signers), same address on all chains?
- **Q7** Send has no partner tier. Needed?
- **Q8** Order of chains after Base, and Arc token capabilities (§8.2).

## 13. Backend and ops rules (from the 2026-11-24 review)

These are not enforced (or not fully enforceable) on chain; the API, relayer and ops must follow them.

- **R-06: each order is bound to one contract.** The splitter v2, sponsored v2 and both v1 splitters
  compute the same `paymentId` but keep separate replay tables, so the same `(recipient, amount, ref)`
  can be settled once on each. The API records, per order, the one contract (and chain) it may be paid
  through; before showing a pay button, accepting a payment or offering a refund it checks
  `isPaymentProcessed` on **all** splitter contracts (v1 and v2) for that id, and treats a second
  settlement as a duplicate to refund off chain.
- **R-07: relayer policy for Send.** A relayed send is a cheap, gasless, ref-tagged rail (0.1% + 0.05
  vs 1% + 0.05 for a sponsored payment), and the contract cannot tell a gift from a sale. The relayer
  refuses relayed sends to known merchant wallets (registered recipients, payment-link wallets),
  rate-limits per sender and per receiver, and keeps Send out of merchant integrations (no `ref`
  invoice flows). Direct sends (sender pays gas) are open to anyone and earn the 0.1%.
- **R-10: gas-treasury (or fee-wallet) blacklist runbook.** Both addresses are immutable. If Circle
  blacklists the gas treasury, every sponsored payment and relayed send reverts (direct `pay` and
  `send` keep working; relayer-run recurring charges also stop, since they pay the treasury). Steps:
  (1) watchdog alert on failing relayed paths / a `Blacklisted` event for our addresses; (2) switch
  the API to direct (buyer-pays-gas) flows only; (3) contact Circle; (4) if not lifted quickly, deploy
  a new sponsored splitter and Send (and recurring for new subscriptions) with a fresh, clean treasury
  from the manifest, publish the new addresses, keep the old ones in the historical list. A
  blacklisted fee wallet stops every path that takes a fee: same steps, redeploying everything but
  the registry. Keep fee wallet and gas treasury clean, separate, single-purpose addresses.
- **R-08:** instant `setRelayer` is kept for incident response (see §6).

Changes made in response to the review (commit after `a9894a6`): R-01 `InvalidRecipient` everywhere;
R-02 caps re-checked in `P2FluxV2Base._rate`, registry sanity read at construction, `minimumAmount`
can no longer divide by zero; R-03 `isChargeable` uses current rates; R-04 fixed fee only on relayed
paths; R-05 and R-09 auto-effective timelock, `executeRate`, `executePartners` and the 7-day grace
removed; R-07b `networkFee` removed from Send; T-01 fuzzed recipients exclude the partner. The
review's PoCs are now regression tests in `test/foundry/v2/review/ReviewFindings.t.sol`.
