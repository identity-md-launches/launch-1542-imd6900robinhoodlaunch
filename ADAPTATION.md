# Adaptation for the IMD `evm_contracts` launch on Robinhood Chain (chain id 4663)

The launch deploys one contract, `IMD6900RobinhoodLaunch`, with four constructor arguments in this order:
`0x35da9c0303507ddf708e87f2568eddf12c47a059` (owner, the team wallet), `0x8366a39CC670B4001A1121B8F6A443A643e40951`
(Uniswap v4's PoolManager on Robinhood Chain), `0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F` (IMDSTR),
`0x16D3f65B708883DF042d98E1C7a49B32A33E2A14` (the Robinhood timelock). The manifest is the next step's; nothing here writes it.

## What the launch rules required: nothing

The project already fits the launch kind as it arrived, so no change was made for the rules themselves:

- **Constructor.** Nonpayable, four `address`-typed arguments (the PoolManager is an interface type, an address word),
  no initializer, no proxy. The owner is the first argument, never `msg.sender`. It calls nothing that existed before it:
  it only creates `IMD6900LockedPool` with `new`, which also calls nothing. Rehearsed offline against the protected
  floor's probe (CREATE2 from an etched factory, `vm.chainId(4663)`, the four arguments above): the constructor runs on
  an empty chain, ~7.1M gas through the probe, init code 32,829 bytes (< 49,152), runtime 22,592 bytes (< 24,576),
  no CALLCODE / DELEGATECALL / SELFDESTRUCT in the runtime. `test_DeploysOnAFreshChain`, `test_FitsOneTransaction`
  and `test_PassesTheAdmissionScan` cover the same in the suite.
- **Libraries.** Every library function called (solady, v4-core's `Hooks`, `TickMath`, `FullMath`, `StateLibrary`,
  `LPFeeLibrary`, `PoolIdLibrary`) is `internal`: the bytecode links nothing.
- **Forbidden powers.** The coin has no owner, mint, pause, blacklist or tax; the locked pool has no owner and no
  liquidity removal (only `lowerFee`'s move into the next pool); nothing is upgradeable. Unchanged.
- **The hook.** Not a contract this launch deploys: `createHook(salt)` creates it from the launch after the deploy, at a
  salt mined off-chain (`script/launch.sh hook`), as the brief requires. Unchanged.
- **Configuration, dependencies.** `foundry.toml`, `remappings.txt`, `lib/` untouched (solc 0.8.26, via-IR, 200 runs,
  cancun, `bytecode_hash = "none"`). Everything builds offline.

## Audit findings: reproduced and fixed

Each finding was reproduced against the code as it arrived before anything was changed (the proof for the first one as
supplied, local tests for the other two); all three reproduced. The fixes are the smallest that close them.

### 1. `split()` re-split a payee's refused share into the $IMD bucket (medium, 5bb80824…) — fixed

Reproduced with the supplied proof: with the pot bridge refusing ETH, sixty `split()` calls moved the pot's 0.9 ETH
down to an `imdBucket` of 0.998 ETH.

`src/IMD6900RobinhoodLaunch.sol`:
- A refused share is now recorded as `owed[payee]` and summed in `owedTotal`; `split()` divides only
  `balance - imdBucket - owedTotal`, so a refused share is never split again (`_pay`, `PayFailed` still emitted).
- The next `split()` that lists the payee pays what it is owed along with its new share; `payOwed(payee)` (anyone)
  retries for a payee the timelock has since removed from the split. Both pay all of it or nothing.
- `recoverEth` (the timelock's escape hatch, documented for exactly "a payee that refused its share") keeps its
  behaviour and now also clamps `owedTotal` to what is left after the $IMD bucket, so a recovered share is forgotten
  rather than stranding `split()` or `payOwed`.

Tests: `test_ARefusedShareIsKeptForItsPayee` (the proof's scenario: `imdBucket` stays 0.1 ETH, 0.9 ETH owed to the
pot, paid by the next split once it takes ETH again), `test_ARefusedShareIsPaidOnRetry` (`payOwed`, and a repointed
split cannot take the owed share), `test_TheTimelockCanRecoverARefusedShare` (`recoverEth` over an owed share, then
`split()` keeps working).

### 2. A perps engine that can't run halts every trade in the only pool (medium, 2fa4137a…) — reproduced; mitigated, with a documented trust assumption

Reproduced: after `setPerpEngine` with a contract whose fallback reverts, every swap on the pool reverted with
`SweepUnavailable`.

The fail-closed sweep is the project's design, and the brief binds the hook's behaviour and the timelock's role (it
wires the engine, behind its public delay, and holds the `sweepFailOpen` escape hatch). The launch's reference says an
owner power the brief asks for stays and is documented as a trust assumption, so the sweep itself is unchanged.

`src/IMD6900Hook.sol`: `setPerpEngine` now refuses an address that has no code or that cannot answer
`openCount()` (`NotAnEngine`), so a mistaken address (an EOA, a wrong contract, a not-yet-deployed engine) can no
longer freeze trading until the timelock's next delay runs out. Zero still turns perps off. This does not stop a
deliberately malicious engine that answers `openCount()` and reverts in `sweepLiquidations`: that remains the Robinhood
timelock's trust assumption, already stated in the README (an engine is called before every swap, so it goes in only
behind the 12h public delay), with `sweepFailOpen` and `setPerpEngine(0)` as the ways out, each behind the same delay.

Tests: `test_TheHookRefusesAnEngineThatCantAnswer` (an EOA and an always-reverting contract are refused, trading goes on;
a real engine is accepted; zero turns perps off). `test_OnlyTheTimelockRunsTheHook` used `address(1)` as the engine and
now uses the stand-in engine, since a bare address is exactly what the fix refuses.

### 3. `claim()` did not bound `claimedTotal` by `claimTotal` (low, 90b69d78…) — fixed

Reproduced: a root whose leaves summed to 60M with `claimTotal` 50M paid both claims in full, the last 10M out of the
timelock's held coins, after which `claimReserve()`, `endClaims()` and `releaseUnclaimed()` reverted on underflow.

`src/IMD6900RobinhoodLaunch.sol`: `claim()` reverts with `OverClaim` once `claimedTotal + amount` would exceed
`claimTotal`. The reserve is the ceiling; the held coins stay the timelock's.

Test: `test_ClaimsNeverPassTheReserve` (the reserve filled, the next claim refused, the held coins untouched,
`endClaims` works).

### 4. Configured after deployment (info, 47fdccfd…) — left as the brief requires

`createHook(salt)`, `setClaims`, `setPayees` and `hook.setPerpEngine` are post-deploy steps. The brief approves them
("the team calls it, the deploy does not need to") and binds the source, so they stay. `createHook` is open to anyone
and every salt it accepts makes the same hook (same code, permissions and owner), so being front-run is harmless; the
constructor itself needs no post-deploy call to be fully configured.

### 5. Scope (info, 4a06f2e5…) — not a defect

Nothing to do. `test/RobinhoodFork.t.sol` was run once here against `https://rpc.mainnet.chain.robinhood.com` with the
changed source and passed (the whole launch on live state: claims, Universal Router buys, the split to the real pot
bridge, the $IMD buy for the burn executor, the move to 3.33%, the held coins sold back). It still skips without
`ROBINHOOD_RPC_URL`, so the offline suite needs no network.

## Files changed

| File | Change |
|---|---|
| `src/IMD6900RobinhoodLaunch.sol` | `owed` / `owedTotal`, `_pay`, `payOwed`, `OwedPaid`; `split()` over the free balance only; `recoverEth` clamps `owedTotal`; `claim()` bounded by `claimTotal` |
| `src/IMD6900Hook.sol` | `setPerpEngine` refuses a non-engine (`NotAnEngine`) |
| `test/IMD6900RobinhoodLaunch.t.sol` | the five tests above, the `BadEngine` and `Refuser` stand-ins, `test_OnlyTheTimelockRunsTheHook` adjusted |
| `README.md` | the test count, the owed share and the engine check |
| `ADAPTATION.md` | this file |

`forge build` and `forge test` pass offline: 44 tests in `IMD6900RobinhoodLaunchTest`, the fork test skipped without
an RPC. Tests use no environment and pass in any order.
