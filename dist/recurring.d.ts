import { type Address, type Hex } from 'viem';
/**
 * Wallet-independent recurring payments: the customer signs these exact terms once (EIP-712), and
 * the P2FluxRecurring contract will execute exactly this payment once per period until revoked.
 * The unlimited ERC-20 allowance only lets the contract move the token at all - this authorization
 * is the only thing that decides where funds go, how much, and how often.
 *
 * Every constant here mirrors contracts/P2FluxRecurring.sol; the hash-equivalence test pins them.
 */
export type RecurringAuthorization = {
    payer: Address;
    recipient: Address;
    token: Address;
    /** Token base units, charged per period before the fee split. */
    amount: bigint;
    /** Billing period in seconds. */
    period: number;
    /** First period starts here (unix seconds). Fixed by the server at setup-token issuance. */
    start: number;
    /** 0 = no expiration. */
    end: number;
    salt: bigint;
    /** Per-charge cap on the extra gas-reimbursement debit, token base units. */
    maxGasReimbursement: bigint;
};
/** P2Flux profit only. Never funds gas - that is NETWORK_FEE plus the reimbursement. */
export declare const RECURRING_FEE_BPS = 200n;
/** Mirrors `GAS_REIMBURSEMENT_HARD_CAP` in the contract (6-decimal token units). */
export declare const GAS_REIMBURSEMENT_HARD_CAP: bigint;
/**
 * Mirrors `NETWORK_FEE`: a flat per-charge network/infrastructure fee, deducted from the signed
 * amount alongside the profit fee. The merchant funds it out of proceeds; the customer's debit is
 * unaffected. It goes to the gas treasury, never to the profit wallet.
 */
export declare const RECURRING_NETWORK_FEE: bigint;
export declare const recurringFee: (amount: bigint) => bigint;
/** What the merchant actually receives: the commercial amount less both fees. */
export declare const recurringNet: (amount: bigint) => bigint;
/**
 * The smallest amount that still leaves the merchant something.
 *
 * The contract refuses `amount <= fee + NETWORK_FEE`, so this searches up from the fee floor rather
 * than hardcoding a figure that could drift when a fee constant changes. The answer is a handful of
 * units away, so the loop is trivial.
 */
