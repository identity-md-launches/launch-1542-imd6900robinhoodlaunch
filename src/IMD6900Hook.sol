// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @notice IMD6900LockedPool: the one position this hook allows, and the coin it pairs with ETH
interface ILockedPoolView {
    function token() external view returns (address);
    function upperTick() external view returns (int24);
}

/// @notice The perps engine, once there is one: liquidates every position a trade would sink, before it runs
interface IPerpSweep {
    function sweepLiquidations(address liquidator, int256 spec, bool isBuy, uint160 limit) external returns (uint8);
    function openCount() external view returns (uint256);
}

/// @title IMD6900Hook - the ETH / IMD6900 pool's hook on Robinhood Chain: a locked pool, its fee, in-pool perps to come
/// @notice IMD6900RobinhoodLaunch creates it at an address that carries exactly its permissions. What it does:
///          - the pool is ETH / IMD6900 only, with a dynamic fee, initialized once, by IMD6900LockedPool;
///          - liquidity comes from IMD6900LockedPool only, in its one range: nobody else can add a position, and that
///            pool has no way to take liquidity out, so the pool's liquidity is locked for good;
///          - the fee: 6.9% at the launch, gliding down to 4.44% over the first week, then 3.33% for good; the
///            Robinhood timelock can lower it further, never raise it ({lowerFee}). The perps engine's own trades
///            pay none (perps earn their opening fee and funding in the engine), nor does the launch's opening buy.
///            It is the pool's own LP fee, set per swap (no return deltas: the hook never touches a swap's amounts),
///            so it accrues to the locked position like any LP fee;
///          - before any swap that is not the perps engine's own, the engine (once the Robinhood timelock wires one)
///            closes every position the trade would sink, at the price before it moves; a sweep that can't finish
///            reverts the trade (no bad debt outranks always-tradeable). Until an engine is set it does nothing.
contract IMD6900Hook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 60;
    /// @notice The fee, in hundredths of a bip (1e6 = 100%): 6.9% at the launch, gliding to 4.44% over the first
    ///         week, then 3.33%
    uint24 public constant FEE_START = 69_000;
    uint24 public constant FEE_WEEK_END = 44_400;
    uint24 public constant FEE_AFTER = 33_300;
    uint256 public constant GLIDE = 7 days;
    /// @dev Gas kept back for the rest of the swap when a sweep runs, and the least worth forwarding
    uint256 internal constant SWEEP_GAS_RESERVE = 180_000;
    uint256 internal constant SWEEP_GAS_MIN = 400_000;

    /// @notice IMD6900LockedPool: initializes the pool and owns all of its liquidity
    address public immutable pool;
    /// @notice IMD6900RobinhoodLaunch, which creates this hook: its opening buy pays no fee
    address public immutable launcher;

    /// @notice The perps engine; zero means spot only
    address public perpEngine;
    /// @notice Escape hatch: trade even when the pre-trade sweep can't run (meant only while an engine is replaced)
    bool public sweepFailOpen;
    /// @notice The one pool this hook serves, and when it opened (the fee's schedule counts from there)
    PoolId public poolId;
    uint256 public launchedAt;
    /// @notice The most the fee may be, whatever the schedule says: only ever lowered, by the timelock
    uint24 public feeCap = FEE_START;

    event PerpEngineSet(address engine);
    event SweepFailOpenSet(bool on);
    event FeeLowered(uint24 cap);

    error NotOurPool();
    error OnlyPool();
    error WrongRange();
    error InvalidFee();
    /// @notice The pre-trade liquidation sweep ran out of gas: send the trade with more gas
    error SweepGasStarved();
    /// @notice The trade would sink more positions than one transaction can liquidate: trade smaller
    error SweepTradeTooLarge();
    /// @notice The perps engine could not run its sweep at all
    error SweepUnavailable();
    error NoRenounce();

    /// @param owner_ the Robinhood timelock: the engine, the escape hatch and the fee's cap wait out its delay
    constructor(IPoolManager poolManager_, address pool_, address owner_) BaseHook(poolManager_) {
        pool = pool_;
        launcher = msg.sender;
        _initializeOwner(owner_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The fee a trade pays now, in hundredths of a bip: the schedule, under the timelock's cap
    function currentFee() public view returns (uint24 fee) {
        uint256 t = launchedAt;
        if (t == 0) fee = FEE_START; // before the launch: what it opens at
        else if (block.timestamp >= t + GLIDE) fee = FEE_AFTER;
        else fee = uint24(FEE_START - (uint256(FEE_START - FEE_WEEK_END) * (block.timestamp - t)) / GLIDE);
        if (fee > feeCap) fee = feeCap;
    }

    /// @notice The fee a swap by `sender` pays: none for the perps engine's own trades and the launch's opening buy
    function feeFor(address sender) public view returns (uint24) {
        if ((sender == perpEngine && sender != address(0)) || sender == launcher) return 0;
        return currentFee();
    }

    /// @notice The trading fee in basis points now, for the perps engine's model
    function feeBps() public view returns (uint256) {
        return currentFee() / 100;
    }

    /*                       OWNER (the Robinhood timelock)                  */

    /// @dev Replaceable: an engine whose sweep can never run blocks trading (fail closed), so the owner keeps the way
    ///      out, behind the timelock. Zero turns perps off.
    function setPerpEngine(address engine) external onlyOwner {
        perpEngine = engine;
        emit PerpEngineSet(engine);
    }

    /// @notice Caps the fee lower, for good: the cap only ever goes down
    function lowerFee(uint24 cap) external onlyOwner {
        if (cap >= feeCap) revert InvalidFee();
        feeCap = cap;
        emit FeeLowered(cap);
    }

    function setSweepFailOpen(bool on) external onlyOwner {
        sweepFailOpen = on;
        emit SweepFailOpenSet(on);
    }

    /// @notice Ownership never goes to nobody: the engine and the escape hatch need an owner
    function renounceOwnership() public payable override onlyOwner {
        revert NoRenounce();
    }

    /*                              CALLBACKS                               */

    /// @dev Only the locked pool, only once, only ETH / its coin with a dynamic fee, tick spacing 60, this hook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != pool) revert OnlyPool();
        if (
            PoolId.unwrap(poolId) != bytes32(0) || !key.currency0.isAddressZero()
                || Currency.unwrap(key.currency1) != ILockedPoolView(pool).token()
                || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != TICK_SPACING
        ) revert NotOurPool();
        poolId = key.toId();
        launchedAt = block.timestamp;
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _checkLiquidity(sender, params);
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev The locked pool never removes liquidity; it only collects its fees (a zero change, which v4 routes here)
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _checkLiquidity(sender, params);
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert NotOurPool();
        _sweep(sender, params.amountSpecified, params.zeroForOne, params.sqrtPriceLimitX96);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeFor(sender) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev A second, best-effort sweep for anything the final price leaves under water
    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _sweep(sender, 0, false, 0);
        return (BaseHook.afterSwap.selector, int128(0));
    }

    /*                               INTERNAL                               */

    function _checkLiquidity(address sender, ModifyLiquidityParams calldata params) internal view {
        if (sender != pool) revert OnlyPool();
        if (
            params.tickLower != TickMath.minUsableTick(TICK_SPACING)
                || params.tickUpper != ILockedPoolView(pool).upperTick()
        ) revert WrongRange();
    }

    /// @dev The liquidation sweep for both callbacks. `spec != 0` is the pre-trade sweep and fails closed; the
    ///      post-trade one (`spec == 0`) is best-effort. The engine's own swaps skip it: they are the sweep. The EOA
    ///      that sent the transaction is the liquidator and takes the keeper's cut.
    function _sweep(address sender, int256 spec, bool isBuy, uint160 limit) internal {
        address engine = perpEngine;
        if (engine == address(0) || sender == engine) return;
        uint256 reserve = spec != 0 ? SWEEP_GAS_RESERVE + SWEEP_GAS_MIN : SWEEP_GAS_RESERVE;
        uint256 g = gasleft();
        if (g > reserve + SWEEP_GAS_MIN) {
            (bool ok, bytes memory out) =
                engine.call{gas: g - reserve}(abi.encodeCall(IPerpSweep.sweepLiquidations, (tx.origin, spec, isBuy, limit)));
            if (spec == 0) return;
            if (!ok || out.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
                return;
            }
            uint256 status = abi.decode(out, (uint256));
            if (status == 2) revert SweepTradeTooLarge();
            if (status != 0) revert SweepGasStarved();
        } else if (spec != 0) {
            // too little gas to sweep: refuse the trade while positions are open, rather than trade blind; an engine
            // that can't even say whether positions are open fails closed here too (unless fail-open is set)
            (bool ok, bytes memory ret) = engine.staticcall(abi.encodeCall(IPerpSweep.openCount, ()));
            if (!ok || ret.length < 32) {
                if (!sweepFailOpen) revert SweepUnavailable();
            } else if (abi.decode(ret, (uint256)) != 0) {
                revert SweepGasStarved();
            }
        }
    }
}
