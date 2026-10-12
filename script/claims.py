#!/usr/bin/env python3
"""The claim list for IMD6900RobinhoodLaunch.setClaims: every snapshot holder's IMDSTR, as it stands now, capped at the
snapshot (what arrived since doesn't claim), as a Merkle tree the launch verifies (sorted pairs, leaves
keccak256(keccak256(abi.encode(account, amount)))).

    python3 script/claims.py [--snapshot snapshots/rh-community-2026-10-09.json] [--out claims.json]

Writes claims.json: root, total (the reserve the opening buy must cover), and each holder's amount and proof (the
claim page reads it). Prints the setClaims arguments. RPC: ROBINHOOD_RPC_URL, else Robinhood's public one.
"""
import argparse, json, os, subprocess
from decimal import Decimal
from Crypto.Hash import keccak

IMDSTR = "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F"
RPC = os.environ.get("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")


def k(b: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=b).digest()


def leaf(account: str, amount: int) -> bytes:
    enc = bytes.fromhex(account[2:].lower().rjust(64, "0")) + amount.to_bytes(32, "big")
    return k(k(enc))


def pair(a: bytes, b: bytes) -> bytes:
    return k(a + b) if a < b else k(b + a)


def tree(leaves):
    """layers bottom-up; an odd node out goes up as it is"""
    layers = [leaves]
    while len(layers[-1]) > 1:
        cur, nxt = layers[-1], []
        for i in range(0, len(cur), 2):
            nxt.append(pair(cur[i], cur[i + 1]) if i + 1 < len(cur) else cur[i])
        layers.append(nxt)
    return layers


def proof(layers, i):
    out = []
    for layer in layers[:-1]:
        j = i ^ 1
        if j < len(layer): out.append(layer[j])
        i //= 2
    return out


def balance(account: str) -> int:
    out = subprocess.check_output(["cast", "call", IMDSTR, "balanceOf(address)(uint256)", account, "--rpc-url", RPC], text=True,
                                  env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    return int(out.split()[0])


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--snapshot", default=os.path.join(here, "..", "snapshots", "rh-community-2026-10-09.json"))
    ap.add_argument("--out", default=os.path.join(here, "..", "claims.json"))
    a = ap.parse_args()
    snap = json.load(open(a.snapshot))
    rows = []
    for account, amt in sorted(snap["balances"].items()):
        cap = int(Decimal(str(amt)) * Decimal(10) ** 18)
        now = balance(account)
        amount = min(cap, now)
        if amount > 0: rows.append((account.lower(), amount))
    leaves = [leaf(acc, amt) for acc, amt in rows]
    layers = tree(leaves)
    root = "0x" + layers[-1][0].hex()
    total = sum(amt for _, amt in rows)
    for (acc, amt), l in zip(rows, leaves):  # every proof checks before anything is written
        h = l
        for p in proof(layers, leaves.index(l)): h = pair(h, p)
        assert h == layers[-1][0], acc
    out = {"root": root, "total": str(total), "snapshot": os.path.basename(a.snapshot), "holders": len(rows),
           "claims": {acc: {"amount": str(amt), "proof": ["0x" + p.hex() for p in proof(layers, i)]} for i, (acc, amt) in enumerate(rows)}}
    json.dump(out, open(a.out, "w"), indent=1)
    print(f"{len(rows)} holders, {total / 1e24:.4f}M IMDSTR to claim; root {root}")
    print(f"setClaims({root}, {total}, <deadline: at least 90 days after the launch>)")
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
