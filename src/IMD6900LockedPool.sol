// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IFeeSink {
    function addFees() external payable;
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title IMD6900LockedPool - the ETH / IMD6900 pool's liquidity on Robinhood Chain, locked for good
/// @notice Owns the pool's one position. Its launch opens it once, with IMD6900 only: the whole range from the pool's
///         lowest price up to the opening price, so the opening needs no ETH and every coin enters the market from
///         here. There is no owner and no function that takes liquidity out: what is in the pool stays in the pool.
///         The only thing that leaves is the fee the position earns ({collect}, anyone): its ETH to the launch's fee
///         split (the NFT pot and ops), its IMD6900 burned.
contract IMD6900LockedPool is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 public constant TICK_SPACING = 60;
    int24 public constant LOWER_TICK = -887_220; // TickMath.minUsableTick(60)

    IPoolManager public immutable poolManager;
    /// @notice The pool's static fee, in hundredths of a bip (the hook holds the pool to the same)
    uint24 public immutable poolFee;
    /// @notice IMD6900RobinhoodLaunch: sets the hook once, opens the pool once, and takes the ETH fees
    address public immutable launcher;

    address public hook;
    /// @notice IMD6900, once the pool is open
    address public token;
    /// @notice The top of the position's range: the opening price, on a tick
    int24 public upperTick;
    /// @notice The position's liquidity: set at the opening, never changed
    uint128 public liquidity;

    event HookSet(address hook);
    event Opened(uint160 sqrtPriceX96, int24 upperTick, uint256 tokens, uint128 liquidity);
    event Collected(uint256 eth, uint256 tokensBurned);

    error OnlyLauncher();
    error OnlyPoolManager();
    error HookAlreadySet();
    error NoHook();
    error AlreadyOpen();
    error NotOpen();
    error BadPrice();
    error ZeroLiquidity();

    constructor(IPoolManager poolManager_, uint24 poolFee_, address launcher_) {
        poolManager = poolManager_;
        poolFee = poolFee_;
        launcher = launcher_;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), poolFee, TICK_SPACING, IHooks(hook));
    }

    function poolId() external view returns (PoolId) {
        return poolKey().toId();
    }

    /*                               LAUNCHER                               */

    function setHook(address hook_) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookSet(hook_);
    }

    /// @notice Opens the pool once: initializes it at `sqrtPriceX96` rounded down onto a tick, and puts `amount` of
    ///         the launcher's IMD6900 (approved) into the range from the lowest price up to that tick. What the
    ///         liquidity can't take (rounding dust) goes back to the launcher.
    function open(address token_, uint160 sqrtPriceX96, uint256 amount) external nonReentrant returns (uint128 liq) {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (hook == address(0)) revert NoHook();
        if (token != address(0)) revert AlreadyOpen();
        int24 t = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 upper = t - (((t % TICK_SPACING) + TICK_SPACING) % TICK_SPACING); // floor onto the spacing
        if (upper <= LOWER_TICK || upper > TickMath.maxUsableTick(TICK_SPACING)) revert BadPrice();
        token = token_;
        upperTick = upper;
        uint160 start = TickMath.getSqrtPriceAtTick(upper);
        uint160 low = TickMath.getSqrtPriceAtTick(LOWER_TICK);
        SafeTransferLib.safeTransferFrom(token_, msg.sender, address(this), amount);
        poolManager.initialize(poolKey(), start);
        // every coin sits below the price: amount1 = L * (sqrt(upper) - sqrt(lower)) / 2^96, rounded down
        uint256 l = FullMath.mulDiv(amount, 1 << 96, start - low);
        if (l <= 1) revert ZeroLiquidity();
        liq = uint128(l - 1);
        liquidity = liq;
        (, uint256 used) = _modify(int256(uint256(liq)));
        if (amount > used) SafeTransferLib.safeTransfer(token_, msg.sender, amount - used);
        emit Opened(start, upper, used, liq);
    }

    /*                               ANYONE                                 */

    /// @notice Collects the fees the position has earned: the ETH to the launcher's fee split, the IMD6900 burned
    function collect() external nonReentrant returns (uint256 eth, uint256 tokens) {
        if (token == address(0)) revert NotOpen();
        (eth, tokens) = _modify(0);
        if (eth != 0) IFeeSink(launcher).addFees{value: eth}();
        if (tokens != 0) IBurnable(token).burn(tokens);
        emit Collected(eth, tokens);
    }

    /// @notice The fees {collect} would take right now are only known by poking the position; this is its liquidity
    ///         and the pool's price
    function state() external view returns (uint160 sqrtPriceX96, int24 tick, uint128 poolLiquidity) {
        PoolId id = poolKey().toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        poolLiquidity = poolManager.getLiquidity(id);
    }

    /*                            POOL MANAGER                              */

    /// @dev Adds the opening liquidity (a positive change) or collects the fees (a zero change). Never removes.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        int256 liquidityDelta = abi.decode(data, (int256));
        PoolKey memory key = poolKey();
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(LOWER_TICK, upperTick, liquidityDelta, 0), "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) poolManager.settle{value: uint256(uint128(-a0))}(); // never at the opening: the range holds no ETH
        else if (a0 > 0) poolManager.take(key.currency0, address(this), uint256(uint128(a0)));
        if (a1 < 0) {
            poolManager.sync(key.currency1);
            SafeTransferLib.safeTransfer(token, address(poolManager), uint256(uint128(-a1)));
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
        return abi.encode(_abs(a0), _abs(a1));
    }

    /// @notice ETH fees from the pool manager
    receive() external payable {}

    /*                              INTERNAL                                */

    function _modify(int256 liquidityDelta) internal returns (uint256 eth, uint256 tokens) {
        (eth, tokens) = abi.decode(poolManager.unlock(abi.encode(liquidityDelta)), (uint256, uint256));
    }

    function _abs(int128 v) internal pure returns (uint256) {
        return v < 0 ? uint256(uint128(-v)) : uint256(uint128(v));
    }
}
