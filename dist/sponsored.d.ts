import { type Address, type Hex } from 'viem';
/**
 * The sponsored contracts, recomputed off chain.
 *
 * Everything here mirrors a `public view` function on the deployed contract, so the API, the hosted
 * checkout and the contract derive the same authorization nonce from the same terms. If they ever
 * disagreed, the token would reject the signature - which is the failure this file exists to
 * prevent, and which the contract test suite asserts against the real deployment.
 */
/** Must match `SPONSOR_PAY_DOMAIN` in contracts/P2FluxSponsoredSplitter.sol. */
export declare const SPONSOR_PAY_DOMAIN: `0x${string}`;
/** Must match `SPONSOR_DOMAIN` in contracts/P2FluxGasSponsor.sol. */
export declare const SPONSOR_DOMAIN: `0x${string}`;
/** Must match `OPERATION_PERMIT` in contracts/P2FluxGasSponsor.sol. */
export declare const OPERATION_PERMIT: `0x${string}`;
export type SponsoredPayment = {
    payer: Address;
    recipient: Address;
    amount: bigint;
    ref: Hex;
    networkFee: bigint;
    validBefore: bigint;
};
/** The token authorization nonce a sponsored payment's terms produce. */
export declare const sponsoredPaymentNonce: (args: {
    chainId: number;
    splitter: Address;
    token: Address;
    serviceFee: bigint;
    payment: SponsoredPayment;
}) => Hex;
/** The fee-authorization nonce a permit sponsorship's terms produce. */
export declare const sponsorPermitNonce: (args: {
    chainId: number;
    sponsor: Address;
    token: Address;
    payer: Address;
    spender: Address;
    allowanceValue: bigint;
    allowanceDeadline: bigint;
    networkFee: bigint;
    validBefore: bigint;
}) => Hex;
/** What the buyer's wallet is debited for a sponsored payment. */
export declare const sponsoredTotalDebit: (amount: bigint, networkFee: bigint, serviceFee: bigint) => bigint;
/** Hand-written subset of P2FluxSponsoredSplitter; the compiled artifact lives in gitignored out/. */
export declare const sponsoredSplitterAbi: readonly [{
    readonly type: "function";
    readonly name: "payWithAuthorization";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly name: "p";
        readonly type: "tuple";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "ref";
            readonly type: "bytes32";
        }, {
            readonly name: "networkFee";
            readonly type: "uint256";
        }, {
            readonly name: "validBefore";
            readonly type: "uint256";
        }];
    }, {
        readonly name: "v";
        readonly type: "uint8";
    }, {
        readonly name: "r";
        readonly type: "bytes32";
    }, {
        readonly name: "s";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "isPaymentProcessed";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "token";
        readonly type: "address";
    }, {
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly name: "ref";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
    }];
}, {
    readonly type: "function";
    readonly name: "authorizationNonce";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "p";
        readonly type: "tuple";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "ref";
            readonly type: "bytes32";
        }, {
            readonly name: "networkFee";
            readonly type: "uint256";
        }, {
            readonly name: "validBefore";
            readonly type: "uint256";
        }];
    }];
    readonly outputs: readonly [{
        readonly type: "bytes32";
    }];
}, {
    readonly type: "function";
    readonly name: "GAS_SERVICE_FEE";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "MAX_NETWORK_FEE_HARD_CAP";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "ONE_TIME_BPS";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint16";
    }];
}, {
    readonly type: "function";
    readonly name: "supportedToken";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "feeWallet";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "gasTreasury";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "relayer";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "error";
    readonly name: "ZeroAddress";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "ZeroAmount";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "AmountTooSmall";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotRelayer";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NetworkFeeTooHigh";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "PaymentAlreadyProcessed";
    readonly inputs: readonly [{
        readonly name: "paymentId";
        readonly type: "bytes32";
    }];
}, {
    readonly type: "error";
    readonly name: "ResidualBalance";
    readonly inputs: readonly [];
}, {
    readonly type: "event";
    readonly name: "SponsoredPaid";
    readonly inputs: readonly [{
        readonly name: "ref";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "recipient";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "payer";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "net";
        readonly type: "uint256";
    }, {
        readonly name: "fee";
        readonly type: "uint256";
    }, {
        readonly name: "networkFee";
        readonly type: "uint256";
    }, {
        readonly name: "serviceFee";
        readonly type: "uint256";
    }];
}, {
    readonly type: "event";
    readonly name: "PaymentSettled";
    readonly inputs: readonly [{
        readonly name: "paymentId";
        readonly type: "bytes32";
        readonly indexed: true;
    }];
}];
/** Hand-written subset of P2FluxGasSponsor. */
export declare const gasSponsorAbi: readonly [{
    readonly type: "function";
    readonly name: "sponsorPermit";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly name: "payer";
        readonly type: "address";
    }, {
        readonly name: "spender";
        readonly type: "address";
    }, {
        readonly name: "allowanceValue";
        readonly type: "uint256";
    }, {
        readonly name: "allowanceDeadline";
        readonly type: "uint256";
    }, {
        readonly name: "permitV";
        readonly type: "uint8";
    }, {
        readonly name: "permitR";
        readonly type: "bytes32";
    }, {
        readonly name: "permitS";
        readonly type: "bytes32";
    }, {
        readonly name: "networkFee";
        readonly type: "uint256";
    }, {
        readonly name: "validBefore";
        readonly type: "uint256";
    }, {
        readonly name: "feeV";
        readonly type: "uint8";
    }, {
        readonly name: "feeR";
        readonly type: "bytes32";
    }, {
        readonly name: "feeS";
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "authorizationNonce";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly name: "payer";
        readonly type: "address";
    }, {
        readonly name: "spender";
        readonly type: "address";
    }, {
        readonly name: "allowanceValue";
        readonly type: "uint256";
    }, {
        readonly name: "allowanceDeadline";
        readonly type: "uint256";
    }, {
        readonly name: "networkFee";
        readonly type: "uint256";
    }, {
        readonly name: "validBefore";
        readonly type: "uint256";
    }];
    readonly outputs: readonly [{
        readonly type: "bytes32";
    }];
}, {
    readonly type: "function";
    readonly name: "settledSponsorships";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
    }];
}, {
    readonly type: "function";
    readonly name: "MAX_SPONSOR_FEE_HARD_CAP";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "supportedToken";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "gasTreasury";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "relayer";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "error";
    readonly name: "ZeroAddress";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotRelayer";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NetworkFeeTooHigh";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "SponsorshipAlreadySettled";
    readonly inputs: readonly [{
        readonly name: "authorizationNonce";
        readonly type: "bytes32";
    }];
}, {
    readonly type: "error";
    readonly name: "ResidualBalance";
    readonly inputs: readonly [];
}, {
    readonly type: "event";
    readonly name: "SponsorshipSettled";
    readonly inputs: readonly [{
        readonly name: "payer";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "operation";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "spender";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "allowanceValue";
        readonly type: "uint256";
    }, {
        readonly name: "networkFee";
        readonly type: "uint256";
    }, {
        readonly name: "authorizationNonce";
        readonly type: "bytes32";
    }];
}];
/** EIP-712 typed data for the token's own `ReceiveWithAuthorization`, for wallet signing. */
export declare const receiveWithAuthorizationTypedData: (args: {
    chainId: number;
    token: Address;
    tokenName: string;
    tokenVersion: string;
    from: Address;
    to: Address;
    value: bigint;
    validBefore: bigint;
    nonce: Hex;
}) => {
    readonly domain: {
        readonly name: string;
        readonly version: string;
        readonly chainId: number;
        readonly verifyingContract: `0x${string}`;
    };
    readonly types: {
        readonly ReceiveWithAuthorization: readonly [{
            readonly name: "from";
            readonly type: "address";
        }, {
            readonly name: "to";
            readonly type: "address";
        }, {
            readonly name: "value";
            readonly type: "uint256";
        }, {
            readonly name: "validAfter";
            readonly type: "uint256";
        }, {
            readonly name: "validBefore";
            readonly type: "uint256";
        }, {
            readonly name: "nonce";
            readonly type: "bytes32";
        }];
    };
    readonly primaryType: "ReceiveWithAuthorization";
    readonly message: {
        readonly from: `0x${string}`;
        readonly to: `0x${string}`;
        readonly value: bigint;
        readonly validAfter: 0n;
        readonly validBefore: bigint;
        readonly nonce: `0x${string}`;
    };
};
/** EIP-712 typed data for the token's EIP-2612 `permit`, for wallet signing. */
export declare const permitTypedData: (args: {
    chainId: number;
    token: Address;
    tokenName: string;
    tokenVersion: string;
    owner: Address;
    spender: Address;
    value: bigint;
    nonce: bigint;
    deadline: bigint;
}) => {
    readonly domain: {
        readonly name: string;
        readonly version: string;
        readonly chainId: number;
        readonly verifyingContract: `0x${string}`;
    };
    readonly types: {
        readonly Permit: readonly [{
            readonly name: "owner";
            readonly type: "address";
        }, {
            readonly name: "spender";
            readonly type: "address";
        }, {
            readonly name: "value";
            readonly type: "uint256";
        }, {
            readonly name: "nonce";
            readonly type: "uint256";
        }, {
            readonly name: "deadline";
            readonly type: "uint256";
        }];
    };
    readonly primaryType: "Permit";
    readonly message: {
        readonly owner: `0x${string}`;
        readonly spender: `0x${string}`;
        readonly value: bigint;
        readonly nonce: bigint;
        readonly deadline: bigint;
    };
};
