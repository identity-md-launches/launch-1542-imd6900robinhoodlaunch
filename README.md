# IMD6900 on Robinhood Chain: the coin, a locked Uniswap v4 pool, the perps hook

Identity.MD 6900 (IMD6900) relaunched on Robinhood Chain as a plain coin with its whole supply in a locked Uniswap v4
pool, deployed by the IMD swarm (`evm_contracts`) and launched through Programmable (custom launch, open provenance) at a
0x6900… address. It replaces the old IMDSTR market (pulled to the Pons launcher, 2.83 ETH): that ETH is the opening buy,
and the old IMDSTR claims the new coin 1:1, up to each holder's snapshot balance.

## The contracts

| | |
|---|---|
| `src/IMD6900RobinhoodLaunch.sol` | What the swarm deploys. Its constructor creates the pool and mines the hook's address; it calls nothing that existed before it. Then the launch, the claims, the fee split. |
| `src/IMD6900.sol` | The coin: 1B minted once to the launch. No owner, no mint, no tax, no pause, no blacklist, no limits, no proxy. Holders can burn their own. |
| `src/IMD6900LockedPool.sol` | Owns the pool's one position. No owner, no way to take liquidity out. `collect()` (anyone): ETH fees to the split, IMD6900 fees burned. |
| `src/IMD6900Hook.sol` | ETH / IMD6900 only, initialized once by the locked pool, liquidity from it only; in-pool perps sweep once the timelock wires an engine. No return deltas, no dynamic fee, not upgradeable: Uniswap routes the pool automatically. Owned by the Robinhood timelock. |

## The launch, one transaction

`launch(salt, expectedToken, sqrtPriceX96, minBought, excessTo)`, from the team wallet, with the ETH:

1. creates IMD6900 with CREATE2 from the launch (reverts unless it lands at `expectedToken`, the mined 0x6900… address);
2. opens the pool at `sqrtPriceX96` with all 1B as IMD6900-only liquidity from that price down: no ETH needed, locked;
3. buys first with every wei the launch holds (nobody can trade before: the coin didn't exist a moment earlier);
4. keeps the claims' reserve, and keeps the rest of what it bought in the launch: only the timelock can release it (`releaseExcess`, 12h public delay), so no wallet ever holds it.

The opening price comes from `script/params.py`: chosen so that after the buy the coin trades at IMD6900's Ethereum
price (2.81 ETH: open at ~19.2 ETH market cap, land at ~25.2, ~126.7M bought). The pool's 1% fee then splits 70% to the
pot bridge (Ethereum's NFT pot), 10% to $IMD's burn (bought on $IMD's Robinhood pool, sent to IMD's official burn
executor `0x4D65…1e07`, which bridges it to Base), 20% ops; the IMD6900 part is burned.

## Red flags, and why there are none

Plain coin (nothing anyone can change), the liquidity locked by construction (no remove path exists), the hook not
upgradeable and owned by the 12h timelock, the opening buy in the same transaction as the pool (no snipe window), the
bought coins in a contract (the claims' reserve) or burned, never in a wallet. Owner powers left on the launch: the
claim list before the launch, the payees, releasing the unclaimed reserve after the claim deadline (≥ 90 days), the
IMDSTR the claims collected. The hook's owner (the timelock) wires the perps engine: an engine is called before every
swap, so it goes in only behind the delay.

## Tests

```sh
forge test                                         # 25 tests, offline: admission, launch, pool, fees, $IMD burn, claims
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract RobinhoodFork -vv
```

The fork test runs the whole thing on live Robinhood state: the real PoolManager, IMDSTR (claims after the timelock's
distributor op), the pot bridge, $IMD's pool and burn executor, and a buy through Uniswap's Universal Router.

## Runbook: `script/launch.sh`

The contracts don't depend on Programmable: the last step decides between launching straight on Uniswap and launching
through Programmable (the same `launch()`, after their review, with their stamp and listing). Each step signs with the
team wallet's keystore (`imdstr-deployer`); `script/launch.sh status` shows where things stand.

1. `fund`: the Pons launcher's 2.83 ETH back to the team wallet.
2. `deploy`: the launch contract (its constructor creates the locked pool and mines the hook).
3. `claims`: the claim list from live balances capped at the snapshot (35 holders, ~63.9M), deadline in 120 days.
4. `queue-claims`, then `open-claims` 12h later: the timelock makes the launch an IMDSTR distributor.
5. `mine`: the coin's 0x6900… address for this launch.
6. Either `direct` (live on Uniswap in one transaction), or `programmable` (plan built from the exact source, packed with
   Programmable's packer, preflighted), `submit` (their manual review, up to 24h), `review`, then the team wallet signs
   `launch` in the approved 24h window, then the stamp.

Rehearsed end to end, both ways, on forks of Robinhood (`SIGN_ARGS="--unlocked --from <team>" RPC=<fork>`).
