// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

interface ITokenSupply {
    function totalSupply() external view returns (uint256);
}

/// @notice ETH-only, fixed-fee v4 hook with an immutable owner and per-pool swap controls.
/// @dev Implements only the callbacks it advertises. All other selectors revert.
contract ReedGuard is IUnlockCallback {
    using SafeCast for uint256;

    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant COOLDOWN = 30 seconds;

    IPoolManager public immutable poolManager;
    address public immutable owner;
    address public immutable feeRecipient;

    mapping(PoolId poolId => address) private _tokens;
    mapping(PoolId poolId => bool) public paused;
    mapping(PoolId poolId => mapping(address wallet => uint256 timestamp)) public nextSwapAt;
    /// @notice ETH claims held by this hook for this pool, redeemable only to feeRecipient.
    mapping(PoolId poolId => uint256 amount) public claimableFees;

    // Execution guards, not pool settings. Cleared before each top-level call returns.
    bool private _paying;
    bool private _claimInProgress;

    error ZeroAddress();
    error OnlyPoolManager();
    error OnlyOwner();
    error NativeETHPairRequired();
    error WrongHook();
    error UnknownPool(PoolId poolId);
    error PoolPaused(PoolId poolId);
    error SwapTooSoon(PoolId poolId, address wallet, uint256 nextAllowed);
    error PartialETHFill(int256 expected, int256 actual);
    error ReentrantCall();
    error UnexpectedUnlock();

    event PoolRegistered(PoolId indexed poolId, address indexed token);
    event Paused(PoolId indexed poolId);
    event Unpaused(PoolId indexed poolId);
    event SwapCooldown(PoolId indexed poolId, address indexed wallet, uint256 nextAllowed);
    event FeePaid(PoolId indexed poolId, uint256 amount);
    event FeeDeferred(PoolId indexed poolId, uint256 amount);
    event FeesClaimed(PoolId indexed poolId, uint256 amount);

    constructor(IPoolManager poolManager_, address owner_, address feeRecipient_) {
        if (address(poolManager_) == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        owner = owner_;
        feeRecipient = feeRecipient_;
        // This is an internal pure library check; construction makes no external calls.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier nonReentrant() {
        if (_paying) revert ReentrantCall();
        _paying = true;
        _;
        _paying = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            revert NativeETHPairRequired();
        }
        if (address(key.hooks) != address(this)) revert WrongHook();
        PoolId poolId = key.toId();
        _tokens[poolId] = Currency.unwrap(key.currency1);
        emit PoolRegistered(poolId, Currency.unwrap(key.currency1));
        return IHooks.beforeInitialize.selector;
    }

    /// @notice The non-ETH currency of this initialized pool.
    function token(PoolId poolId) public view returns (address result) {
        result = _tokens[poolId];
        if (result == address(0)) revert UnknownPool(poolId);
    }

    /// @notice The pool token's current totalSupply(), without decimal assumptions or caching.
    function totalSupply(PoolId poolId) external view returns (uint256) {
        return ITokenSupply(token(poolId)).totalSupply();
    }

    function pause(PoolId poolId) external onlyOwner {
        token(poolId);
        paused[poolId] = true;
        emit Paused(poolId);
    }

    function unpause(PoolId poolId) external onlyOwner {
        token(poolId);
        paused[poolId] = false;
        emit Unpaused(poolId);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_paying) revert ReentrantCall();
        PoolId poolId = key.toId();
        token(poolId);
        if (paused[poolId]) revert PoolPaused(poolId);

        // tx.origin is deliberately only a throttle key, never an authorization credential.
        address wallet = tx.origin;
        uint256 nextAllowed = nextSwapAt[poolId][wallet];
        if (block.timestamp < nextAllowed) revert SwapTooSoon(poolId, wallet, nextAllowed);
        nextAllowed = block.timestamp + COOLDOWN;
        nextSwapAt[poolId][wallet] = nextAllowed;
        emit SwapCooldown(poolId, wallet, nextAllowed);

        int128 fee = 0;
        if (_ethIsSpecified(params)) fee = _specifiedFee(params).toInt128();
        // The unspecified currency is the token here: never take any of it.
        // For token-specified swaps both deltas are zero until afterSwap.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        PoolId poolId = key.toId();
        token(poolId);
        uint256 fee;
        bool ethSpecified = _ethIsSpecified(params);
        if (ethSpecified) {
            fee = _specifiedFee(params);
            // beforeSwap has adjusted the pool's input/output by this fee. A partial fill
            // cannot support the promised specified fee, so roll back the entire swap.
            int256 expected = params.amountSpecified + int256(fee);
            if (int256(delta.amount0()) != expected) {
                revert PartialETHFill(expected, int256(delta.amount0()));
            }
        } else {
            fee = FullMath.mulDiv(_abs(int256(delta.amount0())), FEE_BPS, BPS_DENOMINATOR);
        }

        if (fee != 0) _payOrDefer(poolId, fee);
        // afterSwap can only return an unspecified-currency delta. Return zero when that
        // currency is the token; the ETH fee is already represented by beforeSwap's delta.
        return (IHooks.afterSwap.selector, ethSpecified ? int128(0) : fee.toInt128());
    }

    /// @notice Redeem this pool's deferred ETH fees to the immutable recipient. Anyone may call.
    /// @return amount ETH redeemed; zero if there are no claims or no ETH is available yet.
    /// @dev Call outside an existing PoolManager unlock. Failed transfers preserve all claims.
    function claimFees(PoolId poolId) external nonReentrant returns (uint256 amount) {
        token(poolId);
        amount = claimableFees[poolId];
        uint256 available = address(poolManager).balance;
        if (amount > available) amount = available;
        // v4 burns/takes signed 128-bit deltas. Large cumulative claims remain redeemable
        // over multiple calls instead of becoming permanently unclaimable.
        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (amount > maxDelta) amount = maxDelta;
        if (amount == 0) return 0;

        claimableFees[poolId] -= amount;
        _claimInProgress = true;
        poolManager.unlock(abi.encode(poolId, amount));
        _claimInProgress = false;
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_claimInProgress) revert UnexpectedUnlock();
        _claimInProgress = false;
        (PoolId poolId, uint256 amount) = abi.decode(data, (PoolId, uint256));
        // Claim id 0 is native ETH in v4. +amount from burn and -amount from take cancel.
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), feeRecipient, amount);
        emit FeesClaimed(poolId, amount);
        return "";
    }

    function _payOrDefer(PoolId poolId, uint256 fee) private {
        if (address(poolManager).balance >= fee) {
            // If the recipient rejects ETH, take reverts atomically; mint the claim instead.
            try poolManager.take(Currency.wrap(address(0)), feeRecipient, fee) {
                emit FeePaid(poolId, fee);
                return;
            } catch {}
        }
        claimableFees[poolId] += fee;
        poolManager.mint(address(this), 0, fee);
        emit FeeDeferred(poolId, fee);
    }

    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _specifiedFee(SwapParams calldata params) private pure returns (uint256) {
        return FullMath.mulDiv(_abs(params.amountSpecified), FEE_BPS, BPS_DENOMINATOR);
    }

    function _abs(int256 value) private pure returns (uint256) {
        // Also well-defined for type(int256).min; any oversized fee is rejected by SafeCast.
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
