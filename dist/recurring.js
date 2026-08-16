import { hashTypedData } from 'viem';
import { usdc } from './addresses.js';
/** P2Flux profit only. Never funds gas - that is NETWORK_FEE plus the reimbursement. */
export const RECURRING_FEE_BPS = 200n;
/** Mirrors `GAS_REIMBURSEMENT_HARD_CAP` in the contract (6-decimal token units). */
export const GAS_REIMBURSEMENT_HARD_CAP = usdc('0.05');
/**
 * Mirrors `NETWORK_FEE`: a flat per-charge network/infrastructure fee, deducted from the signed
 * amount alongside the profit fee. The merchant funds it out of proceeds; the customer's debit is
 * unaffected. It goes to the gas treasury, never to the profit wallet.
 */
export const RECURRING_NETWORK_FEE = usdc('0.10');
export const recurringFee = (amount) => (amount * RECURRING_FEE_BPS) / 10000n;
/** What the merchant actually receives: the commercial amount less both fees. */
export const recurringNet = (amount) => amount - recurringFee(amount) - RECURRING_NETWORK_FEE;
/**
 * The smallest amount that still leaves the merchant something.
 *
 * The contract refuses `amount <= fee + NETWORK_FEE`, so this searches up from the fee floor rather
 * than hardcoding a figure that could drift when a fee constant changes. The answer is a handful of
 * units away, so the loop is trivial.
 */
