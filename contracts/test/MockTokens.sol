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
