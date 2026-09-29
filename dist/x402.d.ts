import type { Address, Hex } from 'viem';
/** P2Flux's fee on an x402 payment: 1%, never less than the deployment's `MIN_FEE`. */
export declare const X402_FEE_BPS = 100n;
/** Mirrors `maxFee` in the contract: the most the relayer may take from a payment of `amount`. */
export declare const x402MaxFee: (amount: bigint, minFee: bigint) => bigint;
/** Uniswap Permit2: the same address on every chain. */
export declare const PERMIT2: Address;
/**
 * x402's `upto` proxy (x402-foundation/x402 x402UptoPermit2Proxy). One CREATE2 address, verified on
 * Base and Base Sepolia (identical code hash) on 2026-09-29; the x402 client hardcodes it as the
 * Permit2 spender, so it is not configurable.
 */
export declare const X402_UPTO_PROXY: Address;
/**
 * EIP-712 typed data for USDC's `TransferWithAuthorization`: what an x402 `exact` client signs, with
 * `to` = the seller's vault. For tests and tooling - in production the agent's own client builds it.
 */
export declare const transferWithAuthorizationTypedData: (args: {
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
        readonly TransferWithAuthorization: readonly [{
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
    readonly primaryType: "TransferWithAuthorization";
    readonly message: {
        readonly from: `0x${string}`;
        readonly to: `0x${string}`;
        readonly value: bigint;
        readonly validAfter: 0n;
        readonly validBefore: bigint;
        readonly nonce: `0x${string}`;
    };
};
/**
 * The full P2FluxX402Splitter ABI. Generated from the compiled contract rather than hand-picked, and
 * test/x402.test.ts fails if it ever differs from a fresh compile.
 */
export declare const p2fluxX402SplitterAbi: readonly [{
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "_supportedToken";
        readonly type: "address";
    }, {
        readonly internalType: "address";
        readonly name: "_feeWallet";
        readonly type: "address";
    }, {
        readonly internalType: "address";
        readonly name: "_relayer";
        readonly type: "address";
    }, {
        readonly internalType: "address";
        readonly name: "_uptoProxy";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "_minFee";
        readonly type: "uint256";
    }];
    readonly stateMutability: "nonpayable";
    readonly type: "constructor";
}, {
    readonly inputs: readonly [];
    readonly name: "AmountTooSmall";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "FeeTooHigh";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "NotAContract";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "NotRelayer";
    readonly type: "error";
}, {
    readonly inputs: readonly [{
        readonly internalType: "bytes32";
        readonly name: "paymentId";
        readonly type: "bytes32";
    }];
    readonly name: "PaymentAlreadyProcessed";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "ReentrancyGuardReentrantCall";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "TokenNotSupported";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "UnexpectedAmount";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "WrongDestination";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "ZeroAddress";
    readonly type: "error";
}, {
    readonly inputs: readonly [];
    readonly name: "ZeroAmount";
    readonly type: "error";
}, {
    readonly anonymous: false;
    readonly inputs: readonly [{
        readonly indexed: true;
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly indexed: false;
        readonly internalType: "uint256";
        readonly name: "net";
        readonly type: "uint256";
    }, {
        readonly indexed: false;
        readonly internalType: "uint256";
        readonly name: "fee";
        readonly type: "uint256";
    }];
    readonly name: "Flushed";
    readonly type: "event";
}, {
    readonly anonymous: false;
    readonly inputs: readonly [{
        readonly indexed: true;
        readonly internalType: "bytes32";
        readonly name: "ref";
        readonly type: "bytes32";
    }, {
        readonly indexed: true;
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly indexed: true;
        readonly internalType: "address";
        readonly name: "token";
        readonly type: "address";
    }, {
        readonly indexed: false;
        readonly internalType: "uint256";
        readonly name: "net";
        readonly type: "uint256";
    }, {
        readonly indexed: false;
        readonly internalType: "uint256";
        readonly name: "fee";
        readonly type: "uint256";
    }];
    readonly name: "Paid";
    readonly type: "event";
}, {
    readonly anonymous: false;
    readonly inputs: readonly [{
        readonly indexed: true;
        readonly internalType: "bytes32";
        readonly name: "paymentId";
        readonly type: "bytes32";
    }];
    readonly name: "PaymentSettled";
    readonly type: "event";
}, {
    readonly inputs: readonly [];
    readonly name: "FEE_BPS";
    readonly outputs: readonly [{
        readonly internalType: "uint16";
        readonly name: "";
        readonly type: "uint16";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "MIN_FEE";
    readonly outputs: readonly [{
        readonly internalType: "uint256";
        readonly name: "";
        readonly type: "uint256";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "PAYMENT_DOMAIN";
    readonly outputs: readonly [{
        readonly internalType: "bytes32";
        readonly name: "";
        readonly type: "bytes32";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "feeWallet";
    readonly outputs: readonly [{
        readonly internalType: "address";
        readonly name: "";
        readonly type: "address";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }];
    readonly name: "flush";
    readonly outputs: readonly [];
    readonly stateMutability: "nonpayable";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "token";
        readonly type: "address";
    }, {
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly internalType: "bytes32";
        readonly name: "ref";
        readonly type: "bytes32";
    }];
    readonly name: "isPaymentProcessed";
    readonly outputs: readonly [{
        readonly internalType: "bool";
        readonly name: "";
        readonly type: "bool";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "uint256";
        readonly name: "amount";
        readonly type: "uint256";
    }];
    readonly name: "maxFee";
    readonly outputs: readonly [{
        readonly internalType: "uint256";
        readonly name: "";
        readonly type: "uint256";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "token";
        readonly type: "address";
    }, {
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly internalType: "bytes32";
        readonly name: "ref";
        readonly type: "bytes32";
    }];
    readonly name: "paymentId";
    readonly outputs: readonly [{
        readonly internalType: "bytes32";
        readonly name: "";
        readonly type: "bytes32";
    }];
    readonly stateMutability: "pure";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "bytes32";
        readonly name: "";
        readonly type: "bytes32";
    }];
    readonly name: "processedPayments";
    readonly outputs: readonly [{
        readonly internalType: "bool";
        readonly name: "";
        readonly type: "bool";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "relayer";
    readonly outputs: readonly [{
        readonly internalType: "address";
        readonly name: "";
        readonly type: "address";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "fee";
        readonly type: "uint256";
    }, {
        readonly components: readonly [{
            readonly components: readonly [{
                readonly internalType: "address";
                readonly name: "token";
                readonly type: "address";
            }, {
                readonly internalType: "uint256";
                readonly name: "amount";
                readonly type: "uint256";
            }];
            readonly internalType: "struct ISignatureTransfer.TokenPermissions";
            readonly name: "permitted";
            readonly type: "tuple";
        }, {
            readonly internalType: "uint256";
            readonly name: "nonce";
            readonly type: "uint256";
        }, {
            readonly internalType: "uint256";
            readonly name: "deadline";
            readonly type: "uint256";
        }];
        readonly internalType: "struct ISignatureTransfer.PermitTransferFrom";
        readonly name: "permit";
        readonly type: "tuple";
    }, {
        readonly internalType: "uint256";
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly internalType: "address";
        readonly name: "owner";
        readonly type: "address";
    }, {
        readonly components: readonly [{
            readonly internalType: "address";
            readonly name: "to";
            readonly type: "address";
        }, {
            readonly internalType: "address";
            readonly name: "facilitator";
            readonly type: "address";
        }, {
            readonly internalType: "uint256";
            readonly name: "validAfter";
            readonly type: "uint256";
        }];
        readonly internalType: "struct IX402UptoPermit2Proxy.Witness";
        readonly name: "witness";
        readonly type: "tuple";
    }, {
        readonly internalType: "bytes";
        readonly name: "signature";
        readonly type: "bytes";
    }];
    readonly name: "settleUpto";
    readonly outputs: readonly [];
    readonly stateMutability: "nonpayable";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "fee";
        readonly type: "uint256";
    }, {
        readonly components: readonly [{
            readonly internalType: "uint256";
            readonly name: "value";
            readonly type: "uint256";
        }, {
            readonly internalType: "uint256";
            readonly name: "deadline";
            readonly type: "uint256";
        }, {
            readonly internalType: "bytes32";
            readonly name: "r";
            readonly type: "bytes32";
        }, {
            readonly internalType: "bytes32";
            readonly name: "s";
            readonly type: "bytes32";
        }, {
            readonly internalType: "uint8";
            readonly name: "v";
            readonly type: "uint8";
        }];
        readonly internalType: "struct IX402UptoPermit2Proxy.EIP2612Permit";
        readonly name: "permit2612";
        readonly type: "tuple";
    }, {
        readonly components: readonly [{
            readonly components: readonly [{
                readonly internalType: "address";
                readonly name: "token";
                readonly type: "address";
            }, {
                readonly internalType: "uint256";
                readonly name: "amount";
                readonly type: "uint256";
            }];
            readonly internalType: "struct ISignatureTransfer.TokenPermissions";
            readonly name: "permitted";
            readonly type: "tuple";
        }, {
            readonly internalType: "uint256";
            readonly name: "nonce";
            readonly type: "uint256";
        }, {
            readonly internalType: "uint256";
            readonly name: "deadline";
            readonly type: "uint256";
        }];
        readonly internalType: "struct ISignatureTransfer.PermitTransferFrom";
        readonly name: "permit";
        readonly type: "tuple";
    }, {
        readonly internalType: "uint256";
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly internalType: "address";
        readonly name: "owner";
        readonly type: "address";
    }, {
        readonly components: readonly [{
            readonly internalType: "address";
            readonly name: "to";
            readonly type: "address";
        }, {
            readonly internalType: "address";
            readonly name: "facilitator";
            readonly type: "address";
        }, {
            readonly internalType: "uint256";
            readonly name: "validAfter";
            readonly type: "uint256";
        }];
        readonly internalType: "struct IX402UptoPermit2Proxy.Witness";
        readonly name: "witness";
        readonly type: "tuple";
    }, {
        readonly internalType: "bytes";
        readonly name: "signature";
        readonly type: "bytes";
    }];
    readonly name: "settleUptoWithPermit";
    readonly outputs: readonly [];
    readonly stateMutability: "nonpayable";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly internalType: "uint256";
        readonly name: "fee";
        readonly type: "uint256";
    }, {
        readonly components: readonly [{
            readonly internalType: "address";
            readonly name: "from";
            readonly type: "address";
        }, {
            readonly internalType: "uint256";
            readonly name: "value";
            readonly type: "uint256";
        }, {
            readonly internalType: "uint256";
            readonly name: "validAfter";
            readonly type: "uint256";
        }, {
            readonly internalType: "uint256";
            readonly name: "validBefore";
            readonly type: "uint256";
        }, {
            readonly internalType: "bytes32";
            readonly name: "nonce";
            readonly type: "bytes32";
        }];
        readonly internalType: "struct P2FluxX402Splitter.Authorization";
        readonly name: "a";
        readonly type: "tuple";
    }, {
        readonly internalType: "bytes";
        readonly name: "signature";
        readonly type: "bytes";
    }];
    readonly name: "settleWithAuthorization";
    readonly outputs: readonly [];
    readonly stateMutability: "nonpayable";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "supportedToken";
    readonly outputs: readonly [{
        readonly internalType: "address";
        readonly name: "";
        readonly type: "address";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [];
    readonly name: "uptoProxy";
    readonly outputs: readonly [{
        readonly internalType: "contract IX402UptoPermit2Proxy";
        readonly name: "";
        readonly type: "address";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}, {
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "recipient";
        readonly type: "address";
    }];
    readonly name: "vaultOf";
    readonly outputs: readonly [{
        readonly internalType: "address";
        readonly name: "";
        readonly type: "address";
    }];
    readonly stateMutability: "view";
    readonly type: "function";
}];
