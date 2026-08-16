/** Base Sepolia (chainId 84532). Verified live on-chain 2026-08-12. */
export const BASE_SEPOLIA = {
    chainId: 84532,
    /** Circle USDC, FiatTokenV2_2, 6 decimals. */
    usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
    explorer: 'https://sepolia.basescan.org',
};
export const USDC_DECIMALS = 6;
/** 1 USDC = 1_000_000 base units. */
export const usdc = (amount) => {
    const [whole, frac = ''] = amount.split('.');
    return BigInt(whole + frac.padEnd(USDC_DECIMALS, '0').slice(0, USDC_DECIMALS));
};
export const formatUsdc = (value) => {
    const s = value.toString().padStart(USDC_DECIMALS + 1, '0');
    return `${s.slice(0, -USDC_DECIMALS)}.${s.slice(-USDC_DECIMALS)}`;
};
export const txLink = (hash) => `${BASE_SEPOLIA.explorer}/tx/${hash}`;
