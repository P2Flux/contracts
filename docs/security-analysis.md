# Security analysis — how these contracts are checked

Free, open-source tooling only. Nothing here is an audit, and nothing here claims to be one.

## What runs

| Check | Command | Where |
|---|---|---|
| Deployment-facing suite (anvil + viem) | `npm test` | CI, every push |
| Fuzz + stateful invariant suites | `forge test` | CI, every push |
| Longer soak before a release | `FOUNDRY_PROFILE=deep forge test` | locally |
| Static analysis | `slither .` (0.11.6) | CI, every push |
| Runtime dependency audit | `npm audit --omit=dev --audit-level=high` | CI, every push |

Foundry setup, once: `forge install foundry-rs/forge-std@v1.9.7 --no-git`. `lib/` is deliberately
untracked — `test/hygiene.test.ts` reads every tracked path as a file, which a git submodule is not.

## What the fuzz and invariant suites prove (`test/foundry/`)

- **Conservation.** For every settlement, payer outflow equals merchant receipt + P2Flux fee +
  fixed network fee + quoted/reimbursed network cost, to the base unit. No USDC appears or vanishes,
  and no contract ends a call holding any part of a payment.
- **Fee ceilings.** 1% one-time and 2% recurring, rounding toward the merchant; the quoted network
  fee can never exceed the constructor hard cap, and recurring gas reimbursement is capped both by
  the payer's signature and by the 0.05 USDC protocol ceiling. Amounts that would leave the
  merchant nothing are refused, and the minimum is the exact boundary.
- **Access control.** Only the relayer can execute sponsored calls; only the relayer is ever
  reimbursed; only the immutable admin can rotate the recurring relayer, never to zero, and
  rotation cannot move any payment destination. No other privileged function exists.
- **Replay and signature binding.** One settlement per intent, one charge per period (no catch-up
  billing after a gap), authorizations are single-use, and modifying ANY signed field — recipient,
  amount, fee, reference, expiry, period, salt, payer — invalidates the signature. Signatures are
  dead on another chain id and on another deployment. ERC-6492 wrappers are refused.
- **Revocation.** Only the payer can revoke; a revoked authorization is never charged again.
- **Robustness.** Dust donated to a sponsored contract neither bricks it nor leaks; a failed permit
  rolls back the fee already pulled; a failed transfer leaves the intent payable.

The stateful suites drive random sequences (relayer and stranger charges, time jumps, revocations,
replays, donations) against an independent ledger and compare after every call.

## Slither triage

Reviewed 2026-09-18, Slither 0.11.6. All 13 findings are recorded by id in `slither.db.json`, so CI
fails on anything new. None is a vulnerability:

| Detector | Where | Verdict |
|---|---|---|
| `arbitrary-send-erc20` ×3 | `P2FluxRecurring.charge` | **False positive.** `from` is the payer whose EIP-712 signature (EOA, ERC-1271 or EIP-7702) was verified immediately before; pulling from a signer who authorised exactly these terms is the design. The fuzz suite proves forged and tampered signatures fail. |
| `reentrancy-balance` ×3 | `P2FluxSponsoredSplitter`, `P2FluxGasSponsor` | **False positive.** Both functions are `nonReentrant`, the token is the immutable pinned USDC, and comparing against the pre-call balance is the intended residual check. |
| `unused-return` ×2 | `P2FluxRecurring._isAuthorized` | **Informational.** The ignored value is `tryRecover`'s error argument; the error code itself is checked. |
| `reentrancy-events` ×2 | `P2FluxSplitter.pay` | **Informational.** State is written before the token calls (checks-effects-interactions); the token is pinned. |
| `timestamp` ×3 | `P2FluxRecurring` period logic | **Accepted.** Periods are hours to months; validator timestamp drift of seconds cannot move a charge across a period in any way that benefits anyone. |

The deployed contracts are immutable and source-verified, so findings are triaged in the database
rather than with inline `slither-disable` comments: editing a verified source file, even a comment,
changes its metadata hash and breaks the match with the deployment.

## Accepted dependency risk

`npm audit` reports `tmp` (via `solc@0.8.26`, dev-only). The only available fix replaces the
compiler with 0.8.37. The deployed bytecode is verified against 0.8.26, so the compiler stays
pinned; `tmp` is reachable only through solc's build-time tooling on a developer machine, never at
runtime and never in the published package.
