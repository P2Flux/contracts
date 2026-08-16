/** Minimal ERC-20 subset. Recurring contract ABI lives in `recurring.ts`, splitter in `splitter.ts`. */
export declare const erc20Abi: readonly [{
    readonly type: "function";
    readonly name: "balanceOf";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "address";
    }];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "allowance";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "address";
    }, {
        readonly type: "address";
    }];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "transfer";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly type: "address";
    }, {
        readonly type: "uint256";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
    }];
}, {
    readonly type: "function";
    readonly name: "approve";
    readonly stateMutability: "nonpayable";
    readonly inputs: readonly [{
        readonly type: "address";
    }, {
        readonly type: "uint256";
    }];
    readonly outputs: readonly [{
        readonly type: "bool";
    }];
}, {
    readonly type: "function";
    readonly name: "nonces";
    readonly stateMutability: "view";
    readonly inputs: readonly [{
        readonly type: "address";
    }];
    readonly outputs: readonly [{
        readonly type: "uint256";
    }];
}, {
    readonly type: "function";
    readonly name: "name";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "string";
    }];
}, {
    readonly type: "function";
    readonly name: "decimals";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "uint8";
    }];
}, {
    readonly type: "function";
    readonly name: "version";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "string";
    }];
}, {
    readonly type: "function";
    readonly name: "DOMAIN_SEPARATOR";
    readonly stateMutability: "view";
    readonly inputs: readonly [];
    readonly outputs: readonly [{
        readonly type: "bytes32";
    }];
}];