export declare const minRecurringAmount: () => bigint;
/** 128 random bits: two subscriptions with identical terms stay distinguishable and independent. */
export declare const randomSalt: () => bigint;
export declare const RECURRING_TYPES: {
    readonly RecurringAuthorization: readonly [{
        readonly name: "payer";
        readonly type: "address";
    }, {
        readonly name: "recipient";
        readonly type: "address";
    }, {
        readonly name: "token";
        readonly type: "address";
    }, {
        readonly name: "amount";
        readonly type: "uint256";
    }, {
        readonly name: "period";
        readonly type: "uint48";
    }, {
        readonly name: "start";
        readonly type: "uint48";
    }, {
        readonly name: "end";
        readonly type: "uint48";
    }, {
        readonly name: "salt";
        readonly type: "bytes32";
    }, {
        readonly name: "maxGasReimbursement";
        readonly type: "uint256";
    }];
};
export declare const recurringDomain: (chainId: number, contract: Address) => {
    name: string;
    version: string;
    chainId: number;
    verifyingContract: `0x${string}`;
};
/** The exact typed data a wallet signs. Must hash identically to the contract's subscriptionId. */
export declare const recurringTypedData: (auth: RecurringAuthorization, chainId: number, contract: Address) => {
    domain: {
        name: string;
        version: string;
        chainId: number;
        verifyingContract: `0x${string}`;
    };
    types: {
        readonly RecurringAuthorization: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    };
    primaryType: "RecurringAuthorization";
    message: {
        payer: `0x${string}`;
        recipient: `0x${string}`;
        token: `0x${string}`;
        amount: bigint;
        period: number;
        start: number;
        end: number;
        salt: Hex;
        maxGasReimbursement: bigint;
    };
};
/** The auth in the shape viem's ABI encoder expects (salt as bytes32 hex). */
export declare const abiAuth: (auth: RecurringAuthorization) => {
    payer: `0x${string}`;
    recipient: `0x${string}`;
    token: `0x${string}`;
    amount: bigint;
    period: number;
    start: number;
    end: number;
    salt: Hex;
    maxGasReimbursement: bigint;
};
/** Deterministic subscription id: the EIP-712 digest, exactly as the contract computes it. */
export declare const recurringSubscriptionId: (auth: RecurringAuthorization, chainId: number, contract: Address) => Hex;
export declare const recurringAbi: readonly [{
    readonly type: "function";
    readonly name: "charge";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly type: "tuple";
        readonly name: "auth";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    }, {
        readonly name: "signature";
        readonly type: "bytes";
    }, {
        readonly name: "gasReimbursement";
        readonly type: "uint256";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "revoke";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly type: "tuple";
        readonly name: "auth";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "subscriptionId";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "tuple";
        readonly name: "auth";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    }];
    readonly outputs: readonly [{
        readonly type: "bytes32";
    }];
}, {
    readonly type: "function";
    readonly name: "currentPeriod";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "tuple";
        readonly name: "auth";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    }];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "isChargeable";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "tuple";
        readonly name: "auth";
        readonly components: readonly [{
            readonly name: "payer";
            readonly type: "address";
        }, {
            readonly name: "recipient";
            readonly type: "address";
        }, {
            readonly name: "token";
            readonly type: "address";
        }, {
            readonly name: "amount";
            readonly type: "uint256";
        }, {
            readonly name: "period";
            readonly type: "uint48";
        }, {
            readonly name: "start";
            readonly type: "uint48";
        }, {
            readonly name: "end";
            readonly type: "uint48";
        }, {
            readonly name: "salt";
            readonly type: "bytes32";
        }, {
            readonly name: "maxGasReimbursement";
            readonly type: "uint256";
        }];
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
    }];
}, {
    readonly type: "function";
    readonly name: "lastChargedPeriodPlusOne";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "revoked";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
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
    readonly type: "function";
    readonly name: "feeWallet";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "admin";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "setRelayer";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly type: "address";
    }];
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "GAS_REIMBURSEMENT_HARD_CAP";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "FEE_BPS";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint16";
    }];
}, {
    readonly type: "function";
    readonly name: "NETWORK_FEE";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint256";
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
    readonly name: "supportedToken";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "event";
    readonly name: "SubscriptionCharged";
    readonly inputs: readonly [{
        readonly name: "subscriptionId";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "payer";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "recipient";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "periodIndex";
        readonly type: "uint256";
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
        readonly name: "gasReimbursement";
        readonly type: "uint256";
    }];
}, {
    readonly type: "event";
    readonly name: "SubscriptionRevoked";
    readonly inputs: readonly [{
        readonly name: "subscriptionId";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "payer";
        readonly type: "address";
        readonly indexed: true;
    }];
}, {
    readonly type: "event";
    readonly name: "RelayerChanged";
    readonly inputs: readonly [{
        readonly name: "relayer";
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
    readonly name: "ZeroPeriod";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "InvalidEnd";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotAdmin";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotStarted";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "Expired";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "Revoked";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "AlreadyRevoked";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotPayer";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "InvalidSignature";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "AlreadyChargedThisPeriod";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "GasReimbursementTooHigh";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "TokenNotSupported";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "AmountTooSmall";
    readonly inputs: readonly [];
}];
/** Wire form for the p2s2 capability payload and API responses (bigint-free). */
export type WireAuthorization = {
    payer: Address;
    recipient: Address;
    token: Address;
    amount: string;
    period: number;
    start: number;
    end: number;
    salt: string;
    max_gas_reimbursement: string;
};
export declare const toWire: (auth: RecurringAuthorization) => WireAuthorization;
export declare const fromWire: (wire: WireAuthorization) => RecurringAuthorization;
