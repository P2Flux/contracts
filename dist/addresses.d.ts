/** Base Sepolia (chainId 84532). Verified live on-chain 2026-08-12. */
export declare const BASE_SEPOLIA: {
    readonly chainId: 84532;
    /** Circle USDC, FiatTokenV2_2, 6 decimals. */
    readonly usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
    readonly explorer: "https://sepolia.basescan.org";
};
/**
 * Base Mainnet (chainId 8453).
 *
 * The USDC address is Circle's native issue on Base, published at circle.com/usdc and mirrored by
 * Base's own docs - the one address real money lives at. Everything signed against it is real:
 * there is no faucet, no reset, and no second chance on a typo, which is why it is a named constant
 * here rather than something an environment file spells out by hand.
 */
export declare const BASE_MAINNET: {
    readonly chainId: 8453;
    /** Circle USDC, native (not USDbC), 6 decimals. */
    readonly usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
    /** P2FluxSplitter, deployed 2026-08-23 (tx 0x159fabcf...19cf2), Sourcify exact_match. */
    readonly splitter: "0x5A3bD0945cd0C80B124870881dE49a717D20E0D0";
    /** The block the splitter deployed in - the canonical floor for payment-recovery log searches. */
    readonly splitterDeployBlock: 50362015;
    /** P2FluxRecurring, deployed 2026-08-23 (tx 0xf849fd1d...ba5ce), Sourcify exact_match. */
    readonly recurring: "0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975";
    readonly explorer: "https://basescan.org";
};
/** The chains this protocol is deployed to, by id. */
export declare const CHAINS: {
    readonly 84532: {
        readonly chainId: 84532;
        /** Circle USDC, FiatTokenV2_2, 6 decimals. */
        readonly usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
        readonly explorer: "https://sepolia.basescan.org";
    };
    readonly 8453: {
        readonly chainId: 8453;
        /** Circle USDC, native (not USDbC), 6 decimals. */
        readonly usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
        /** P2FluxSplitter, deployed 2026-08-23 (tx 0x159fabcf...19cf2), Sourcify exact_match. */
        readonly splitter: "0x5A3bD0945cd0C80B124870881dE49a717D20E0D0";
        /** The block the splitter deployed in - the canonical floor for payment-recovery log searches. */
        readonly splitterDeployBlock: 50362015;
        /** P2FluxRecurring, deployed 2026-08-23 (tx 0xf849fd1d...ba5ce), Sourcify exact_match. */
        readonly recurring: "0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975";
        readonly explorer: "https://basescan.org";
    };
};
export declare const USDC_DECIMALS = 6;
/** 1 USDC = 1_000_000 base units. */
export declare const usdc: (amount: string) => bigint;
export declare const formatUsdc: (value: bigint) => string;
/**
 * An explorer link for a transaction. Chain-aware, because a Sepolia link to a Mainnet transaction
 * is a 404 that reads like a missing payment. Defaults to Sepolia for the existing dev tooling.
 */
export declare const txLink: (hash: string, chainId?: number) => string;
