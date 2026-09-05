// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-20 for tests: mint freely, standard approve/transferFrom semantics.
contract MockUSDC {
    string public constant name = "Mock USDC";
    string public constant symbol = "mUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        return _move(from, to, value);
    }

    function _move(address from, address to, uint256 value) internal returns (bool) {
        require(balanceOf[from] >= value, "insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}

/// @notice Returns false instead of reverting - SafeERC20 must catch it.
contract FalseReturnToken is MockUSDC {
    bool public failTransfers;

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (failTransfers) return false;
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        return _move(from, to, value);
    }
}

interface IRecurringLike {
    struct RecurringAuthorization {
        address payer;
        address recipient;
        address token;
        uint256 amount;
        uint48 period;
        uint48 start;
        uint48 end;
        bytes32 salt;
        uint256 maxGasReimbursement;
    }

    function charge(RecurringAuthorization calldata auth, bytes calldata signature, uint256 gasReimbursement)
        external;
}

/// @notice ERC-20 whose transferFrom re-enters `charge` - the guard must stop it.
contract ReentrantToken is MockUSDC {
    IRecurringLike public target;
    IRecurringLike.RecurringAuthorization public storedAuth;
    bytes public storedSignature;
    bool public armed;
    bool public reentered;

    function arm(
        IRecurringLike _target,
        IRecurringLike.RecurringAuthorization calldata auth,
        bytes calldata signature
    ) external {
        target = _target;
        storedAuth = auth;
        storedSignature = signature;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (armed) {
            armed = false;
            reentered = true;
            // Re-enter during the transfer. ReentrancyGuard must revert this inner call,
            // which bubbles up and reverts the outer charge too.
            target.charge(storedAuth, storedSignature, 0);
        }
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        return _move(from, to, value);
    }
}

/// @notice Minimal ERC-1271 wallet: accepts a digest if its single owner signed it.
contract Mock1271Wallet {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s, uint8 v) = _split(signature);
        if (ecrecover(digest, v, r, s) == owner) return 0x1626ba7e;
        return 0xffffffff;
    }

    function _split(bytes calldata signature) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "bad length");
        r = bytes32(signature[0:32]);
        s = bytes32(signature[32:64]);
        v = uint8(signature[64]);
    }
}

/// @dev Wallets that misbehave in each way ERC-1271 validation must survive. Every one of these must
///      be treated as "not authorized" rather than crashing, hanging or being trusted.

/// @dev Returns a plausible but wrong selector.
contract WrongMagicWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @dev Reverts instead of answering.
contract RevertingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("no");
    }
}

/// @dev Returns nothing at all - `returndatasize` zero.
contract EmptyReturnWallet {
    fallback() external {}
}

/// @dev Returns fewer than 32 bytes, the short-returndata case.
contract ShortReturnWallet {
    fallback() external {
        assembly {
            mstore(0x00, 0x1626ba7e)
            return(0x00, 0x04)
        }
    }
}

/// @dev Answers correctly until flipped, so a charge can be valid in one period and refused in the
///      next - the "contract signatures are revocable" property that makes per-charge revalidation
///      the only safe design.
contract FlippableWallet {
    bool public accept = true;

    function setAccept(bool value) external {
        accept = value;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return accept ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Burns gas in an unbounded loop before answering. Used to prove the caller's gas bound is
///      real: on-chain the relayer's transaction limit contains it, off-chain the API's explicit
///      call cap does.
contract GasBurnerWallet {
    uint256 public sink;

    function isValidSignature(bytes32, bytes calldata) external returns (bytes4) {
        for (uint256 i = 0; i < 100_000; i++) sink = i;
        return 0x1626ba7e;
    }
}

/// @dev An ERC-1271 wallet that also accepts anything: the "malicious validator" case. Charging it
///      is fine - it is spending its own funds, bounded by its own allowance and the signed terms.
contract AlwaysValidWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/**
 * @notice A FiatToken-v2-shaped mock: EIP-2612 `permit` and EIP-3009
 *         `receiveWithAuthorization`, with the real domain, typehashes and nonce semantics.
 *
 * @dev The sponsored contracts lean on the token to enforce most of their security - signature
 *      validity, single use of a nonce, the deadline, and `to == msg.sender` - so a mock that only
 *      pretended to check those would test nothing. This one checks all four the way USDC does.
 */
contract MockFiatToken is MockUSDC {
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    string public constant version = "2";

    mapping(address => uint256) public nonces;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        virtual
    {
        require(block.timestamp <= deadline, "permit expired");
        bytes32 digest = _digest(
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
        );
        require(_recover(digest, v, r, s) == owner, "invalid permit signature");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(to == msg.sender, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization is not yet valid");
        require(block.timestamp < validBefore, "authorization is expired");
        require(!authorizationState[from][nonce], "authorization is used or canceled");

        bytes32 digest = _digest(
            keccak256(
                abi.encode(
                    RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce
                )
            )
        );
        require(_recover(digest, v, r, s) == from, "invalid authorization signature");

        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        require(_move(from, to, value), "transfer failed");
    }

    function _digest(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function _recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) private pure returns (address) {
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "malleable s");
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "invalid signature");
        return signer;
    }
}

/// @notice A FiatToken whose `permit` always reverts: proves the fee pull is rolled back with it.
contract PermitRevertingToken is MockFiatToken {
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external pure override {
        revert("permit refused");
    }
}
