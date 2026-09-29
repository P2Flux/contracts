/** Minimal ERC-20 subset. Recurring contract ABI lives in `recurring.ts`, splitter in `splitter.ts`. */
export const erc20Abi = [
    {
        type: 'function',
        name: 'balanceOf',
        stateMutability: 'view',
        inputs: [{ type: 'address' }],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'allowance',
        stateMutability: 'view',
        inputs: [{ type: 'address' }, { type: 'address' }],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'transfer',
        stateMutability: 'nonpayable',
        inputs: [{ type: 'address' }, { type: 'uint256' }],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'approve',
        stateMutability: 'nonpayable',
        inputs: [{ type: 'address' }, { type: 'uint256' }],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'nonces',
        stateMutability: 'view',
        inputs: [{ type: 'address' }],
        outputs: [{ type: 'uint256' }],
    },
    /* EIP-3009: whether `nonce` of `authorizer` is already used. How the x402 facilitator refuses a
     * replayed authorization before paying gas to find out on-chain. */
    {
        type: 'function',
        name: 'authorizationState',
        stateMutability: 'view',
        inputs: [{ type: 'address' }, { type: 'bytes32' }],
        outputs: [{ type: 'bool' }],
    },
    { type: 'function', name: 'name', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
    /* Asserted at startup: six decimals is baked into every amount this API parses, formats and signs,
     * so a token with any other precision mis-prices by orders of magnitude rather than a little. */
    { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
    { type: 'function', name: 'version', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
    {
        type: 'function',
        name: 'DOMAIN_SEPARATOR',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'bytes32' }],
    },
];
