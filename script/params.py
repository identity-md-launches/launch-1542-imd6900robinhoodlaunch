#!/usr/bin/env python3
"""The opening price for IMD6900RobinhoodLaunch.launch: chosen so that, after the opening buy, the coin on Robinhood
trades at IMD6900's price on Ethereum (read live from its pool).

    python3 script/params.py [--buy 2.81] [--slippage 2]

The locked position holds the whole supply from the opening price down, so it trades like a constant product pool
with x0 = the opening market cap in ETH and y0 = the supply. A buy of d ETH (after the pool's 1%) moves the market
cap to (x0 + d)^2 / x0; this solves for x0 so that lands on Ethereum's price. Prints the launch's sqrtPriceX96, the
coins the buy lands and the minBought floor.
"""
import argparse, json, math, os, subprocess

ETH_RPC = os.environ.get("ETH_RPC_URL", "https://ethereum-rpc.publicnode.com")
PM = "0x000000000004444c5dc75cB358380D2e3dE08A90"
SLOT0 = "0x7e47497a4b220e6c3be61258e56d7f872887172456bb19561cb09c9f93025f88"  # IMD6900's Ethereum pool, in the PoolManager
IMD6900_ETH = "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F"
SUPPLY = 10**9
FEE = 0.01


def cast(*a):
    return subprocess.check_output(["cast", *a], text=True, env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}).split()[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--buy", type=float, default=2.81, help="the opening buy, ETH")
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
    bought = SUPPLY * d / (x0 + d)
    coins_per_eth = SUPPLY / x0
    sqrt_price = int(math.isqrt(int(coins_per_eth * 2**192)))
    out = {
        "ethereum": {"ethPerCoin": eth_per_coin, "supply": eth_supply, "marketCapEth": eth_per_coin * eth_supply},
        "openMarketCapEth": x0, "afterMarketCapEthOn1B": (x0 + d) ** 2 / x0,
        "buyEth": a.buy, "buyWei": str(int(round(a.buy * 1e18))), "expectedBought": bought,
        "sqrtPriceX96": str(sqrt_price), "minBought": str(int(bought * (1 - a.slippage / 100)) * 10**18),
    }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
