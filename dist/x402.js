/*
 * x402 settlement: AI agents paying for APIs, content and tools with an unmodified x402 client, settled
 * through P2FluxX402Splitter so the P2Flux fee is split out on-chain. See contracts/P2FluxX402Splitter.sol.
 */
/** P2Flux's fee on an x402 payment: 1%, never less than the deployment's `MIN_FEE`. */
export const X402_FEE_BPS = 100n;
/** Mirrors `maxFee` in the contract: the most the relayer may take from a payment of `amount`. */
export const x402MaxFee = (amount, minFee) => {
    const fee = (amount * X402_FEE_BPS) / 10000n;
    return fee > minFee ? fee : minFee;
};
/** Uniswap Permit2: the same address on every chain. */
export const PERMIT2 = '0x000000000022D473030F116dDEE9F6B43aC78BA3';
/**
 * x402's `upto` proxy (x402-foundation/x402 x402UptoPermit2Proxy). One CREATE2 address, verified on
 * Base and Base Sepolia (identical code hash) on 2026-09-29; the x402 client hardcodes it as the
 * Permit2 spender, so it is not configurable.
 */
export const X402_UPTO_PROXY = '0x4020A4f3b7b90ccA423B9fabCc0CE57C6C240002';
/**
 * EIP-712 typed data for USDC's `TransferWithAuthorization`: what an x402 `exact` client signs, with
 * `to` = the seller's vault. For tests and tooling - in production the agent's own client builds it.
 */
export const transferWithAuthorizationTypedData = (args) => ({
    domain: {
        name: args.tokenName,
        version: args.tokenVersion,
        chainId: args.chainId,
        verifyingContract: args.token,
    },
    types: {
        TransferWithAuthorization: [
            { name: 'from', type: 'address' },
            { name: 'to', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'validAfter', type: 'uint256' },
            { name: 'validBefore', type: 'uint256' },
            { name: 'nonce', type: 'bytes32' },
        ],
    },
    primaryType: 'TransferWithAuthorization',
    message: {
        from: args.from,
        to: args.to,
        value: args.value,
        validAfter: 0n,
        validBefore: args.validBefore,
        nonce: args.nonce,
    },
});
/**
 * The full P2FluxX402Splitter ABI. Generated from the compiled contract rather than hand-picked, and
 * test/x402.test.ts fails if it ever differs from a fresh compile.
 */
