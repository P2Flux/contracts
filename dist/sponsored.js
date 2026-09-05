import { encodeAbiParameters, keccak256, toBytes } from 'viem';
/**
 * The sponsored contracts, recomputed off chain.
 *
 * Everything here mirrors a `public view` function on the deployed contract, so the API, the hosted
 * checkout and the contract derive the same authorization nonce from the same terms. If they ever
 * disagreed, the token would reject the signature - which is the failure this file exists to
 * prevent, and which the contract test suite asserts against the real deployment.
 */
/** Must match `SPONSOR_PAY_DOMAIN` in contracts/P2FluxSponsoredSplitter.sol. */
export const SPONSOR_PAY_DOMAIN = keccak256(toBytes('P2FLUX_SPONSORED_PAYMENT_V1'));
/** Must match `SPONSOR_DOMAIN` in contracts/P2FluxGasSponsor.sol. */
export const SPONSOR_DOMAIN = keccak256(toBytes('P2FLUX_GAS_SPONSOR_V1'));
/** Must match `OPERATION_PERMIT` in contracts/P2FluxGasSponsor.sol. */
export const OPERATION_PERMIT = keccak256(toBytes('PERMIT'));
/** The token authorization nonce a sponsored payment's terms produce. */
export const sponsoredPaymentNonce = (args) => keccak256(encodeAbiParameters([
    { type: 'bytes32' },
    { type: 'uint256' },
    { type: 'address' },
    { type: 'address' },
    { type: 'address' },
    { type: 'address' },
    { type: 'uint256' },
    { type: 'bytes32' },
    { type: 'uint256' },
    { type: 'uint256' },
    { type: 'uint256' },
], [
    SPONSOR_PAY_DOMAIN,
    BigInt(args.chainId),
    args.splitter,
    args.token,
    args.payment.payer,
    args.payment.recipient,
    args.payment.amount,
    args.payment.ref,
    args.payment.networkFee,
    args.serviceFee,
    args.payment.validBefore,
]));
export const sponsorPermitNonce = (args) => keccak256(encodeAbiParameters([
    { type: 'bytes32' },
    { type: 'uint256' },
    { type: 'address' },
    { type: 'address' },
    { type: 'address' },
    { type: 'bytes32' },
    { type: 'address' },
    { type: 'uint256' },
    { type: 'uint256' },
    { type: 'uint256' },
    { type: 'uint256' },
], [
    SPONSOR_DOMAIN,
    BigInt(args.chainId),
    args.sponsor,
    args.token,
    args.payer,
    OPERATION_PERMIT,
    args.spender,
    args.allowanceValue,
    args.allowanceDeadline,
    args.networkFee,
    args.validBefore,
]));
/** What the buyer's wallet is debited for a sponsored payment. */
export const sponsoredTotalDebit = (amount, networkFee, serviceFee) => amount + networkFee + serviceFee;
/** Hand-written subset of P2FluxSponsoredSplitter; the compiled artifact lives in gitignored out/. */
export const sponsoredSplitterAbi = [
    {
        type: 'function',
        name: 'payWithAuthorization',
        stateMutability: 'nonpayable',
        inputs: [
            {
                name: 'p',
                type: 'tuple',
                components: [
                    { name: 'payer', type: 'address' },
                    { name: 'recipient', type: 'address' },
                    { name: 'amount', type: 'uint256' },
                    { name: 'ref', type: 'bytes32' },
                    { name: 'networkFee', type: 'uint256' },
                    { name: 'validBefore', type: 'uint256' },
                ],
            },
            { name: 'v', type: 'uint8' },
            { name: 'r', type: 'bytes32' },
            { name: 's', type: 'bytes32' },
        ],
        outputs: [],
    },
    {
        type: 'function',
        name: 'isPaymentProcessed',
        stateMutability: 'view',
        inputs: [
            { name: 'token', type: 'address' },
            { name: 'recipient', type: 'address' },
            { name: 'amount', type: 'uint256' },
            { name: 'ref', type: 'bytes32' },
        ],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'authorizationNonce',
        stateMutability: 'view',
        inputs: [
            {
                name: 'p',
                type: 'tuple',
                components: [
                    { name: 'payer', type: 'address' },
                    { name: 'recipient', type: 'address' },
                    { name: 'amount', type: 'uint256' },
                    { name: 'ref', type: 'bytes32' },
                    { name: 'networkFee', type: 'uint256' },
                    { name: 'validBefore', type: 'uint256' },
                ],
            },
        ],
        outputs: [{ type: 'bytes32' }],
    },
    { type: 'function', name: 'GAS_SERVICE_FEE', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    {
        type: 'function',
        name: 'MAX_NETWORK_FEE_HARD_CAP',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
    { type: 'function', name: 'ONE_TIME_BPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint16' }] },
    { type: 'function', name: 'supportedToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'feeWallet', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'gasTreasury', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'relayer', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'error', name: 'ZeroAddress', inputs: [] },
    { type: 'error', name: 'ZeroAmount', inputs: [] },
    { type: 'error', name: 'AmountTooSmall', inputs: [] },
    { type: 'error', name: 'NotRelayer', inputs: [] },
    { type: 'error', name: 'NetworkFeeTooHigh', inputs: [] },
    { type: 'error', name: 'PaymentAlreadyProcessed', inputs: [{ name: 'paymentId', type: 'bytes32' }] },
    { type: 'error', name: 'ResidualBalance', inputs: [] },
    {
        type: 'event',
        name: 'SponsoredPaid',
        inputs: [
            { name: 'ref', type: 'bytes32', indexed: true },
            { name: 'recipient', type: 'address', indexed: true },
            { name: 'payer', type: 'address', indexed: true },
            { name: 'net', type: 'uint256' },
            { name: 'fee', type: 'uint256' },
            { name: 'networkFee', type: 'uint256' },
            { name: 'serviceFee', type: 'uint256' },
        ],
    },
    {
        type: 'event',
        name: 'PaymentSettled',
        inputs: [{ name: 'paymentId', type: 'bytes32', indexed: true }],
    },
];
/** Hand-written subset of P2FluxGasSponsor. */
export const gasSponsorAbi = [
    {
        type: 'function',
        name: 'sponsorPermit',
        stateMutability: 'nonpayable',
        inputs: [
            {
                name: 'sponsorship',
                type: 'tuple',
                components: [
                    { name: 'payer', type: 'address' },
                    { name: 'spender', type: 'address' },
                    { name: 'allowanceValue', type: 'uint256' },
                    { name: 'allowanceDeadline', type: 'uint256' },
                    { name: 'networkFee', type: 'uint256' },
                    { name: 'validBefore', type: 'uint256' },
                ],
            },
            { name: 'permitV', type: 'uint8' },
            { name: 'permitR', type: 'bytes32' },
            { name: 'permitS', type: 'bytes32' },
            { name: 'feeV', type: 'uint8' },
            { name: 'feeR', type: 'bytes32' },
            { name: 'feeS', type: 'bytes32' },
        ],
        outputs: [],
    },
    {
        type: 'function',
        name: 'authorizationNonce',
        stateMutability: 'view',
        inputs: [
            {
                name: 'sponsorship',
                type: 'tuple',
                components: [
                    { name: 'payer', type: 'address' },
                    { name: 'spender', type: 'address' },
                    { name: 'allowanceValue', type: 'uint256' },
                    { name: 'allowanceDeadline', type: 'uint256' },
                    { name: 'networkFee', type: 'uint256' },
                    { name: 'validBefore', type: 'uint256' },
                ],
            },
        ],
        outputs: [{ type: 'bytes32' }],
    },
    {
        type: 'function',
        name: 'settledSponsorships',
        stateMutability: 'view',
        inputs: [{ type: 'bytes32' }],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'MAX_SPONSOR_FEE_HARD_CAP',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
    { type: 'function', name: 'supportedToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'gasTreasury', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'relayer', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'error', name: 'ZeroAddress', inputs: [] },
    { type: 'error', name: 'NotRelayer', inputs: [] },
    { type: 'error', name: 'NetworkFeeTooHigh', inputs: [] },
    {
        type: 'error',
        name: 'SponsorshipAlreadySettled',
        inputs: [{ name: 'authorizationNonce', type: 'bytes32' }],
    },
    { type: 'error', name: 'ResidualBalance', inputs: [] },
    {
        type: 'event',
        name: 'SponsorshipSettled',
        inputs: [
            { name: 'payer', type: 'address', indexed: true },
            { name: 'operation', type: 'bytes32', indexed: true },
            { name: 'spender', type: 'address', indexed: true },
            { name: 'allowanceValue', type: 'uint256' },
            { name: 'networkFee', type: 'uint256' },
            { name: 'authorizationNonce', type: 'bytes32' },
        ],
    },
];
/** EIP-712 typed data for the token's own `ReceiveWithAuthorization`, for wallet signing. */
export const receiveWithAuthorizationTypedData = (args) => ({
    domain: {
        name: args.tokenName,
        version: args.tokenVersion,
        chainId: args.chainId,
        verifyingContract: args.token,
    },
    types: {
        ReceiveWithAuthorization: [
            { name: 'from', type: 'address' },
            { name: 'to', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'validAfter', type: 'uint256' },
            { name: 'validBefore', type: 'uint256' },
            { name: 'nonce', type: 'bytes32' },
        ],
    },
    primaryType: 'ReceiveWithAuthorization',
    message: {
        from: args.from,
        to: args.to,
        value: args.value,
        validAfter: 0n,
        validBefore: args.validBefore,
        nonce: args.nonce,
    },
});
/** EIP-712 typed data for the token's EIP-2612 `permit`, for wallet signing. */
export const permitTypedData = (args) => ({
    domain: {
        name: args.tokenName,
        version: args.tokenVersion,
        chainId: args.chainId,
        verifyingContract: args.token,
    },
    types: {
        Permit: [
            { name: 'owner', type: 'address' },
            { name: 'spender', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    },
    primaryType: 'Permit',
    message: {
        owner: args.owner,
        spender: args.spender,
        value: args.value,
        nonce: args.nonce,
        deadline: args.deadline,
    },
});
