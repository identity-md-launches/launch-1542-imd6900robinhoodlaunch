// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IMD6900} from "../src/IMD6900.sol";
import {IMD6900Hook} from "../src/IMD6900Hook.sol";
import {IMD6900LockedPool} from "../src/IMD6900LockedPool.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";
import {HookSalt, CoinSalt} from "./HookSalt.sol";
import {IERC20, MockImdstr, Trader, Engine, Refuser} from "./IMD6900RobinhoodLaunch.t.sol";

/// A perps engine the hook accepts (it answers openCount) whose sweep answers as told: reverts, or a status
contract MoodyEngine {
    uint8 public status;
    bool public broken;
    uint256 public open;

    function set(uint8 s, bool b, uint256 o) external {
        (status, broken, open) = (s, b, o);
    }

    function sweepLiquidations(address, int256, bool, uint160) external view returns (uint8) {
        if (broken) revert("sweep down");
        return status;
    }

    function openCount() external view returns (uint256) {
        return open;
    }
}

/// A trader that stops at a price of its choosing
contract LimitTrader {
    IPoolManager immutable pm;
    PoolKey key;
    bool buy;
    int256 amt;
    uint160 limit;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(PoolKey calldata k, bool buy_, int256 amt_, uint160 limit_) external returns (BalanceDelta d) {
        (key, buy, amt, limit) = (k, buy_, amt_, limit_);
        d = abi.decode(pm.unlock(""), (BalanceDelta));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        BalanceDelta d = pm.swap(key, SwapParams(buy, amt, limit), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 v) internal {
        if (v < 0) {
            if (c.isAddressZero()) {
                pm.settle{value: uint128(-v)}();
            } else {
                pm.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(pm), uint128(-v));
                pm.settle();
            }
        } else if (v > 0) {
            pm.take(c, address(this), uint128(v));
        }
    }
    receive() external payable {}
}