export const minRecurringAmount = () => {
    let amount = RECURRING_NETWORK_FEE;
    while (recurringNet(amount) < 1n)
        amount++;
    return amount;
};
/** 128 random bits: two subscriptions with identical terms stay distinguishable and independent. */
export const randomSalt = () => BigInt(`0x${Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString('hex')}`);
export const RECURRING_TYPES = {
    RecurringAuthorization: [
        { name: 'payer', type: 'address' },
        { name: 'recipient', type: 'address' },
        { name: 'token', type: 'address' },
        { name: 'amount', type: 'uint256' },
        { name: 'period', type: 'uint48' },
        { name: 'start', type: 'uint48' },
        { name: 'end', type: 'uint48' },
        { name: 'salt', type: 'bytes32' },
        { name: 'maxGasReimbursement', type: 'uint256' },
    ],
};
export const recurringDomain = (chainId, contract) => ({
    name: 'P2FluxRecurring',
    version: '1',
    chainId,
    verifyingContract: contract,
});
/** The exact typed data a wallet signs. Must hash identically to the contract's subscriptionId. */
export const recurringTypedData = (auth, chainId, contract) => ({
    domain: recurringDomain(chainId, contract),
    types: RECURRING_TYPES,
    primaryType: 'RecurringAuthorization',
    message: {
        payer: auth.payer,
        recipient: auth.recipient,
        token: auth.token,
        amount: auth.amount,
        period: auth.period,
        start: auth.start,
        end: auth.end,
        salt: (`0x${auth.salt.toString(16).padStart(64, '0')}`),
        maxGasReimbursement: auth.maxGasReimbursement,
    },
});
/** The auth in the shape viem's ABI encoder expects (salt as bytes32 hex). */
export const abiAuth = (auth) => ({
    payer: auth.payer,
    recipient: auth.recipient,
    token: auth.token,
    amount: auth.amount,
    period: auth.period,
    start: auth.start,
    end: auth.end,
    salt: (`0x${auth.salt.toString(16).padStart(64, '0')}`),
    maxGasReimbursement: auth.maxGasReimbursement,
});
/** Deterministic subscription id: the EIP-712 digest, exactly as the contract computes it. */
export const recurringSubscriptionId = (auth, chainId, contract) => hashTypedData(recurringTypedData(auth, chainId, contract));
const authTuple = {
    type: 'tuple',
    name: 'auth',
    components: [
        { name: 'payer', type: 'address' },
        { name: 'recipient', type: 'address' },
        { name: 'token', type: 'address' },
        { name: 'amount', type: 'uint256' },
        { name: 'period', type: 'uint48' },
        { name: 'start', type: 'uint48' },
        { name: 'end', type: 'uint48' },
        { name: 'salt', type: 'bytes32' },
        { name: 'maxGasReimbursement', type: 'uint256' },
    ],
};
export const recurringAbi = [
    {
        type: 'function',
        name: 'charge',
        stateMutability: 'nonpayable',
        inputs: [authTuple, { name: 'signature', type: 'bytes' }, { name: 'gasReimbursement', type: 'uint256' }],
        outputs: [],
    },
    { type: 'function', name: 'revoke', stateMutability: 'nonpayable', inputs: [authTuple], outputs: [] },
    {
        type: 'function',
        name: 'subscriptionId',
        stateMutability: 'view',
        inputs: [authTuple],
        outputs: [{ type: 'bytes32' }],
    },
    {
        type: 'function',
        name: 'currentPeriod',
        stateMutability: 'view',
        inputs: [authTuple],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'isChargeable',
        stateMutability: 'view',
        inputs: [authTuple],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'lastChargedPeriodPlusOne',
        stateMutability: 'view',
        inputs: [{ type: 'bytes32' }],
        outputs: [{ type: 'uint256' }],
    },
    { type: 'function', name: 'revoked', stateMutability: 'view', inputs: [{ type: 'bytes32' }], outputs: [{ type: 'bool' }] },
    { type: 'function', name: 'relayer', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'feeWallet', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'admin', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'setRelayer', stateMutability: 'nonpayable', inputs: [{ type: 'address' }], outputs: [] },
    {
        type: 'function',
        name: 'GAS_REIMBURSEMENT_HARD_CAP',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
    { type: 'function', name: 'FEE_BPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint16' }] },
    { type: 'function', name: 'NETWORK_FEE', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'gasTreasury', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'supportedToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    {
        type: 'event',
        name: 'SubscriptionCharged',
        inputs: [
            { name: 'subscriptionId', type: 'bytes32', indexed: true },
            { name: 'payer', type: 'address', indexed: true },
            { name: 'recipient', type: 'address', indexed: true },
            { name: 'periodIndex', type: 'uint256' },
            { name: 'net', type: 'uint256' },
            { name: 'fee', type: 'uint256' },
            { name: 'networkFee', type: 'uint256' },
            { name: 'gasReimbursement', type: 'uint256' },
        ],
    },
    {
        type: 'event',
        name: 'SubscriptionRevoked',
        inputs: [
            { name: 'subscriptionId', type: 'bytes32', indexed: true },
            { name: 'payer', type: 'address', indexed: true },
        ],
    },
    { type: 'event', name: 'RelayerChanged', inputs: [{ name: 'relayer', type: 'address' }] },
    { type: 'error', name: 'ZeroAddress', inputs: [] },
    { type: 'error', name: 'ZeroAmount', inputs: [] },
    { type: 'error', name: 'ZeroPeriod', inputs: [] },
    { type: 'error', name: 'InvalidEnd', inputs: [] },
    { type: 'error', name: 'NotAdmin', inputs: [] },
    { type: 'error', name: 'NotStarted', inputs: [] },
    { type: 'error', name: 'Expired', inputs: [] },
    { type: 'error', name: 'Revoked', inputs: [] },
    { type: 'error', name: 'AlreadyRevoked', inputs: [] },
    { type: 'error', name: 'NotPayer', inputs: [] },
    { type: 'error', name: 'InvalidSignature', inputs: [] },
    { type: 'error', name: 'AlreadyChargedThisPeriod', inputs: [] },
    { type: 'error', name: 'GasReimbursementTooHigh', inputs: [] },
    { type: 'error', name: 'TokenNotSupported', inputs: [] },
    { type: 'error', name: 'AmountTooSmall', inputs: [] },
];
export const toWire = (auth) => ({
    payer: auth.payer,
    recipient: auth.recipient,
    token: auth.token,
    amount: auth.amount.toString(),
    period: auth.period,
    start: auth.start,
    end: auth.end,
    salt: auth.salt.toString(),
    max_gas_reimbursement: auth.maxGasReimbursement.toString(),
});
export const fromWire = (wire) => ({
    payer: wire.payer.toLowerCase(),
    recipient: wire.recipient.toLowerCase(),
    token: wire.token.toLowerCase(),
    amount: BigInt(wire.amount),
    period: wire.period,
    start: wire.start,
    end: wire.end,
    salt: BigInt(wire.salt),
    maxGasReimbursement: BigInt(wire.max_gas_reimbursement),
});