export const p2fluxX402SplitterAbi = [
    {
        inputs: [
            { internalType: 'address', name: '_supportedToken', type: 'address' },
            { internalType: 'address', name: '_feeWallet', type: 'address' },
            { internalType: 'address', name: '_relayer', type: 'address' },
            { internalType: 'address', name: '_uptoProxy', type: 'address' },
            { internalType: 'uint256', name: '_minFee', type: 'uint256' },
        ],
        stateMutability: 'nonpayable',
        type: 'constructor',
    },
    { inputs: [], name: 'AmountTooSmall', type: 'error' },
    { inputs: [], name: 'FeeTooHigh', type: 'error' },
    { inputs: [], name: 'NotAContract', type: 'error' },
    { inputs: [], name: 'NotRelayer', type: 'error' },
    {
        inputs: [{ internalType: 'bytes32', name: 'paymentId', type: 'bytes32' }],
        name: 'PaymentAlreadyProcessed',
        type: 'error',
    },
    { inputs: [], name: 'ReentrancyGuardReentrantCall', type: 'error' },
    { inputs: [], name: 'TokenNotSupported', type: 'error' },
    { inputs: [], name: 'UnexpectedAmount', type: 'error' },
    { inputs: [], name: 'WrongDestination', type: 'error' },
    { inputs: [], name: 'ZeroAddress', type: 'error' },
    { inputs: [], name: 'ZeroAmount', type: 'error' },
    {
        anonymous: false,
        inputs: [
            { indexed: true, internalType: 'address', name: 'recipient', type: 'address' },
            { indexed: false, internalType: 'uint256', name: 'net', type: 'uint256' },
            { indexed: false, internalType: 'uint256', name: 'fee', type: 'uint256' },
        ],
        name: 'Flushed',
        type: 'event',
    },
    {
        anonymous: false,
        inputs: [
            { indexed: true, internalType: 'bytes32', name: 'ref', type: 'bytes32' },
            { indexed: true, internalType: 'address', name: 'recipient', type: 'address' },
            { indexed: true, internalType: 'address', name: 'token', type: 'address' },
            { indexed: false, internalType: 'uint256', name: 'net', type: 'uint256' },
            { indexed: false, internalType: 'uint256', name: 'fee', type: 'uint256' },
        ],
        name: 'Paid',
        type: 'event',
    },
    {
        anonymous: false,
        inputs: [{ indexed: true, internalType: 'bytes32', name: 'paymentId', type: 'bytes32' }],
        name: 'PaymentSettled',
        type: 'event',
    },
    {
        inputs: [],
        name: 'FEE_BPS',
        outputs: [{ internalType: 'uint16', name: '', type: 'uint16' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'MIN_FEE',
        outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'PAYMENT_DOMAIN',
        outputs: [{ internalType: 'bytes32', name: '', type: 'bytes32' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'feeWallet',
        outputs: [{ internalType: 'address', name: '', type: 'address' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [{ internalType: 'address', name: 'recipient', type: 'address' }],
        name: 'flush',
        outputs: [],
        stateMutability: 'nonpayable',
        type: 'function',
    },
    {
        inputs: [
            { internalType: 'address', name: 'token', type: 'address' },
            { internalType: 'address', name: 'recipient', type: 'address' },
            { internalType: 'uint256', name: 'amount', type: 'uint256' },
            { internalType: 'bytes32', name: 'ref', type: 'bytes32' },
        ],
        name: 'isPaymentProcessed',
        outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [{ internalType: 'uint256', name: 'amount', type: 'uint256' }],
        name: 'maxFee',
        outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [
            { internalType: 'address', name: 'token', type: 'address' },
            { internalType: 'address', name: 'recipient', type: 'address' },
            { internalType: 'uint256', name: 'amount', type: 'uint256' },
            { internalType: 'bytes32', name: 'ref', type: 'bytes32' },
        ],
        name: 'paymentId',
        outputs: [{ internalType: 'bytes32', name: '', type: 'bytes32' }],
        stateMutability: 'pure',
        type: 'function',
    },
    {
        inputs: [{ internalType: 'bytes32', name: '', type: 'bytes32' }],
        name: 'processedPayments',
        outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'relayer',
        outputs: [{ internalType: 'address', name: '', type: 'address' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [
            { internalType: 'address', name: 'recipient', type: 'address' },
            { internalType: 'uint256', name: 'fee', type: 'uint256' },
            {
                components: [
                    {
                        components: [
                            { internalType: 'address', name: 'token', type: 'address' },
                            { internalType: 'uint256', name: 'amount', type: 'uint256' },
                        ],
                        internalType: 'struct ISignatureTransfer.TokenPermissions',
                        name: 'permitted',
                        type: 'tuple',
                    },
                    { internalType: 'uint256', name: 'nonce', type: 'uint256' },
                    { internalType: 'uint256', name: 'deadline', type: 'uint256' },
                ],
                internalType: 'struct ISignatureTransfer.PermitTransferFrom',
                name: 'permit',
                type: 'tuple',
            },
            { internalType: 'uint256', name: 'amount', type: 'uint256' },
            { internalType: 'address', name: 'owner', type: 'address' },
            {
                components: [
                    { internalType: 'address', name: 'to', type: 'address' },
                    { internalType: 'address', name: 'facilitator', type: 'address' },
                    { internalType: 'uint256', name: 'validAfter', type: 'uint256' },
                ],
                internalType: 'struct IX402UptoPermit2Proxy.Witness',
                name: 'witness',
                type: 'tuple',
            },
            { internalType: 'bytes', name: 'signature', type: 'bytes' },
        ],
        name: 'settleUpto',
        outputs: [],
        stateMutability: 'nonpayable',
        type: 'function',
    },
    {
        inputs: [
            { internalType: 'address', name: 'recipient', type: 'address' },
            { internalType: 'uint256', name: 'fee', type: 'uint256' },
            {
                components: [
                    { internalType: 'uint256', name: 'value', type: 'uint256' },
                    { internalType: 'uint256', name: 'deadline', type: 'uint256' },
                    { internalType: 'bytes32', name: 'r', type: 'bytes32' },
                    { internalType: 'bytes32', name: 's', type: 'bytes32' },
                    { internalType: 'uint8', name: 'v', type: 'uint8' },
                ],
                internalType: 'struct IX402UptoPermit2Proxy.EIP2612Permit',
                name: 'permit2612',
                type: 'tuple',
            },
            {
                components: [
                    {
                        components: [
                            { internalType: 'address', name: 'token', type: 'address' },
                            { internalType: 'uint256', name: 'amount', type: 'uint256' },
                        ],
                        internalType: 'struct ISignatureTransfer.TokenPermissions',
                        name: 'permitted',
                        type: 'tuple',
                    },
                    { internalType: 'uint256', name: 'nonce', type: 'uint256' },
                    { internalType: 'uint256', name: 'deadline', type: 'uint256' },
                ],
                internalType: 'struct ISignatureTransfer.PermitTransferFrom',
                name: 'permit',
                type: 'tuple',
            },
            { internalType: 'uint256', name: 'amount', type: 'uint256' },
            { internalType: 'address', name: 'owner', type: 'address' },
            {
                components: [
                    { internalType: 'address', name: 'to', type: 'address' },
                    { internalType: 'address', name: 'facilitator', type: 'address' },
                    { internalType: 'uint256', name: 'validAfter', type: 'uint256' },
                ],
                internalType: 'struct IX402UptoPermit2Proxy.Witness',
                name: 'witness',
                type: 'tuple',
            },
            { internalType: 'bytes', name: 'signature', type: 'bytes' },
        ],
        name: 'settleUptoWithPermit',
        outputs: [],
        stateMutability: 'nonpayable',
        type: 'function',
    },
    {
        inputs: [
            { internalType: 'address', name: 'recipient', type: 'address' },
            { internalType: 'uint256', name: 'fee', type: 'uint256' },
            {
                components: [
                    { internalType: 'address', name: 'from', type: 'address' },
                    { internalType: 'uint256', name: 'value', type: 'uint256' },
                    { internalType: 'uint256', name: 'validAfter', type: 'uint256' },
                    { internalType: 'uint256', name: 'validBefore', type: 'uint256' },
                    { internalType: 'bytes32', name: 'nonce', type: 'bytes32' },
                ],
                internalType: 'struct P2FluxX402Splitter.Authorization',
                name: 'a',
                type: 'tuple',
            },
            { internalType: 'bytes', name: 'signature', type: 'bytes' },
        ],
        name: 'settleWithAuthorization',
        outputs: [],
        stateMutability: 'nonpayable',
        type: 'function',
    },
    {
        inputs: [],
        name: 'supportedToken',
        outputs: [{ internalType: 'address', name: '', type: 'address' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [],
        name: 'uptoProxy',
        outputs: [{ internalType: 'contract IX402UptoPermit2Proxy', name: '', type: 'address' }],
        stateMutability: 'view',
        type: 'function',
    },
    {
        inputs: [{ internalType: 'address', name: 'recipient', type: 'address' }],
        name: 'vaultOf',
        outputs: [{ internalType: 'address', name: '', type: 'address' }],
        stateMutability: 'view',
        type: 'function',
    },
];