/// The inputs the happy path never sends: zero, one, the maximum, the wrong caller, the same call twice, a price
/// off the range, a payee list that doesn't add up, a sweep that can't run
contract IMD6900EdgesTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xA11CE);
    address constant TL = address(0x71E10C);
    address constant R = address(0x2E7);
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
    IMD6900Hook hook;
    IMD6900LockedPool pool;
    MockImdstr imdstr;
    Trader trader;
    bytes32[] leaves;
    bytes32 SALT;

    function setUp() public {
        PM = IPoolManager(address(new PoolManager(address(this))));
        imdstr = new MockImdstr();
        L = new IMD6900RobinhoodLaunch(OWNER, PM, address(imdstr), TL);
        hook = L.createHook(HookSalt.mine(L));
        pool = L.pool();
        SALT = CoinSalt.mine(L);
        imdstr.mint(A, AA);
        imdstr.mint(B, BB);
        imdstr.mint(C, CC);
        trader = new Trader(PM);
        vm.deal(address(trader), 1_000 ether);
        leaves.push(_leaf(A, AA));
        leaves.push(_leaf(B, BB));
        leaves.push(_leaf(C, CC));
    }

    /*                             BEFORE THE LAUNCH                          */

    function test_NothingAfterTheLaunchRunsBeforeIt() public {
        bytes32[] memory none;
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.claim(1, 1, none);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.split();
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        L.harvest();
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        pool.collect();
        vm.prank(TL);
        vm.expectRevert(IMD6900LockedPool.NotOpen.selector);
        pool.lowerFee(1);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.endClaims();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NotLaunched.selector);
        L.releaseUnclaimed(address(0));
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseExcess(0, TL);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.sellHeld(0, 0, TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.burnImd(0);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.payOwed(POT);
    }

    function test_TheClaimListNeedsBothARootAndATotal() public {
        vm.startPrank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        L.setClaims(bytes32(0), 1, block.timestamp + 100 days);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadClaims.selector);
        L.setClaims(_root(), 0, block.timestamp + 100 days);
        L.setClaims(_root(), AA, block.timestamp + 100 days);
        L.setClaims(bytes32(0), 0, 0); // cleared again: a launch without claims
        vm.stopPrank();
        assertEq(L.claimRoot(), bytes32(0));
        assertEq(L.claimTotal(), 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.setClaims(_root(), AA, block.timestamp + 100 days);
    }

    function test_WithdrawEthEdges() public {
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.withdrawEth(OWNER, 0); // nothing here
        vm.deal(address(L), 1 ether);
        vm.prank(OWNER);
        vm.expectRevert(); // more than is here
        L.withdrawEth(OWNER, 1 ether + 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.withdrawEth(address(this), 1 ether);
        vm.prank(OWNER);
        L.withdrawEth(R, 1);
        assertEq(R.balance, 1, "one wei");
        assertEq(address(L).balance, 1 ether - 1);
    }

    function test_TheLaunchNeedsEth() public {
        vm.prank(OWNER);
        L.setClaims(bytes32(0), 0, 0);
        address expected = L.tokenAddress(SALT);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.launch(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(0));
        assertEq(L.token(), address(0), "nothing launched: the whole transaction reverted");
    }

    function test_TheLaunchNeedsTheHook() public {
        IMD6900RobinhoodLaunch bare = new IMD6900RobinhoodLaunch(OWNER, PM, address(imdstr), TL);
        IMD6900LockedPool p = bare.pool();
        assertEq(p.hook(), address(0));
        vm.prank(address(bare)); // the launch's own call into its pool, before createHook: nothing can open
        vm.expectRevert(IMD6900LockedPool.NoHook.selector);
        p.open(address(imdstr), _sqrtPrice(OPEN_MC), 1);
        assertEq(p.token(), address(0));
    }

    function test_TheLaunchHoldsItsFloor() public {
        _claims();
        address expected = L.tokenAddress(SALT);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        vm.expectPartialRevert(IMD6900RobinhoodLaunch.Short.selector);
        L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), 200_000_000 ether, address(0));
    }

    function test_RefusesAPriceOffTheRange() public {
        _claims();
        address expected = L.tokenAddress(SALT);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900LockedPool.BadPrice.selector);
        L.launch{value: BUY}(SALT, expected, TickMath.MIN_SQRT_PRICE + 1, 0, address(0)); // at the floor: no range
        // an absurd price, 1 coin worth 1e14 ETH: more liquidity than a tick can carry, so v4 refuses
        vm.prank(OWNER);
        vm.expectRevert();
        L.launch{value: BUY}(SALT, expected, TickMath.getSqrtPriceAtTick(-400_000), 0, address(0));
        assertEq(L.token(), address(0));
    }

    function test_LaunchesWithoutClaims() public {
        vm.prank(OWNER);
        L.setClaims(bytes32(0), 0, 0);
        address expected = L.tokenAddress(SALT);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (address t, uint256 bought) = L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), 0, address(0));
        assertEq(IERC20(t).balanceOf(address(L)), 0, "no reserve, the excess burned");
        assertEq(
            L.launchExcess(), bought + (SUPPLY - bought - IERC20(t).balanceOf(address(PM))), "the buy and the dust"
        );
        assertEq(IERC20(t).totalSupply(), IERC20(t).balanceOf(address(PM)), "all that is left is in the pool");
        bytes32[] memory none;
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, 1, none);
    }

    /*                                CLAIMS                                 */

    function test_ClaimEdges() public {
        (address t,) = _launch();
        bytes32[] memory pa = _proof(0);
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.claim(0, AA, pa);
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(AA + 1, AA, pa);
        bytes32[] memory none;
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA, none);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA, _proof(1)); // someone else's proof
        L.claim(1, AA, pa); // one wei
        L.claim(AA - 1, AA, pa); // the rest
        vm.expectRevert(IMD6900RobinhoodLaunch.OverClaim.selector);
        L.claim(1, AA, pa);
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(A), AA);
        // a proof is the claimant's own: B can't use A's leaf
        vm.startPrank(B);
        imdstr.approve(address(L), BB);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadProof.selector);
        L.claim(1, AA, pa);
        vm.stopPrank();
    }

    function test_ClaimsNeedTheImdstr() public {
        _launch();
        bytes32[] memory pa = _proof(0);
        vm.prank(A); // approved nothing: IMDSTR won't move, the claim fails whole
        vm.expectRevert();
        L.claim(1, AA, pa);
        assertEq(L.claimedBy(A), 0);
        assertEq(L.claimedTotal(), 0);
    }

    function test_ReleaseUnclaimedOnceAndWhereTold() public {
        (address t,) = _launch();
        vm.warp(block.timestamp + 100 days);
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.releaseUnclaimed(R);
        vm.prank(OWNER);
        L.releaseUnclaimed(R);
        assertEq(IERC20(t).balanceOf(R), AA + BB + CC, "sent, not burned");
        assertEq(IERC20(t).balanceOf(address(L)), 0);
        assertEq(L.claimReserve(), 0);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.releaseUnclaimed(R);
        vm.prank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.AlreadyReleased.selector);
        L.endClaims();
    }

    function test_ReleaseImdstrEdges() public {
        _launch();
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(0, R); // nothing claimed yet
        vm.startPrank(C);
        imdstr.approve(address(L), CC);
        L.claim(CC, CC, _proof(2));
        vm.stopPrank();
        vm.expectRevert(Ownable.Unauthorized.selector);
        L.releaseImdstr(0, R);
        vm.prank(OWNER);
        vm.expectRevert(IMD6900RobinhoodLaunch.ZeroAmount.selector);
        L.releaseImdstr(CC + 1, R);
        vm.prank(OWNER);
        L.releaseImdstr(1, R);
        assertEq(imdstr.balanceOf(R), 1);
        vm.prank(OWNER);
        L.releaseImdstr(0, R);
        assertEq(imdstr.balanceOf(R), CC);
        assertEq(imdstr.balanceOf(address(L)), 0);
    }

    /*                               THE SPLIT                               */

    function test_PayeesMustAddUp() public {
        address[] memory to = new address[](0);
        uint16[] memory bps = new uint16[](0);
        vm.startPrank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // none
        (to, bps) = (new address[](9), new uint16[](9));
        for (uint256 i; i < 9; ++i) {
            (to[i], bps[i]) = (address(uint160(i + 1)), i == 0 ? 2_000 : 1_000);
        }
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // nine
        (to, bps) = (new address[](2), new uint16[](1));
        (to[0], to[1], bps[0]) = (POT, R, 10_000);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // lengths differ
        (to, bps) = (new address[](2), new uint16[](2));
        (to[0], bps[0], to[1], bps[1]) = (POT, 5_000, address(0), 5_000);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // the zero address
        (to[1], bps[1]) = (R, 4_999);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // 9,999
        bps[1] = 5_001;
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps); // 10,001
        (to, bps) = (new address[](8), new uint16[](8));
        for (uint256 i; i < 8; ++i) {
            (to[i], bps[i]) = (address(uint160(0x100 + i)), 1_250);
        }
        L.setPayees(to, bps); // eight, the most
        vm.stopPrank();
        (address[] memory got, uint16[] memory gotBps) = L.payees();
        assertEq(got.length, 8);
        assertEq(got[7], address(0x107));
        assertEq(gotBps[7], 1_250);
        // and fewer again: the old tail is gone
        (to, bps) = (new address[](1), new uint16[](1));
        (to[0], bps[0]) = (R, 10_000);
        vm.prank(TL);
        L.setPayees(to, bps);
        (got,) = L.payees();
        assertEq(got.length, 1);
        assertEq(got[0], R);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_PayeeSharesMustSumToTenThousand(uint16 a, uint16 b, uint16 c) public {
        address[] memory to = new address[](3);
        uint16[] memory bps = new uint16[](3);
        (to[0], to[1], to[2]) = (POT, R, L.IMD_BURN());
        (bps[0], bps[1], bps[2]) = (a, b, c);
        bool ok = uint256(a) + b + c == 10_000;
        vm.prank(TL);
        if (!ok) vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPayees(to, bps);
        (address[] memory got,) = L.payees();
        assertEq(got.length, ok ? 3 : 2);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_TheSplitIsExact(uint256 amount) public {
        _launch();
        amount = bound(amount, 1, 1_000 ether);
        vm.deal(address(this), amount);
        L.addFees{value: amount}();
        uint256 potBefore = POT.balance;
        assertEq(L.split(), amount);
        uint256 toPot = amount * 9_000 / 10_000;
        uint256 toImd = amount * 1_000 / 10_000;
        assertEq(POT.balance - potBefore, toPot, "90% to the pot bridge, rounded down");
        assertEq(L.imdBucket(), toImd, "10% set aside for $IMD");
        assertEq(address(L).balance, amount - toPot, "the dust of rounding waits for the next split");
        assertLe(amount - toPot - toImd, 1);
        assertEq(L.split(), amount - toPot - toImd, "the dust is split again (or nothing is)");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_RecoverEthKeepsTheBooks(uint256 fees, uint256 take) public {
        _launch();
        fees = bound(fees, 10, 100 ether);
        vm.etch(POT, address(new Refuser()).code);
        vm.deal(address(this), fees);
        L.addFees{value: fees}();
        L.split();
        uint256 bucket = L.imdBucket();
        uint256 owedPot = L.owed(POT);
        assertEq(bucket + owedPot, fees - (fees - fees * 9_000 / 10_000 - fees * 1_000 / 10_000));
        take = bound(take, 1, address(L).balance);
        vm.prank(TL);
        L.recoverEth(R, take);
        assertEq(R.balance, take);
        uint256 left = address(L).balance;
        assertGe(left, L.imdBucket() + L.owedTotal(), "solvent");
        assertEq(L.imdBucket(), bucket < left ? bucket : left, "the bucket is kept first");
        assertEq(L.owedTotal(), left - L.imdBucket() < owedPot ? left - L.imdBucket() : owedPot);
        // what is owed is paid in full or not at all, never past what is here for it
        vm.etch(POT, "");
        uint256 due = L.owed(POT) > L.owedTotal() ? L.owedTotal() : L.owed(POT);
        if (due == 0) {
            vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
            L.payOwed(POT);
        } else {
            assertEq(L.payOwed(POT), due);
            assertEq(POT.balance, due);
        }
        assertEq(L.owedTotal(), 0);
        assertGe(address(L).balance, L.imdBucket());
    }

    function test_ARefusedShareOutlivesARepointedBurnExecutor() public {
        _launch();
        vm.etch(POT, address(new Refuser()).code);
        vm.deal(address(this), 1 ether);
        L.addFees{value: 1 ether}();
        L.split();
        vm.prank(TL);
        L.setImdBurn(R); // the default split now names R for the $IMD share
        vm.deal(address(this), 1 ether);
        L.addFees{value: 1 ether}();
        L.split();
        assertEq(L.imdBucket(), 0.2 ether, "the bucket is the burn's, whoever executes it");
        assertEq(L.owed(POT), 1.8 ether);
        assertEq(L.owedTotal(), 1.8 ether);
        assertEq(address(L).balance, 2 ether);
    }

    function test_SettersRefuseTheObviousMistakes() public {
        vm.startPrank(TL);
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setImdBurn(address(0));
        vm.expectRevert(IMD6900RobinhoodLaunch.BadPayees.selector);
        L.setPerpFeeTo(address(L)); // perp fees would loop back here
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.recoverEth(TL, 0); // nothing to recover
        vm.stopPrank();
        vm.expectRevert(IMD6900RobinhoodLaunch.NotTimelock.selector);
        L.recoverEth(address(this), 0);
    }

    /// The perps engine's flush never fails on its sink: what the landing refuses is kept here for it as owed, out of
    /// the split, retried by payOwed once it takes ETH again, and the timelock's recoverEth is the way out meanwhile
    function test_PerpFeesRefusedByTheirLandingAreOwedNotLost() public {
        vm.etch(POT, address(new Refuser()).code);
        vm.deal(address(this), 3 ether);
        L.addPerpFees{value: 1 ether}();
        assertEq(address(L).balance, 1 ether, "kept here");
        assertEq(L.owed(POT), 1 ether, "for the pot");
        assertEq(L.owedTotal(), 1 ether);
        L.addPerpFees{value: 1 ether}(); // twice: it adds up, nothing overwritten
        assertEq(L.owed(POT), 2 ether);
        assertEq(L.owedTotal(), 2 ether);
        // still refusing: the retry fails whole and the books don't move
        vm.expectRevert();
        L.payOwed(POT);
        assertEq(L.owed(POT), 2 ether);
        assertEq(L.owedTotal(), 2 ether);
        // repointed: the new landing gets the next flush straight, the old debt stays the pot's
        vm.prank(TL);
        L.setPerpFeeTo(R);
        L.addPerpFees{value: 1 ether}();
        assertEq(R.balance, 1 ether);
        assertEq(L.owed(R), 0);
        assertEq(L.owed(POT), 2 ether);
        // the pot takes ETH again: anyone retries, all of it at once
        vm.etch(POT, "");
        uint256 before = POT.balance;
        assertEq(L.payOwed(POT), 2 ether);
        assertEq(POT.balance - before, 2 ether);
        assertEq(L.owed(POT), 0);
        assertEq(L.owedTotal(), 0);
        assertEq(address(L).balance, 0);
        vm.expectRevert(IMD6900RobinhoodLaunch.NoEth.selector);
        L.payOwed(POT); // nothing left to retry
    }

    /// After the launch, a refused perp flush stays out of the split: the next split pays only the fees, and a payee
    /// list that names the pot again pays the debt with its share
    function test_OwedPerpFeesStayOutOfTheSplitUntilThePotTakesThem() public {
        _launch();
        vm.etch(POT, address(new Refuser()).code);
        vm.deal(address(this), 2 ether);
        L.addPerpFees{value: 1 ether}();
        assertEq(L.owed(POT), 1 ether);
        L.addFees{value: 1 ether}();
        assertEq(L.split(), 1 ether, "the split is the fees alone, never the pot's debt");
        assertEq(L.imdBucket(), 0.1 ether);
        assertEq(L.owed(POT), 1.9 ether, "the pot refused its share of the split too");
        assertEq(L.owedTotal(), 1.9 ether);
        assertEq(address(L).balance, 2 ether);
        assertEq(L.split(), 0, "nothing beyond the bucket and the owed");
        vm.etch(POT, "");
        vm.deal(address(this), 1 ether);
        L.addFees{value: 1 ether}();
        uint256 before = POT.balance;
        assertEq(L.split(), 1 ether);
        assertEq(POT.balance - before, 0.9 ether + 1.9 ether, "its share and everything it was owed");
        assertEq(L.owed(POT), 0);
        assertEq(L.owedTotal(), 0);
        assertEq(address(L).balance, L.imdBucket());
    }

    function test_BurnImdHoldsItsFloor() public {
        _launch();
        vm.deal(address(this), 1 ether);
        L.addFees{value: 1 ether}();
        L.split();
        assertEq(L.imdBucket(), 0.1 ether);
        // no $IMD pool here: the buy reverts whole, the bucket is untouched
        vm.expectRevert();
        L.burnImd(0);
        assertEq(L.imdBucket(), 0.1 ether);
    }

    /*                              THE CALLBACKS                            */

    function test_OnlyThePoolManagerCallsBack() public {
        vm.expectRevert(IMD6900RobinhoodLaunch.OnlyPoolManager.selector);
        L.unlockCallback(abi.encode(uint8(0), uint256(1)));
        vm.expectRevert(IMD6900LockedPool.OnlyPoolManager.selector);
        pool.unlockCallback(abi.encode(uint8(0), uint128(1)));
        vm.prank(address(PM)); // even the pool manager, outside its own unlock: nothing to settle against
        vm.expectRevert();
        L.unlockCallback(abi.encode(uint8(0), uint256(1)));
    }

    function test_OnlyTheLauncherRunsThePool() public {
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        pool.setHook(address(this));
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.HookAlreadySet.selector);
        pool.setHook(address(this));
        vm.expectRevert(IMD6900LockedPool.OnlyLauncher.selector);
        pool.open(address(this), _sqrtPrice(OPEN_MC), 1);
        _launch();
        vm.prank(address(L));
        vm.expectRevert(IMD6900LockedPool.AlreadyOpen.selector);
        pool.open(address(this), _sqrtPrice(OPEN_MC), 1);
    }

    function test_NobodyElseInitializesAPoolOnTheHook() public {
        (address t,) = _launch();
        PoolKey memory k = pool.poolKey();
        k.fee = 10_000; // the same pair and hook at another fee: the hook refuses anyone but the locked pool
        vm.expectRevert();
        PM.initialize(k, _sqrtPrice(OPEN_MC));
        PoolKey memory other =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imdstr)), 44_400, 60, IHooks(address(hook)));
        vm.expectRevert();
        PM.initialize(other, _sqrtPrice(OPEN_MC));
        t;
    }

    function test_TheHooksCallbacksAreThePoolManagers() public {
        _launch();
        PoolKey memory k = pool.poolKey();
        vm.expectRevert(); // BaseHook: NotPoolManager
        hook.beforeSwap(address(this), k, SwapParams(true, -1, 0), "");
        vm.expectRevert();
        hook.beforeInitialize(address(pool), k, 0);
    }

    /*                               THE SWEEP                               */

    function test_ASweepThatCantRunFailsClosedUnlessTheTimelockOpensIt() public {
        _launch();
        MoodyEngine e = new MoodyEngine();
        vm.prank(TL);
        hook.setPerpEngine(address(e));
        PoolKey memory k = pool.poolKey();
        e.set(0, true, 0); // the sweep reverts
        vm.expectRevert();
        trader.swap(k, true, -1 ether);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setSweepFailOpen(true);
        vm.prank(TL);
        hook.setSweepFailOpen(true);
        trader.swap(k, true, -1 ether); // trades again, blind
        vm.prank(TL);
        hook.setSweepFailOpen(false);
        e.set(2, false, 0); // too many positions to liquidate in one go
        vm.expectRevert();
        trader.swap(k, true, -1 ether);
        e.set(1, false, 0); // the sweep ran out of gas
        vm.expectRevert();
        trader.swap(k, true, -1 ether);
        e.set(0, false, 0); // all clear
        trader.swap(k, true, -1 ether);
        // the sweep only guards trades on the hook's own pool; a sell runs it too
        uint256 coins = IERC20(L.token()).balanceOf(address(trader));
        e.set(2, false, 0);
        vm.expectRevert();
        trader.swap(k, false, -int256(coins));
    }

    function test_TheHookRefusesAnEngineThatLies() public {
        _launch();
        MoodyEngine e = new MoodyEngine();
        vm.prank(TL);
        hook.setPerpEngine(address(e)); // openCount answers: accepted, whatever its sweep does later
        assertEq(hook.perpEngine(), address(e));
        vm.prank(TL);
        hook.setPerpEngine(address(0));
        assertEq(hook.perpEngine(), address(0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setPerpEngine(address(e));
    }

    function test_TheLaunchOwnerCanHandOverTheHookCannotRenounce() public {
        vm.prank(OWNER);
        L.transferOwnership(R);
        assertEq(L.owner(), R);
        vm.prank(TL);
        hook.transferOwnership(R);
        assertEq(hook.owner(), R);
        vm.prank(R);
        vm.expectRevert(IMD6900Hook.NoRenounce.selector);
        hook.renounceOwnership();
    }

    /*                               THE POOL                                */

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_LowerFeeAfterAnyTrades(uint256 buyEth, uint256 sellFrac, uint256 newFee, bool collectFirst)
        public
    {
        (address t,) = _launch();
        PoolKey memory old = pool.poolKey();
        buyEth = bound(buyEth, 1e9, 500 ether);
        trader.swap(old, true, -int256(buyEth));
        uint256 coins = IERC20(t).balanceOf(address(trader));
        sellFrac = bound(sellFrac, 0, coins);
        if (sellFrac != 0) trader.swap(old, false, -int256(sellFrac));
        if (collectFirst) pool.collect();
        (uint160 p0,,) = pool.state();
        uint128 l0 = pool.liquidity();
        uint256 supply = IERC20(t).totalSupply();
        uint24 nf = uint24(bound(newFee, 0, 44_399));
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(nf);
        (uint160 p1,, uint128 inPool) = pool.state();
        assertEq(p1, p0, "same price");
        assertEq(inPool, l1);
        assertEq(pool.liquidity(), l1);
        assertLe(l1, l0);
        assertGe(l1, l0 - l0 / 1e9 - 1, "all of it, to the rounding");
        assertEq(PM.getLiquidity(old.toId()), 0, "the old pool is empty");
        assertEq(address(pool).balance, 0, "the pool keeps nothing");
        assertEq(IERC20(t).balanceOf(address(pool)), 0);
        assertLe(IERC20(t).totalSupply(), supply);
        assertEq(pool.fee(), nf);
        trader.swap(pool.poolKey(), true, -1 ether); // trading goes on
    }

    /// Every coin outside the pool sold back at once: the price climbs as high as the market can take it (never the
    /// opening tick itself: the fee comes out of every sell, so the pool's ETH can't all be bought back), and the
    /// fee still moves
    function test_LowerFeeWithThePriceAsHighAsItGoes() public {
        (address t,) = _launch(address(trader));
        vm.startPrank(A);
        imdstr.approve(address(L), AA);
        L.claim(AA, AA, _proof(0));
        IERC20(t).transfer(address(trader), AA);
        vm.stopPrank();
        uint256 all = IERC20(t).balanceOf(address(trader));
        assertEq(
            all, L.launchExcess() + AA, "the excess and A's claim: every coin outside the pool but B's and C's reserve"
        );
        trader.swap(pool.poolKey(), false, -int256(all));
        (uint160 p,,) = pool.state();
        uint160 top = TickMath.getSqrtPriceAtTick(pool.upperTick());
        assertLt(p, top, "under the top: the fee kept some of the coins back");
        assertGt(p, top - top / 20, "but within a few percent of it");
        assertLt(
            address(PM).balance,
            1 ether,
            "most of the ETH bought back (what's left: the fees earned, and the fee's bite)"
        );
        uint128 l0 = pool.liquidity();
        vm.prank(TL);
        uint128 l1 = pool.lowerFee(33_300);
        assertGe(l1, l0 - l0 / 1e9 - 1);
        (uint160 p1,,) = pool.state();
        assertEq(p1, p);
        trader.swap(pool.poolKey(), true, -1 ether); // and the new pool trades
        assertGt(IERC20(t).balanceOf(address(trader)), 0);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_OpensAtAnyReasonablePrice(uint256 mc) public {
        // from 0.01 ETH to 10M ETH on a billion coins
        mc = bound(mc, 0.01 ether, 10_000_000 ether);
        vm.prank(OWNER);
        L.setClaims(bytes32(0), 0, 0);
        address expected = L.tokenAddress(SALT);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (address t, uint256 bought) = L.launch{value: BUY}(SALT, expected, _sqrtPrice(mc), 0, address(L));
        assertGt(bought, 0);
        (uint160 sq, int24 tick, uint128 inPool) = pool.state();
        assertEq(inPool, pool.liquidity(), "the position is the pool");
        assertLe(tick, pool.upperTick(), "the buy moved the price down from the top");
        assertLt(sq, TickMath.getSqrtPriceAtTick(pool.upperTick()));
        assertEq(IERC20(t).balanceOf(address(PM)) + L.excessHeld(), SUPPLY, "every coin is in the pool or held here");
        assertEq(address(PM).balance, BUY, "every wei of the buy is in the pool");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_SellHeldNeverTouchesTheReserve(uint256 amount, uint256 minEth) public {
        (address t,) = _launch(address(L));
        uint256 held = L.excessHeld();
        amount = bound(amount, 1, held);
        minEth = bound(minEth, 0, BUY);
        vm.prank(TL);
        try L.sellHeld(amount, minEth, R) returns (uint256 eth) {
            assertGe(eth, minEth);
            assertEq(R.balance, eth);
        } catch (bytes memory err) {
            assertEq(bytes4(err), IMD6900RobinhoodLaunch.Short.selector, "only the floor stops it");
            assertEq(L.excessHeld(), held);
        }
        assertGe(IERC20(t).balanceOf(address(L)), AA + BB + CC, "the claims' reserve never moves");
        assertEq(IERC20(t).balanceOf(address(L)), AA + BB + CC + L.excessHeld());
    }

    /*                               HELPERS                                */

    function _launch() internal returns (address t, uint256 bought) {
        return _launch(address(0));
    }

    function _launch(address excessTo) internal returns (address t, uint256 bought) {
        _claims();
        address expected = L.tokenAddress(SALT);
        vm.deal(OWNER, BUY);
        vm.prank(OWNER);
        (t, bought) = L.launch{value: BUY}(SALT, expected, _sqrtPrice(OPEN_MC), 0, excessTo);
    }

    function _claims() internal {
        vm.prank(OWNER);
        L.setClaims(_root(), AA + BB + CC, block.timestamp + 100 days);
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

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _hash(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    function _root() internal view returns (bytes32) {
        return _hash(_hash(leaves[0], leaves[1]), leaves[2]);
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
