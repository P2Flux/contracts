/** The full P2FluxX402Splitter ABI. */
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
    readonly name: "X402_REF_DOMAIN";
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
    readonly inputs: readonly [{
        readonly internalType: "address";
        readonly name: "payer";
        readonly type: "address";
    }, {
        readonly internalType: "bytes32";
        readonly name: "nonce";
        readonly type: "bytes32";
    }];
    readonly name: "refOf";
    readonly outputs: readonly [{
        readonly internalType: "bytes32";
        readonly name: "";
        readonly type: "bytes32";
    }];
    readonly stateMutability: "pure";
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
/** P2FluxX402Vault creation code: `vaultOf` is CREATE2 over this followed by abi.encode(recipient). */
export declare const X402_VAULT_CREATION_CODE: "0x60c0604052348015600e575f80fd5b50604051610472380380610472833981016040819052602b91603f565b336080526001600160a01b031660a052606a565b5f60208284031215604e575f80fd5b81516001600160a01b03811681146063575f80fd5b9392505050565b60805160a0516103dc6100965f395f8181606e015261013b01525f818160ad015260db01526103dc5ff3fe608060405234801561000f575f80fd5b506004361061003f575f3560e01c806316afdf8e1461004357806366d003ac14610069578063c45a0155146100a8575b5f80fd5b610056610051366004610302565b6100cf565b6040519081526020015b60405180910390f35b6100907f000000000000000000000000000000000000000000000000000000000000000081565b6040516001600160a01b039091168152602001610060565b6100907f000000000000000000000000000000000000000000000000000000000000000081565b5f336001600160a01b037f0000000000000000000000000000000000000000000000000000000000000000161461011957604051631966391b60e11b815260040160405180910390fd5b5f8211801561012e575061012e85858461017d565b156101365750805b6101757f00000000000000000000000000000000000000000000000000000000000000006101648386610345565b6001600160a01b038816919061024b565b949350505050565b6040516001600160a01b038381166024830152604482018390525f91829182919087169060640160408051601f198184030181529181526020820180516001600160e01b031663a9059cbb60e01b179052516101d9919061036a565b5f604051808303815f865af19150503d805f8114610212576040519150601f19603f3d011682016040523d82523d5f602084013e610217565b606091505b50915091508180156102415750805115806102415750808060200190518101906102419190610380565b9695505050505050565b6102588383836001610289565b61028457604051635274afe760e01b81526001600160a01b038416600482015260240160405180910390fd5b505050565b60405163a9059cbb60e01b5f8181526001600160a01b038616600452602485905291602083604481808b5af1925060015f511483166102df5783831516156102d3573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b6001600160a01b03811681146102ff575f80fd5b50565b5f805f8060808587031215610315575f80fd5b8435610320816102eb565b93506020850135610330816102eb565b93969395505050506040820135916060013590565b8181038181111561036457634e487b7160e01b5f52601160045260245ffd5b92915050565b5f82518060208501845e5f920191825250919050565b5f60208284031215610390575f80fd5b8151801515811461039f575f80fd5b939250505056fea26469706673582212208528bec3a0f2cebdf4845102e8bf5bd840e0bc5dfb06ccfae5d80a3c5aab2d5764736f6c634300081a0033";
