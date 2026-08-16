/** Base Sepolia (chainId 84532). Verified live on-chain 2026-08-12. */
export declare const BASE_SEPOLIA: {
    readonly chainId: 84532;
    /** Circle USDC, FiatTokenV2_2, 6 decimals. */
    readonly usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
    readonly explorer: "https://sepolia.basescan.org";
};
export declare const USDC_DECIMALS = 6;
/** 1 USDC = 1_000_000 base units. */
export declare const usdc: (amount: string) => bigint;
export declare const formatUsdc: (value: bigint) => string;
export declare const txLink: (hash: string) => string;
