/** Base Sepolia (chainId 84532). Verified live on-chain 2026-08-12. */
export const BASE_SEPOLIA = {
    chainId: 84532,
    /** Circle USDC, FiatTokenV2_2, 6 decimals. */
    usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e',
    explorer: 'https://sepolia.basescan.org',
};
/**
 * Base Mainnet (chainId 8453).
 *
 * The USDC address is Circle's native issue on Base, published at circle.com/usdc and mirrored by
 * Base's own docs - the one address real money lives at. Everything signed against it is real:
 * there is no faucet, no reset, and no second chance on a typo, which is why it is a named constant
 * here rather than something an environment file spells out by hand.
 */
export const BASE_MAINNET = {
    chainId: 8453,
    /** Circle USDC, native (not USDbC), 6 decimals. */
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    /** P2FluxSplitter, deployed 2026-08-23 (tx 0x159fabcf...19cf2), Sourcify exact_match. */
    splitter: '0x5A3bD0945cd0C80B124870881dE49a717D20E0D0',
    /** The block the splitter deployed in - the canonical floor for payment-recovery log searches. */
    splitterDeployBlock: 50362015,
    /** P2FluxRecurring, deployed 2026-08-23 (tx 0xf849fd1d...ba5ce), Sourcify exact_match. */
    recurring: '0xb415A9910Ef627e3bEF10F5Cb9DC92a3271e0975',
    /**
     * P2FluxSponsoredSplitter, deployed 2026-09-06 from manifest sha256 827b76fa…b2034
     * (tx 0xb203550c...b1f5, deployer nonce 2). One-time payments whose network fee the buyer pays in
     * USDC; the relayer sends the transaction. Immutables read back and verified against the manifest.
     */
    sponsoredSplitter: '0x95E18ec05D4282acB3aab7aD60325bA4EEeEa8df',
    /** The block the sponsored splitter deployed in - the floor for sponsored payment-recovery searches. */
    sponsoredSplitterDeployBlock: 50966621,
    /**
     * P2FluxGasSponsor, deployed 2026-09-06 from the same manifest (tx 0x7d8031bf...3bf5, deployer
     * nonce 3). Subscription signup, allowance restore and allowance removal for a customer holding no ETH.
     */
    gasSponsor: '0xD1DDAaa301403d18fD4A23Fc69493ef48af90285',
    gasSponsorDeployBlock: 50966742,
    explorer: 'https://basescan.org',
};
/** The chains this protocol is deployed to, by id. */
export const CHAINS = {
    [BASE_SEPOLIA.chainId]: BASE_SEPOLIA,
    [BASE_MAINNET.chainId]: BASE_MAINNET,
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
/**
 * An explorer link for a transaction. Chain-aware, because a Sepolia link to a Mainnet transaction
 * is a 404 that reads like a missing payment. Defaults to Sepolia for the existing dev tooling.
 */
export const txLink = (hash, chainId = BASE_SEPOLIA.chainId) => `${(CHAINS[chainId] ?? BASE_SEPOLIA).explorer}/tx/${hash}`;
