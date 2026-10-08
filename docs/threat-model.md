# Threat model — P2Flux contracts on Base

What each contract can and cannot do, who holds which key, and what an attacker could achieve with
each key or system they might compromise. Written 2026-10-08 against the contracts deployed on Base
Mainnet (addresses in the README). The contracts have **not** had a third-party audit; how they are
checked is in [`security-analysis.md`](security-analysis.md).

## Design properties that bound every risk

- **No upgrades, no proxies, no `delegatecall`.** The code that is verified on Sourcify is the code
  that runs, forever. A bug cannot be patched in place; it can only be replaced by a new deployment
  that users move to.
- **No owner who can move funds.** No contract has a withdraw, sweep, pause or "rescue" function.
  The only things that can change after deployment are listed under *Keys* below.
- **No custody between payments, except two short-lived vault types.** The splitters and the
  recurring contract move USDC from payer to merchant in the same transaction and end every call
  holding nothing (proved by the fuzz suites). The AI-agent vaults (`P2FluxX402Splitter` vaults and
  `P2FluxBatchVaults`) hold a seller's money until anyone calls `flush`, which can only pay that
  seller and the fixed fee.
- **Payments are bound to signatures.** Every payment is authorised by a signature from the payer
  (EIP-712, EIP-3009 or ERC-1271) over the exact recipient, amount, fee terms and reference. The
  relayer submits; it cannot change what was signed.
- **One token.** Every contract is pinned at deployment to Circle's native USDC on Base.

## Keys and roles

| Role | Address (Base Mainnet) | Where it lives | What it can do |
|---|---|---|---|
| Relayer | `0xF3Ca1D6BC5ad6Ca054eCa65a45117Ebff2a52309` | hot key on the P2Flux API server | Submit payer-signed transactions; receive the gas reimbursement a payer signed (capped); be paid ETH by the gas refill |
| Admin (`P2FluxRecurring`) | `0xEc8779352AF47C5CbF877e1B22B5CFF6Df042410` | cold, never on a server | Rotate the recurring contract's relayer. Nothing else |
| Gas treasury | `0xdCdE2146cF3ab9aE37933211AF8943c807c31506` | cold wallet | Receives network fees; approves `P2FluxGasRefill`; sets the refill limits |
| Fee wallet | `0x12FDDADa5C8d027537B90342a68F5dd1A79C8feB` | P2Flux | Receives the P2Flux fee. Has no power over any contract |
| Deployer | `0x69D942d721156587bb53241A71614f26B4b38E2a` | workstation key, used only to deploy | Deployed the contracts. Has no role in any of them |

Changeable after deployment, and only by these keys:
- `P2FluxRecurring.relayer`, by the admin (so a stolen relayer key can be replaced).
- `P2FluxGasRefill` limits (daily cap, refill target, slippage up to 5%), by the gas treasury.

## What an attacker can do with each compromise

### The relayer key (most exposed: it lives on an internet-facing server)
- **Cannot** redirect any payment, change any amount, or create a payment nobody signed.
- **Recurring:** can trigger charges that are already due under a payer's signed terms (once per
  period, the signed amount) and take up to the signed gas reimbursement, never more than
  0.05 USDC per charge (hard-coded). The admin then rotates the relayer.
- **Sponsored one-time payments and allowance operations:** can only submit what the payer signed;
  the network fee it can collect is capped in the contract (0.25 USDC per operation).
- **AI-agent payments:** can only settle what the agent signed, into that seller's vault; the fee
  is fixed (`max(1%, 0.003 USDC)`, and the seller always keeps at least half). For `upto`, it chooses
  the amount used up to the agent's signed maximum — the x402 `upto` trust model.
- **Gas refill:** could spend the relayer's own ETH and let `P2FluxGasRefill` top it up again, at
  the oracle price, at most **100 USDC per day** (the current cap) from the gas treasury, until the
  treasury lowers the cap or removes its approval. This is the largest bounded loss from this key.
- **Response:** the admin rotates the recurring relayer; the API is moved to a new key; the gas
  treasury lowers the refill cap or revokes its approval. The watchdog alerts when the relayer
  stays low and refills stop landing - in this scenario, once the daily cap is used up; it does not
  alert on each successful refill.

### The admin key
- Can only point `P2FluxRecurring` at a different relayer. A malicious relayer is bounded exactly as
  above: it cannot redirect payments or exceed signed terms.

### The gas treasury key
- Controls P2Flux's own gas money and the refill limits. It has no power over customer or merchant
  funds.

### The P2Flux API server
- Holds the relayer key (see above) and the key that signs payment requests. Payment requests are
  not money: a buyer's wallet still shows and signs the exact recipient and amount, and the hosted
  checkout refuses contracts other than the published ones. A self-hosted checkout with a merchant
  wallet list refuses any payment that does not go to the merchant's own wallets, even if the API
  were compromised.
- The API cannot sign for a buyer, so it cannot start a subscription or a payment nobody approved.

### The hosted checkout (pay.p2flux.com)
- A modified page could ask a buyer to sign something else. Defences: strict Content-Security-Policy,
  the page pins the published contract addresses, and the buyer's wallet shows what is being signed.
  Merchants who want to remove this dependency can self-host the checkout (checksummed releases).

## The largest exposure: standing USDC approvals

A subscription needs the payer to approve `P2FluxRecurring` to pull USDC (by default an unlimited
approval, like most subscription systems). Each charge is still limited to the signed amount, once
per period, to the signed recipient. But **if a bug in `P2FluxRecurring` allowed a charge outside
those terms, every approving wallet would be exposed up to its approval and balance.** This is why
`P2FluxRecurring` is the first contract for an independent review, and why it has the most tests
(fuzzed signature binding for every field, one charge per period, revocation, smart-wallet and
EIP-7702 paths, and agreement between its read-only answers and `charge`).

Payers can limit this themselves: a bounded approval (the API supports it), revoking the
subscription (`revoke`), or removing the approval at any time from their wallet.

## External dependencies we trust

| Dependency | Trust |
|---|---|
| USDC (Circle FiatToken) | Behaves as USDC; Circle can freeze addresses (handled: a frozen fee wallet or seller never locks other funds) |
| Base (OP Stack) sequencer | Orders and includes transactions; an outage delays payments, it does not move funds |
| Chainlink ETH/USD and the Base sequencer-uptime feed | Price for gas refills only; stale or post-outage prices are refused |
| Uniswap v3 | Gas refill swaps only; output must be within the slippage limit of the oracle price |
| x402 batch-settlement escrow (`0x4020…0003`, x402 project) | Holds agent deposits for prepaid AI-agent payments; P2Flux's vaults only receive from it |
| Permit2 / x402 `upto` proxy | Used for x402 `upto` payments; the proxy's code hash is pinned in the fork tests |

## Not covered by these contracts

- Mistakes by merchants (wrong wallet configured) or payers (signing a phishing page's request).
- Funds after they reach the merchant's wallet.
- The security of payers' and merchants' own wallets and devices.

## Reporting

See [`SECURITY.md`](../SECURITY.md): contact@p2flux.com, privately.
