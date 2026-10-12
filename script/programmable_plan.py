#!/usr/bin/env python3
"""The Programmable launch plan (programmable.custom-launch-plan.v1, open provenance) for the swarm-deployed launch.

    python3 script/programmable_plan.py --launch <addr> --salt <0x…> --token <0x6900…> --params params.json [--out plan.json]

What it declares: the launch, the locked pool and the hook as existing components (the IMD swarm deployed them), the
coin as a CREATE2 deployment from the launch (the launch IS the coin's factory: launch() creates it with the mined
salt, opens the pool with all of it, buys first with the ETH sent), the ETH / IMD6900 market with its hook, and the
team wallet as the controller that sends launch(). Every component is bound to the exact source: this compiles the
standard JSON input forge would verify with, fills each contract's immutables from the chain and refuses to write a plan
unless the result is the deployed runtime byte for byte (so a launch the swarm adapted can't slip through).
Then: node <request-packer.mjs> --input plan.json --out request.canonical.json --report pack-report.json
"""
import argparse, base64, hashlib, json, os, subprocess, time
from Crypto.Hash import keccak

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
RPC = os.environ.get("ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com")
MANIFEST = "sha256:3cd25308629f932d6a75e4a7694e6bcb67e4471fd2c1782d3b11ba5a7e3f8b61"
COMPILER = "0.8.26+commit.8a97fa7a"
TEAM = "0x35dA9C0303507ddf708E87F2568EdDf12c47a059"
PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
IMDSTR = "0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F"
TIMELOCK = "0x16D3f65B708883DF042d98E1C7a49B32A33E2A14"
POOL_FEE, TICK_SPACING = 0x800000, 60  # a dynamic fee: the hook sets it per swap
# beforeInitialize, beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, afterSwap (manifest hookPermissionBits)
PERMISSIONS = (1 << 13) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6)
CALLBACKS = ("beforeInitialize", "beforeAddLiquidity", "beforeRemoveLiquidity", "beforeSwap", "afterSwap")

# each contract's immutables in declaration order (their AST ids ascend the same way), as Programmable rebuilds them:
# an address that is another component's (target), or a literal of its ABI type
IMMUTABLES = {
    "IMD6900RobinhoodLaunch": [("poolManager", "address"), ("pool", "@pool"), ("hook", "@hook"), ("hookSalt", "bytes32"),
                               ("imdstr", "address"), ("timelock", "address")],
    "IMD6900LockedPool": [("poolManager", "address"), ("poolFee", "uint24"), ("launcher", "@launch")],
    "IMD6900Hook": [("poolManager", "address"), ("pool", "@pool"), ("launcher", "@launch")],
    "IMD6900": [],
}


def kk(b: bytes) -> str:
    return "0x" + keccak.new(digest_bits=256, data=b).hexdigest()


def sh(*a, cwd=ROOT) -> str:
    return subprocess.check_output(list(a), text=True, cwd=cwd, env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}).strip()


def code(addr: str) -> bytes:
    return bytes.fromhex(sh("cast", "code", addr, "--rpc-url", RPC)[2:])


def call(addr: str, sig: str, *args) -> str:
    return sh("cast", "call", addr, sig, *args, "--rpc-url", RPC).split()[0]


SOLC = os.environ.get("SOLC", os.path.expanduser("~/Library/Application Support/svm/0.8.26/solc-0.8.26"))


def compile_unit(sji):
    """compiles the standard JSON input exactly as Programmable's server does: the bytecode and the immutables' AST ids
    come from this compile of these sources, not from forge's (whose ids count the tests too)"""
    out = json.loads(subprocess.run([SOLC, "--standard-json"], input=json.dumps(sji), capture_output=True, text=True, check=True).stdout)
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors: raise SystemExit("solc: " + errors[0].get("formattedMessage", str(errors[0])))
    if not sh(SOLC, "--version").splitlines()[-1].startswith("Version: " + COMPILER): raise SystemExit(f"{SOLC} isn't {COMPILER}")
    return out


def artifact(out, name):
    c = out["contracts"][f"src/{name}.sol"][name]
    return bytes.fromhex(c["evm"]["bytecode"]["object"]), bytes.fromhex(c["evm"]["deployedBytecode"]["object"]), \
        c["evm"]["deployedBytecode"].get("immutableReferences", {}), c["abi"]


