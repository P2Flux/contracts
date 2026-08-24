# P2Flux contracts

The P2Flux protocol layer: the Solidity contracts, their ABIs, and the TypeScript definitions that
describe them — EIP-712 structures, public chain constants and the amount codec.

This repository is the **canonical source** for all of it. `P2Flux/core` consumes it as a pinned
dependency; a protocol change happens here, gets a tag, and core bumps the pin.

## Contracts

| contract | what it does |
|---|---|
| `P2FluxSplitter` | one-time payments: settles a payment in a single transaction, splitting the fee from the merchant's share. Holds no balance between calls; no withdrawals, no custody, no upgrade path. |
| `P2FluxRecurring` | recurring payments: charges a customer-signed EIP-712 authorization once per period, reimbursing the relayer's measured gas cost. Not upgradeable, not proxied, no `delegatecall`. |

Both are immutable once deployed. The only mutable value in either is `P2FluxRecurring.relayer`,
rotatable by the immutable `admin` so a compromised hot key can be replaced without redeploying.

## Using the TypeScript definitions

```ts
import { recurringAbi, recurringTypedData, RECURRING_FEE_BPS } from '@p2flux/contracts/recurring'
import { splitterAbi, paymentIdFor } from '@p2flux/contracts/splitter'
import { BASE_SEPOLIA, usdc, formatUsdc } from '@p2flux/contracts/addresses'
import { erc20Abi } from '@p2flux/contracts/abi'
```

Raw ABIs, if you would rather not take the package: `abi/P2FluxRecurring.json`,
`abi/P2FluxSplitter.json`. They are build output of the `.sol` files here — `npm run abi:check`
fails if they have drifted from a fresh compile.

The TypeScript ABIs in `src/` are hand-written subsets rather than the full compiled artifact, kept
honest by the tests in `test/`: `recurring.test.ts` pins every EIP-712 hash and economic constant
against the deployed bytecode, so a mirror that disagrees with the contract fails the suite.

## Build and test

```bash
npm install
npm run compile      # solc 0.8.26 -> out/
npm test             # compiles, then runs the suite against anvil
npm run abi:check    # committed ABIs match a fresh compile
npm run build        # TypeScript -> dist/
```

`npm test` needs [Foundry](https://book.getfoundry.sh/)'s `anvil` on your `PATH`. It is used purely
as a local EVM to test against — the build system is solc via npm, so there is no Foundry or Hardhat
project to configure.

`dist/` is committed on release tags so consumers can install straight from a git tag without
running install scripts. It is build output; edit `src/`.

## Deployments

Constants for both networks live in `src/addresses.ts`.

**Base Mainnet (chainId 8453) — live:**

| Contract | Address | Verified |
|---|---|---|
| P2FluxSplitter | `0x5A3bD0945cd0C80B124870881dE49a717D20E0D0` | [Sourcify exact_match](https://repo.sourcify.dev/8453/0x5A3bD0945cd0C80B124870881dE49a717D20E0D0) · [BaseScan](https://basescan.org/address/0x5A3bD0945cd0C80B124870881dE49a717D20E0D0) |
| P2FluxRecurring | `0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975` | [Sourcify exact_match](https://repo.sourcify.dev/8453/0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975) · [BaseScan](https://basescan.org/address/0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975) |
| USDC (Circle, native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | canonical |

Base Sepolia (chainId 84532) remains the test deployment. Deployment tooling that signs with
a live key is deliberately not here — it belongs with the operator, in the private infrastructure.

## License

MIT.
