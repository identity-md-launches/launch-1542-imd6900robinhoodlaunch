// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {IERC20, MockImdstr, Trader, Engine, Refuser, LiquidityAdder} from "./IMD6900RobinhoodLaunch.t.sol";

/// Drives the launched system with bounded, random calls from every role: traders buying and selling through the
/// PoolManager, snapshot holders claiming, the timelock moving the fee, ending the claims, selling or releasing the
/// held coins, recovering ETH and resetting the split, the owner releasing the unclaimed rest, anyone harvesting,
/// splitting, retrying a refused share, buying $IMD for the burn, sending fees; and the pot bridge going down and up.
contract LaunchHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant R = address(0x2E7);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;

    IPoolManager immutable PM;
    IMD6900RobinhoodLaunch immutable L;
    IMD6900LockedPool immutable pool;
    IMD6900Hook immutable hook;
    MockImdstr immutable imdstr;
    address immutable token;
    Engine immutable engine;
    Refuser immutable refuser;
    bytes refuserCode;

    Trader[3] traders;
    address[3] claimants;
    uint256[3] allowances;
    bytes32[3] leaves;

    // ghosts
    uint24 public lastFee;
    uint256 public supplyBefore;
    bool public releasedSeen;
    uint256 public claimedGhost;
    uint256 public imdstrReleased;
    bool public potRefuses;
    PoolId[] public oldPools;
    uint256 public calls;

    constructor(
        IPoolManager pm,
        IMD6900RobinhoodLaunch l,
        MockImdstr imdstr_,
        address[3] memory who,
        uint256[3] memory amounts,
        bytes32[3] memory leaves_
    ) {
        PM = pm;
        L = l;
        pool = l.pool();
        hook = l.hook();
        imdstr = imdstr_;
        token = l.token();
        claimants = who;
        allowances = amounts;
        leaves = leaves_;
        for (uint256 i; i < 3; ++i) {
            traders[i] = new Trader(pm);
            vm.deal(address(traders[i]), 1_000 ether);
        }
        engine = new Engine(pm);
        vm.deal(address(engine), 100 ether);
        refuser = new Refuser();
        refuserCode = address(refuser).code;
        lastFee = pool.fee();
        supplyBefore = IERC20(token).totalSupply();
    }

    function oldPoolCount() external view returns (uint256) {
        return oldPools.length;
    }

    function claimant(uint256 i) external view returns (address) {
        return claimants[i];
    }

    function allowanceOf(uint256 i) external view returns (uint256) {
        return allowances[i];
    }

    modifier tick() {
        supplyBefore = IERC20(token).totalSupply();
        ++calls;
        _;
    }

    /*                               TRADERS                                */

    function buy(uint256 who, uint256 eth) external tick {
        Trader t = traders[bound(who, 0, 2)];
        eth = bound(eth, 1e12, address(t).balance / 4);
        t.swap(pool.poolKey(), true, -int256(eth));
    }

    function sell(uint256 who, uint256 frac) external tick {
        Trader t = traders[bound(who, 0, 2)];
        uint256 coins = IERC20(token).balanceOf(address(t));
        if (coins == 0) return;
        if (!_poolHasEth()) return;
        coins = bound(frac, 1, coins);
        t.swap(pool.poolKey(), false, -int256(coins));
    }

    function engineTrades(uint256 eth) external tick {
        if (hook.perpEngine() != address(engine)) return;
        eth = bound(eth, 1e12, 1 ether);
        engine.swap(pool.poolKey(), true, -int256(eth));
    }

    /*                               HOLDERS                                */

    function claim(uint256 who, uint256 amount) external tick {
        if (L.unclaimedReleased()) return;
        uint256 i = bound(who, 0, 2);
        address a = claimants[i];
        uint256 left = allowances[i] - L.claimedBy(a);
        uint256 reserve = L.claimReserve();
        if (left == 0) return;
        amount = bound(amount, 1, left);
        bytes32[] memory proof = _proof(i);
        vm.startPrank(a);
        imdstr.approve(address(L), amount);
        if (amount > reserve) {
            vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
            L.claim(amount, allowances[i], proof);
        } else {
            L.claim(amount, allowances[i], proof);
            claimedGhost += amount;
        }
        vm.stopPrank();
    }

    /*                               ANYONE                                 */

    function harvest() external tick {
        L.harvest();
    }

    function split() external tick {
        L.split();
    }

    function sendFees(uint256 amount, bool viaAddFees) external tick {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        if (viaAddFees) {
            L.addFees{value: amount}();
        } else {
            (bool ok,) = address(L).call{value: amount}("");
            require(ok);
        }
    }

    function perpFees(uint256 amount) external tick {
        amount = bound(amount, 1, 2 ether);
        vm.deal(address(this), amount);
        address to = L.perpFeeTo();
        if (to == POT && potRefuses) {
            // the sink refuses: the flush still succeeds, and all of it is kept here for the sink as owed
            uint256 owedBefore = L.owed(to);
            uint256 totalBefore = L.owedTotal();
            uint256 heldBefore = address(L).balance;
            L.addPerpFees{value: amount}();
            assertEq(L.owed(to) - owedBefore, amount, "perp fees refused: owed to the sink, all of it");
            assertEq(L.owedTotal() - totalBefore, amount, "perp fees refused: counted in owedTotal");
            assertEq(address(L).balance - heldBefore, amount, "perp fees refused: kept here");
            return;
        }
        uint256 before = to.balance;
        L.addPerpFees{value: amount}();
        assertEq(to.balance - before, amount, "perp fees: all of it, straight through");
    }

    function payOwed(uint256 seed) external tick {
        address p = seed % 2 == 0 ? POT : R;
        uint256 due = L.owed(p);
        if (due > L.owedTotal()) due = L.owedTotal();
        if (due == 0) return;
        if (p == POT && potRefuses) {
            vm.expectRevert();
            L.payOwed(p);
            return;
        }
        uint256 before = p.balance;
        L.payOwed(p);
        assertEq(p.balance - before, due, "payOwed: all of it, or nothing");
    }

    function burnImd() external tick {
        if (L.imdBucket() == 0) return;
        uint256 bucket = L.imdBucket();
        uint256 last = L.lastImdBuy();
        if (last != 0 && block.timestamp < last + L.IMD_BUY_GAP()) {
            // within the gap: refused whole, the bucket untouched
            vm.expectRevert(IMD6900RobinhoodLaunch.TooSoon.selector);
            L.burnImd(0);
            assertEq(L.imdBucket(), bucket, "a buy too soon spends nothing");
            return;
        }
        uint256 execBefore = IERC20(L.IMD()).balanceOf(L.imdBurn());
        uint256 spend = bucket < L.IMD_BUY_MAX() ? bucket : L.IMD_BUY_MAX();
        try L.burnImd(0) returns (uint256 got) {
            assertGt(got, 0, "a buy that returns nothing reverts instead");
            assertEq(IERC20(L.IMD()).balanceOf(L.imdBurn()) - execBefore, got, "the $IMD lands at the executor");
            assertEq(bucket - L.imdBucket(), spend, "charged what the pool took: at most 0.1 ETH, all of it here");
            assertEq(L.lastImdBuy(), block.timestamp, "the gap starts now");
        } catch (bytes memory err) {
            // the only refusal left: a dust bucket the pool's fee rounds to nothing, which spends nothing
            assertEq(bytes4(err), IMD6900RobinhoodLaunch.Short.selector, "burnImd refused for another reason");
            assertLt(spend, 1e6, "a buy of more than dust must go through");
            assertEq(L.imdBucket(), bucket, "a refused buy spends nothing");
            assertEq(L.lastImdBuy(), last, "and starts no gap");
        }
    }

    function setPotRefuses(bool on) external tick {
        if (on) vm.etch(POT, refuserCode);
        else vm.etch(POT, "");
        potRefuses = on;
    }

    function warp(uint256 dt) external tick {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    /*                                OWNER                                 */

    function releaseUnclaimed(uint256 toSeed) external tick {
        if (L.unclaimedReleased() || block.timestamp < L.claimDeadline()) return;
        address to = toSeed % 2 == 0 ? address(0) : R;
        vm.prank(OWNER);
        L.releaseUnclaimed(to);
        releasedSeen = true;
    }

    function releaseImdstr(uint256 amount) external tick {
        uint256 held = imdstr.balanceOf(address(L));
        if (held == 0) return;
        amount = bound(amount, 0, held);
        vm.prank(OWNER);
        L.releaseImdstr(amount, R);
        imdstrReleased += amount == 0 ? held : amount;
    }

    /*                              TIMELOCK                                */

    function lowerFee(uint256 f) external tick {
        uint24 cur = pool.fee();
        if (cur == 0) return;
        uint24 nf = uint24(bound(f, 0, cur - 1));
        (uint160 p0,,) = pool.state();
        uint128 l0 = pool.liquidity();
        oldPools.push(pool.poolId());
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(nf);
        (uint160 p1,,) = pool.state();
        assertEq(p1, p0, "lowerFee keeps the price");
        assertLe(l1, l0, "lowerFee never makes liquidity");
        assertGe(l1, l0 - l0 / 1e9 - 1, "lowerFee moves all of it, to the rounding");
        lastFee = nf;
    }

    function endClaims() external tick {
        if (L.unclaimedReleased()) return;
        uint256 held = L.excessHeld();
        uint256 unclaimed = L.claimReserve();
        vm.prank(TL);
        L.endClaims();
        assertEq(L.excessHeld(), held + unclaimed, "the unclaimed rest joins the held coins");
        releasedSeen = true;
    }

    function releaseExcess(uint256 amount, uint256 toSeed) external tick {
        uint256 held = L.excessHeld();
        if (held == 0) return;
        amount = bound(amount, 1, held);
        address to = toSeed % 2 == 0 ? address(0) : R;
        vm.prank(TL);
        L.releaseExcess(amount, to);
        assertEq(L.excessHeld(), held - amount);
    }

    function sellHeld(uint256 amount) external tick {
        uint256 held = L.excessHeld();
        if (held == 0 || !_poolHasEth()) return;
        amount = bound(amount, 1, held);
        uint256 before = R.balance;
        vm.prank(TL);
        uint256 eth = L.sellHeld(amount, 0, R);
        assertEq(R.balance - before, eth, "the ETH lands where told");
        assertGe(L.excessHeld(), held - amount, "what the pool can't take stays held");
        if (L.excessHeld() > held - amount) {
            assertFalse(_poolHasEth(), "a sale the pool took only part of must have drained it");
        }
    }

    function recoverEth(uint256 amount) external tick {
        uint256 bal = address(L).balance;
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(TL);
        L.recoverEth(R, amount);
    }

    function setPayees(uint256 seed) external tick {
        address[] memory to;
        uint16[] memory bps;
        uint256 c = seed % 4;
        if (c == 0) {
            (to, bps) = (new address[](2), new uint16[](2));
            (to[0], bps[0], to[1], bps[1]) = (POT, 9_000, L.IMD_BURN(), 1_000);
        } else if (c == 1) {
            (to, bps) = (new address[](1), new uint16[](1));
            (to[0], bps[0]) = (R, 10_000);
        } else if (c == 2) {
            (to, bps) = (new address[](3), new uint16[](3));
            (to[0], bps[0], to[1], bps[1], to[2], bps[2]) = (POT, 5_000, R, 2_500, L.IMD_BURN(), 2_500);
        } else {
            (to, bps) = (new address[](1), new uint16[](1));
            (to[0], bps[0]) = (L.IMD_BURN(), 10_000);
        }
        vm.prank(TL);
        L.setPayees(to, bps);
    }

    function setEngine(bool on) external tick {
        vm.prank(TL);
        hook.setPerpEngine(on ? address(engine) : address(0));
    }

    /*                               HELPERS                                */

    /// @dev Selling into the pool needs its price below the position's top (above it there is no ETH to buy, and v4
    ///      refuses a swap whose limit the price already passed)
    function _poolHasEth() internal view returns (bool) {
        (uint160 p,,) = pool.state();
        return p < TickMath.getSqrtPriceAtTick(pool.upperTick());
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 2) {
            p = new bytes32[](1);
            p[0] = _hash(leaves[0], leaves[1]);
        } else {
            p = new bytes32[](2);
            p[0] = leaves[i == 0 ? 1 : 0];
            p[1] = leaves[2];
        }
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract IMD6900InvariantTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant POT = 0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant OPEN_MC = 19.18 ether;
    uint256 constant BUY = 2.81 ether;
    address constant A = address(0xA);
    address constant B = address(0xB);
    address constant C = address(0xC);
    uint256 constant AA = 40_000_000 ether;
    uint256 constant BB = 20_000_000 ether;
    uint256 constant CC = 3_935_747 ether;

    IPoolManager PM;
    IMD6900RobinhoodLaunch L;
    IMD6900LockedPool pool;
    IMD6900Hook hook;
    MockImdstr imdstr;
    address token;
    LaunchHandler h;
    uint256 claimTotal;

    function setUp() public {
        PM = IPoolManager(address(new PoolManager(address(this))));
        imdstr = new MockImdstr();
        L = new IMD6900RobinhoodLaunch(OWNER, PM, address(imdstr), TL);
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        imdstr.mint(A, AA);
        imdstr.mint(B, BB);
        imdstr.mint(C, CC);
        bytes32[3] memory leaves = [_leaf(A, AA), _leaf(B, BB), _leaf(C, CC)];
        bytes32 root = _hash(_hash(leaves[0], leaves[1]), leaves[2]);
        // the reserve is less than the leaves' sum: the last claimant runs into the reserve's cap
        claimTotal = AA + BB + CC / 2;
        vm.prank(OWNER);
        L.setClaims(root, claimTotal, block.timestamp + 100 days);

        // $IMD and its pool, as on Robinhood: ETH / $IMD, 1%, tick spacing 100, no hooks
        address imd = L.IMD();
        vm.etch(imd, address(new MockImdstr()).code);
        LiquidityAdder adder = new LiquidityAdder(PM);
        vm.deal(address(adder), 100 ether);
        MockImdstr(imd).mint(address(adder), 1e30);
        PM.initialize(L.imdPoolKey(), uint160(_sqrt(261 << 192)));
        adder.add(L.imdPoolKey(), 1e21);

        // the launch as script/launch.sh does it: the excess kept here for the timelock
        bytes32 salt = CoinSalt.mine(L);
        address expected = L.tokenAddress(salt);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (token,) = L.launch{value: BUY}(salt, expected, _sqrtPrice(OPEN_MC), 0, address(L));

        h = new LaunchHandler(PM, L, imdstr, [A, B, C], [AA, BB, CC], leaves);
        targetContract(address(h));
    }

    /// Every coin the launch holds is spoken for: the claims' reserve, or the timelock's (nothing is stranded, and
    /// nothing is handed out twice)
    function invariant_TheCoinsHeldAreTheReserveAndTheTimelocks() public view {
        assertEq(IERC20(token).balanceOf(address(L)), L.claimReserve() + L.excessHeld());
    }

    /// The ETH the launch holds covers what it has set aside: the $IMD bucket and every refused share
    function invariant_TheEthHeldCoversTheBucketAndTheOwed() public view {
        assertGe(address(L).balance, L.imdBucket() + L.owedTotal());
        assertLe(L.owedTotal(), L.owed(POT) + L.owed(address(0x2E7)), "owedTotal never exceeds what payees are owed");
    }

    /// The locked pool contract keeps nothing of its own: every op pays out what it takes
    function invariant_ThePoolContractHoldsNothing() public view {
        assertEq(address(pool).balance, 0);
        assertEq(IERC20(token).balanceOf(address(pool)), 0);
    }

    /// All of the current pool's liquidity is the one locked position, and every pool it left is empty. The position
    /// runs from the lowest price up to the opening tick: while the price is under that tick it is the pool's whole
    /// in-range liquidity; at or above it (the pool holds no ETH, as at the opening or after a sale that drained it)
    /// nothing is in range, and the position still holds every coin
    function invariant_AllTheLiquidityIsTheLockedPosition() public view {
        PoolId id = pool.poolId();
        uint128 liq = pool.liquidity();
        assertGt(liq, 0);
        (uint160 p,,) = pool.state();
        if (p < TickMath.getSqrtPriceAtTick(pool.upperTick())) {
            assertEq(PM.getLiquidity(id), liq, "in-range liquidity is the position's");
        } else {
            assertEq(PM.getLiquidity(id), 0, "above the opening tick nothing is in range");
        }
        bytes32 pid = Position.calculatePositionKey(address(pool), pool.LOWER_TICK(), pool.upperTick(), bytes32(0));
        assertEq(PM.getPositionLiquidity(id, pid), liq, "the position's liquidity is what the pool records");
        for (uint256 i; i < h.oldPoolCount(); ++i) {
            assertEq(PM.getLiquidity(h.oldPools(i)), 0, "an old pool is empty");
            assertEq(PM.getPositionLiquidity(h.oldPools(i), pid), 0);
        }
    }

    /// The fee only ever falls, and the hook serves the newest pool at that fee
    function invariant_TheFeeOnlyFallsAndTheHookFollows() public view {
        assertEq(pool.fee(), h.lastFee());
        assertLe(pool.fee(), 44_400);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(pool.poolId()));
        assertEq(pool.poolKey().fee, pool.fee());
        assertEq(hook.perpFeeBps(), pool.fee() / 100);
    }

    /// The coin's supply never rises: only burns change it
    function invariant_TheSupplyNeverRises() public view {
        assertLe(IERC20(token).totalSupply(), h.supplyBefore());
        assertLe(IERC20(token).totalSupply(), SUPPLY);
    }

    /// Claims: never past the reserve, never past a holder's snapshot, 1:1, the IMDSTR kept (or released by the owner)
    function invariant_ClaimsAreBoundedAndOneForOne() public view {
        assertLe(L.claimedTotal(), claimTotal);
        assertEq(L.claimedTotal(), h.claimedGhost());
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            address a = h.claimant(i);
            assertLe(L.claimedBy(a), h.allowanceOf(i));
            assertEq(IERC20(token).balanceOf(a), L.claimedBy(a), "1:1, and holders here never trade");
            sum += L.claimedBy(a);
        }
        assertEq(sum, L.claimedTotal());
        assertEq(imdstr.balanceOf(address(L)) + h.imdstrReleased(), L.claimedTotal(), "the IMDSTR stays until released");
    }

    /// Once the claims end, they stay ended, and the reserve is zero
    function invariant_EndedClaimsStayEnded() public view {
        if (h.releasedSeen()) {
            assertTrue(L.unclaimedReleased());
            assertEq(L.claimReserve(), 0);
        }
    }

    /// The launch itself is final: the coin, the opening buy, the claim list
    function invariant_TheLaunchIsFinal() public view {
        assertEq(L.token(), token);
        assertEq(L.launchEth(), BUY);
        assertEq(uint160(token) >> 144, 0x6900);
        assertEq(address(pool.hook()), address(hook));
        assertEq(hook.owner(), TL);
    }

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function _sqrtPrice(uint256 mc) internal pure returns (uint160) {
        return uint160(_sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, mc)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) (y, z) = (z, (x / z + z) / 2);
    }
}
