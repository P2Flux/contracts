import { type Address, type Hex } from 'viem';
export declare const ONE_TIME_BPS = 100n;
export declare const feeFor: (amount: bigint, bps: bigint) => bigint;
/** Must match `PAYMENT_DOMAIN` in contracts/P2FluxSplitter.sol. */
export declare const PAYMENT_DOMAIN: `0x${string}`;
/**
 * The settlement id the contract computes, recomputed locally.
 *
 * Binding a receipt to this - rather than to the `Paid` event alone - is what makes a verification
 * mean "this exact intent, in this exact token, settled". The token is part of the identity, so a
 * settlement in anything else simply is not this payment.
 */
export declare const paymentIdFor: (args: {
    token: Address;
    recipient: Address;
    amount: bigint;
    reference: Hex;
}) => Hex;
/**
 * Hand-written subset of P2FluxSplitter. The compiled artifact lives in gitignored `out/`, so the
 * API cannot depend on it. Custom errors are included so reverts decode to real names.
 */
export declare const splitterAbi: readonly [{
    readonly type: "function";
    readonly name: "pay";
    readonly stateMutability: "nonpayable";
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
    readonly outputs: readonly [];
}, {
    readonly type: "function";
    readonly name: "payWithPermit";
    readonly stateMutability: "nonpayable";
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
    }, {
        readonly name: "deadline";
        readonly type: "uint256";
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
    readonly name: "paymentId";
    readonly stateMutability: "pure";
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
        readonly type: "bytes32";
    }];
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
    readonly name: "processedPayments";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "bytes32";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
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
    readonly name: "supportedToken";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "address";
    }];
}, {
    readonly type: "function";
    readonly name: "PAYMENT_DOMAIN";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "bytes32";
    }];
}, {
    readonly type: "event";
    readonly name: "Paid";
    readonly inputs: readonly [{
        readonly name: "ref";
        readonly type: "bytes32";
        readonly indexed: true;
    }, {
        readonly name: "recipient";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "token";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "net";
        readonly type: "uint256";
    }, {
        readonly name: "fee";
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
    readonly name: "TokenNotSupported";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "NotAContract";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "TransferFailed";
    readonly inputs: readonly [];
}, {
    readonly type: "error";
    readonly name: "PaymentAlreadyProcessed";
    readonly inputs: readonly [{
        readonly name: "paymentId";
        readonly type: "bytes32";
    }];
}];
/** ERC-20 Transfer, for verifying that the split actually happened. */
export declare const transferEvent: {
    readonly type: "event";
    readonly name: "Transfer";
    readonly inputs: readonly [{
        readonly name: "from";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "to";
        readonly type: "address";
        readonly indexed: true;
    }, {
        readonly name: "value";
        readonly type: "uint256";
    }];
};