def materialize(name, deployed_compiled, refs, onchain, ids):
    """fills the compiled runtime's immutables with the values on chain; returns (runtime, references, immutables)"""
    order = sorted(refs, key=int)
    if len(order) != len(IMMUTABLES[name]): raise SystemExit(f"{name}: {len(order)} immutables compiled, {len(IMMUTABLES[name])} expected")
    rt = bytearray(deployed_compiled)
    references, immutables = [], []
    for ast_id, (var, kind) in zip(order, IMMUTABLES[name]):
        ranges = refs[ast_id]
        word = onchain[ranges[0]["start"]:ranges[0]["start"] + 32]
        for r in ranges:
            if onchain[r["start"]:r["start"] + 32] != word: raise SystemExit(f"{name}.{var}: its copies differ on chain")
            rt[r["start"]:r["start"] + 32] = word
        references.append({"immutableId": ast_id, "ranges": [{"start": r["start"], "length": 32} for r in ranges]})
        if kind.startswith("@"):
            addr = "0x" + word[12:].hex()
            if addr.lower() != ids[kind[1:]].lower(): raise SystemExit(f"{name}.{var} is {addr}, not the {kind[1:]} component")
            immutables.append({"immutableId": ast_id, "abiType": "address", "target": kind[1:]})
        elif kind == "address":
            immutables.append({"immutableId": ast_id, "abiType": "address", "literal": sh("cast", "to-check-sum-address", "0x" + word[12:].hex())})
        elif kind == "bytes32":
            immutables.append({"immutableId": ast_id, "abiType": "bytes32", "literal": "0x" + word.hex()})
        else:
            immutables.append({"immutableId": ast_id, "abiType": kind, "literal": str(int.from_bytes(word, "big"))})
    return bytes(rt), references, immutables


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launch", required=True)
    ap.add_argument("--salt", required=True)
    ap.add_argument("--token", required=True, help="the 0x6900… address the salt gives")
    ap.add_argument("--params", required=True, help="script/params.py's output")
    ap.add_argument("--excess-to", default="0x0000000000000000000000000000000000000000", help="zero burns the excess")
    ap.add_argument("--deadline-hours", type=float, default=23, help="a plan lives at most 24 hours (Programmable's window)")
    ap.add_argument("--out", default=os.path.join(ROOT, "plan.json"))
    a = ap.parse_args()
    p = json.load(open(a.params))
    L = sh("cast", "to-check-sum-address", a.launch)
    pool = sh("cast", "to-check-sum-address", call(L, "pool()(address)"))
    hook = sh("cast", "to-check-sum-address", call(L, "hook()(address)"))
    token = sh("cast", "to-check-sum-address", a.token)
    if call(L, "tokenAddress(bytes32)(address)", a.salt).lower() != token.lower(): raise SystemExit("the salt doesn't give that address")
    if call(L, "owner()(address)").lower() != TEAM.lower(): raise SystemExit("the launch isn't the team wallet's")
    if call(L, "token()(address)") != "0x0000000000000000000000000000000000000000": raise SystemExit("already launched")
    ids = {"launch": L, "pool": pool, "hook": hook, "imd6900": token}
    if int(hook, 16) & 0x3FFF != PERMISSIONS: raise SystemExit("the hook's address doesn't carry its permissions")

    # the exact source: forge's standard JSON input, with Programmable's output selection
    sji = json.loads(sh("forge", "verify-contract", L, "src/IMD6900RobinhoodLaunch.sol:IMD6900RobinhoodLaunch",
                        "--show-standard-json-input", "--chain", "4663"))
    sji["settings"]["outputSelection"] = {"*": {"*": ["abi", "evm.bytecode", "evm.deployedBytecode"]}}
    raw = json.dumps(sji, separators=(",", ":"), sort_keys=True).encode()
    out = compile_unit(sji)
    unit = {"compilationUnitId": "main", "compilerVersion": COMPILER, "standardJsonInputBase64": base64.b64encode(raw).decode(),
            "standardJsonInputSha256": "sha256:" + hashlib.sha256(raw).hexdigest()}

    enc = lambda sig, *xs: sh("cast", "abi-encode", sig, *xs)
    ctor = {
        "launch": enc("f(address,address,address,address)", TEAM, PM, IMDSTR, TIMELOCK),
        "pool": enc("f(address,uint24,address)", PM, str(POOL_FEE), L),
        "hook": enc("f(address,address,address)", PM, pool, TIMELOCK),
        "imd6900": enc("f(address)", L),
    }
    names = {"launch": "IMD6900RobinhoodLaunch", "pool": "IMD6900LockedPool", "hook": "IMD6900Hook", "imd6900": "IMD6900"}
    artifacts, components, effects, hook_abi = [], [], [], []
    token_init = None
    for cid, name in names.items():
        creation, deployed, refs, abi = artifact(out, name)
        if cid == "imd6900":
            runtime, references, immutables = deployed, [], []
            token_init = creation + bytes.fromhex(ctor[cid][2:])
        else:
            onchain = code(ids[cid])
            runtime, references, immutables = materialize(name, deployed, refs, onchain, ids)
            if runtime != onchain: raise SystemExit(f"{name} at {ids[cid]} is not this source: the deployed runtime differs")
        h = kk(runtime)
        artifacts.append({"targetId": f"{cid}-artifact", "compilationUnitId": "main", "sourcePath": f"src/{name}.sol",
                          "contractName": name, "constructorArguments": ctor[cid],
                          "runtimeMaterialization": {"immutableReferences": references, "runtimeImmutables": immutables,
                                                     "deployedRuntimeCodeBase64": base64.b64encode(runtime).decode(),
                                                     "deployedRuntimeCodeHash": h}})
        components.append({"componentId": cid, "artifactId": f"{cid}-artifact", "expectedAddress": ids[cid], "runtimeCodeHash": h,
                           "tags": {"launch": ["launcher", "fee-distributor", "claims"], "pool": ["liquidity", "locked"],
                                    "hook": ["hook", "perps"], "imd6900": ["token"]}[cid]})
        effects.append({"effectId": f"{cid}-runtime", "criticality": "critical", "kind": "runtime", "target": {"componentId": cid}, "runtimeCodeHash": h})
        if cid == "hook": hook_abi = [x for x in abi if x.get("type") == "function" and x["name"] in CALLBACKS]
    if kk(token_init) != call(L, "tokenInitCodeHash()(bytes32)"): raise SystemExit("the coin's init code differs from the launch's")

    data = sh("cast", "calldata", "launch(bytes32,address,uint160,uint256,address)", a.salt, token, p["sqrtPriceX96"], p["minBought"], a.excess_to)
    exist = lambda cid: {"actionId": f"use-{cid}", "kind": "useExisting", "componentId": cid, "dependsOn": [],
                         "authority": {"kind": "controller"}, "preconditions": [], "postconditions": [f"{cid}-runtime"]}
    actions = [exist("launch"), exist("pool"), exist("hook"), {
        "actionId": "launch-imd6900", "kind": "deployCreate2", "componentId": "imd6900", "factory": {"componentId": "launch"},
        "salt": "0x" + a.salt[2:].lower().rjust(64, "0"), "initCode": "0x" + token_init.hex(),
        "dependsOn": ["use-launch", "use-pool", "use-hook"], "authority": {"kind": "controller"}, "preconditions": [],
        "postconditions": ["imd6900-runtime", "launched"],
        "execution": {"target": {"componentId": "launch"}, "data": data, "value": p["buyWei"], "gasLimit": "4000000"}}]
    effects.append({"effectId": "launched", "criticality": "critical", "kind": "callResult", "target": {"componentId": "launch"},
                    "data": sh("cast", "sig", "token()"), "expected": enc("f(address)", token)})
    plan = {
        "schemaVersion": "programmable.custom-launch-plan.v1", "manifestDigest": MANIFEST, "chainId": "4663",
        "controller": {"kind": "eoa", "address": TEAM}, "executor": "controller_multi_step_v1",
        "verificationBundle": {"schemaVersion": "programmable.exact-source-verification-bundle.v2", "compilationUnits": [unit],
                               "components": sorted(artifacts, key=lambda x: x["targetId"].encode())},  # the packer wants them in UTF-8 order
        "components": components, "actions": actions,
        "markets": [{"marketId": "imd6900-eth", "kind": "uniswap_v4", "poolManager": PM, "currency0": {"address": "0x0000000000000000000000000000000000000000"},
                     "currency1": {"componentId": "imd6900"}, "fee": POOL_FEE, "tickSpacing": TICK_SPACING, "hooks": {"componentId": "hook"}}],
        "hookBindings": [{"componentId": "hook", "poolManager": PM, "permissions": PERMISSIONS, "callbackAbi": hook_abi}],
        "dependencies": [{"dependencyId": "pool-manager", "chainId": "4663", "address": PM, "runtimeCodeHash": kk(code(PM))}],
        "expectedEffects": effects,
        # a plan lives at most 24 hours from validAfter
        "budgets": {"maxTotalValue": p["buyWei"], "maxTotalGas": "4000000", "validAfter": str(int(time.time()) - 60),
                    "deadline": str(int(time.time()) - 60 + int(min(a.deadline_hours, 23.5) * 3600))},
        "feeObligations": [], "claimDescriptors": [],
        "distributionPreferences": [{"provider": "hooklist", "optedIn": True}, {"provider": "uniswap_api", "optedIn": True},
                                    {"provider": "uniswap_labs", "optedIn": True}],
        "admissionPolicy": "programmable.custom-launch-policy.provenance.v1",
        "publication": {"visibility": "listed", "name": "Identity.MD 6900", "symbol": "IMD6900",
                        "description": "Identity.MD 6900 on Robinhood Chain: the identity.md machine strategy, the meme branch of the IMD swarm. "
                                       "Launched by the IMD swarm: the whole supply in a locked Uniswap v4 pool with in-pool perps to come, "
                                       "its fee 6.9% gliding to 4.44% over the first week, then 3.33%: 70% to Ethereum's NFT pot, 10% to $IMD's burn.",
                        "imageUrl": "https://imd6900.pages.dev/logo.png", "primaryComponentId": "imd6900", "primaryMarketId": "imd6900-eth",
                        "links": ["https://x.com/IMD6900", "https://imd6900.pages.dev"]},
    }
    json.dump(plan, open(a.out, "w"), indent=1)
    print(f"plan for {token} ({len(components)} components, every runtime matched on chain) -> {a.out}")


if __name__ == "__main__":
    main()
