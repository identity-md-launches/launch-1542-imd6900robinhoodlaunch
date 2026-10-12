#!/usr/bin/env python3
"""The opening price and the opening buy for IMD6900RobinhoodLaunch.launch: chosen so that, after the buy, the coin on
Robinhood trades at IMD6900's price on Ethereum (read live from its pool).

    python3 script/params.py [--buy 2.81] [--slippage 2]

The locked position holds the whole supply from the opening price down, so it trades like a constant product pool
with x0 = the opening market cap in ETH and y0 = the supply. A buy of d ETH (after the pool's 4.44%) moves the market
cap to (x0 + d)^2 / x0. The pool opens on a tick (a multiple of 60, 0.6% apart), so: solve x0 for the whole --buy,
round the opening onto its tick (rounding the coins per ETH down, so x0 up), then size the buy to land exactly on
Ethereum's price from that tick: a little under --buy. Prints the launch's sqrtPriceX96 (mid-tick, so the contract's
rounding keeps that tick), the buy in wei, the coins it lands and the minBought floor.
"""
import argparse, json, math, os, subprocess
from decimal import Decimal, getcontext

getcontext().prec = 60

ETH_RPC = os.environ.get("ETH_RPC_URL", "https://ethereum-rpc.publicnode.com")
PM = "0x000000000004444c5dc75cB358380D2e3dE08A90"
SLOT0 = "0x7e47497a4b220e6c3be61258e56d7f872887172456bb19561cb09c9f93025f88"  # IMD6900's Ethereum pool, in the PoolManager
IMD6900_ETH = "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F"
SUPPLY = 10**9
SPACING = 60
FEE = 0.0444  # the pool's static fee, the opening buy's too (it returns through the fee split)


def cast(*a):
    return subprocess.check_output(["cast", *a], text=True, env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}).split()[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--buy", type=float, default=2.81, help="the most the opening buy spends, ETH")
    ap.add_argument("--slippage", type=float, default=2.0, help="percent under the expected buy for minBought")
    a = ap.parse_args()
    raw = int(cast("storage", PM, SLOT0, "--rpc-url", ETH_RPC), 16)
    sq = raw & ((1 << 160) - 1)
    eth_per_coin = 1 / (sq / 2**96) ** 2  # ETH is currency0 there: the price is coins per ETH
    eth_supply = int(cast("call", IMD6900_ETH, "totalSupply()(uint256)", "--rpc-url", ETH_RPC)) / 1e18
    target = eth_per_coin * SUPPLY  # Ethereum's price, on a billion coins
    d = a.buy * (1 - FEE)
    disc = (target - 2 * d) ** 2 - 4 * d * d
    if disc < 0: raise SystemExit(f"a {a.buy} ETH buy would overshoot Ethereum's price ({target:.2f} ETH on 1B): buy less")
    x0 = ((target - 2 * d) + math.sqrt(disc)) / 2
    tick = math.floor(math.log(SUPPLY / x0) / math.log(1.0001)) // SPACING * SPACING  # the contract's floor onto 60
    x0 = SUPPLY / 1.0001 ** tick  # the opening market cap the tick gives: a little above
    d = math.sqrt(target * x0) - x0  # the buy, after the fee, that lands on Ethereum's price from there
    buy = d / (1 - FEE)
    if not 0 < buy <= a.buy: raise SystemExit(f"no tick lands on Ethereum's price within {a.buy} ETH")
    bought = SUPPLY * d / (x0 + d)
    sqrt_price = int((Decimal("1.0001") ** (Decimal(tick) + Decimal("0.5"))).sqrt() * 2**96)  # mid-tick
    out = {
        "ethereum": {"ethPerCoin": eth_per_coin, "supply": eth_supply, "marketCapEth": eth_per_coin * eth_supply},
        "openTick": tick, "openMarketCapEth": x0, "afterMarketCapEthOn1B": (x0 + d) ** 2 / x0,
        "targetMarketCapEthOn1B": target, "buyEth": buy, "buyWei": str(int(buy * 1e18) // 10**9 * 10**9),
        "expectedBought": bought, "sqrtPriceX96": str(sqrt_price),
        "minBought": str(int(bought * (1 - a.slippage / 100)) * 10**18),
    }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
