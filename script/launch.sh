#!/usr/bin/env bash
# IMD6900 on Robinhood, step by step. The contracts don't depend on Programmable: once the launch contract is deployed
# the coin goes live either straight on Uniswap (`direct`, one transaction) or through Programmable (`programmable`,
# then `submit`: the same launch() after their review, with their stamp and listing). Decide at the last step.
#
#   script/launch.sh status        where everything stands
#   script/launch.sh fund          the Pons launcher's ETH (the old pool's 2.83) back to the team wallet
#   script/launch.sh deploy        the launch contract, from the team wallet (its constructor creates the pool and the hook)
#   script/launch.sh claims        the claim list (script/claims.py: live balances capped at the snapshot), deadline in 120 days
#   script/launch.sh queue-claims  queues the timelock's IMDSTR.setDistributor(<launch>, true): claims open 12h later
#   script/launch.sh open-claims   executes it once ready (anyone with the executor role; the team wallet has it)
#   script/launch.sh mine          the coin's 0x6900… address for this launch (PREFIX=69006900 for a longer one)
#   script/launch.sh direct        launch() now: the coin, the locked pool, the opening buy (BUY_ETH, default 2.81)
#   script/launch.sh programmable  the Programmable plan for the same launch(): built, packed and preflighted
#   script/launch.sh submit        creates it on Programmable (their manual review starts), then `review` polls it
#   script/launch.sh review        the plan's state on Programmable
#
# Signs with the imdstr-deployer keystore (the team wallet); SIGN_ARGS="--unlocked --from <team>" on a fork.
set -euo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${RPC:-${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}}"
if [ -n "${SIGN_ARGS:-}" ]; then read -r -a SIGN <<<"$SIGN_ARGS"; else SIGN=(--account imdstr-deployer); fi
TEAM=0x35dA9C0303507ddf708E87F2568EdDf12c47a059
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
IMDSTR=0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F
TL=0x16D3f65B708883DF042d98E1C7a49B32A33E2A14
PONS_LAUNCHER=0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0
API=https://api.programmable.market/v4/chains/4663
PACKER=${PACKER:-$PWD/.programmable/request-packer.mjs}  # Programmable's own packer, fetched for the manifest below
STATE=${STATE:-launch.state}  # LAUNCH, SALT, TOKEN, PLAN_ID as they come
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
CLAIMS_SALT=$(cast keccak "imd6900-rh-launch-claims-1")
BUY_ETH="${BUY_ETH:-2.81}"
[ -f "$STATE" ] && source "$STATE"
save() { echo "$1=$2" >>"$STATE"; export "$1=$2"; }
c() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
tx() { cast send "$@" "${SIGN[@]}" --rpc-url "$RPC" >/dev/null; }
e() { python3 -c "print(f'{$1/1e18:.4f}')"; }
m() { python3 -c "print(f'{$1/1e24:.2f}M')"; }
claims_data() { cast calldata 'setDistributor(address,bool)' "$LAUNCH" true; }
claims_op() { c $TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT"; }
need() { [ -n "${!1:-}" ] || { echo "no $1 yet: run '$2' first"; exit 1; }; }
key() { security find-generic-password -s PROGRAMMABLE_API_KEY -w; }

case "${1:-status}" in
  status)
    echo "team wallet: $(e $(cast balance $TEAM --rpc-url "$RPC")) ETH · Pons launcher: $(e $(cast balance $PONS_LAUNCHER --rpc-url "$RPC")) ETH"
    if [ -z "${LAUNCH:-}" ]; then echo "launch: not deployed (deploy)"; exit 0; fi
    echo "launch $LAUNCH · pool $(c $LAUNCH 'pool()(address)') · hook $(c $LAUNCH 'hook()(address)')"
    echo "claims: $(m $(c $LAUNCH 'claimTotal()(uint256)')) · distributor op: $(c $TL 'isOperationDone(bytes32)(bool)' $(claims_op)) done, $(c $TL 'isOperationPending(bytes32)(bool)' $(claims_op)) pending"
    echo "coin: ${TOKEN:-not mined} · launched: $(c $LAUNCH 'token()(address)')"
    [ -n "${PLAN_ID:-}" ] && echo "Programmable plan: $PLAN_ID (review)"
    ;;
  fund)
    tx $PONS_LAUNCHER 'withdrawEth(address,uint256)' $TEAM 0 && echo "the Pons launcher's ETH is the team wallet's: $(e $(cast balance $TEAM --rpc-url "$RPC")) ETH"
    ;;
  deploy)
    [ -z "${LAUNCH:-}" ] || { echo "already deployed: $LAUNCH"; exit 0; }
    forge build --silent
    INIT=$(python3 -c "import json;print(json.load(open('out/IMD6900RobinhoodLaunch.sol/IMD6900RobinhoodLaunch.json'))['bytecode']['object'])")
    ARGS=$(cast abi-encode "f(address,address,address,address)" $TEAM $PM $IMDSTR $TL)
    L=$(cast send "${SIGN[@]}" --rpc-url "$RPC" --json --create "${INIT}${ARGS:2}" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])")
    save LAUNCH "$(cast to-check-sum-address "$L")"
    echo "launch $LAUNCH · pool $(c $LAUNCH 'pool()(address)') · hook $(c $LAUNCH 'hook()(address)')"
    ;;
  claims)
    need LAUNCH deploy
    python3 script/claims.py --out claims.json
    ROOT=$(python3 -c "import json;print(json.load(open('claims.json'))['root'])"); TOTAL=$(python3 -c "import json;print(json.load(open('claims.json'))['total'])")
    NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
    tx $LAUNCH 'setClaims(bytes32,uint256,uint256)' $ROOT $TOTAL $((NOW + 120 * 86400)) && echo "claims set: $(m $TOTAL), until $(date -r $((NOW + 120 * 86400)))"
    ;;
  queue-claims)
    need LAUNCH deploy
    tx $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT" 43200
    echo "queued $(claims_op): ready in 12h (open-claims)"
    ;;
  open-claims)
    need LAUNCH deploy
    [ "$(c $TL 'isOperationReady(bytes32)(bool)' $(claims_op))" = true ] || { echo "not ready yet"; exit 1; }
    tx $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $IMDSTR 0 "$(claims_data)" $ZERO "$CLAIMS_SALT" && echo "claims are open"
    ;;
  mine)
    need LAUNCH deploy
    OUT=$(RPC="$RPC" ROBINHOOD_RPC_URL="$RPC" LAUNCH=$LAUNCH script/mine.sh)
    save SALT "$(echo "$OUT" | awk '/^Salt:/{print $2}')"; save TOKEN "$(echo "$OUT" | awk '/^Address:/{print $2}')"
    echo "the coin will be $TOKEN"
    ;;
  direct)
    need LAUNCH deploy; need TOKEN mine
    [ "$(c $LAUNCH 'claimTotal()(uint256)')" != 0 ] || { echo "no claim list: run claims first"; exit 1; }
    python3 script/params.py --buy "$BUY_ETH" > params.json
    SP=$(python3 -c "import json;print(json.load(open('params.json'))['sqrtPriceX96'])"); MIN=$(python3 -c "import json;print(json.load(open('params.json'))['minBought'])"); V=$(python3 -c "import json;print(json.load(open('params.json'))['buyWei'])")
    echo "launching $TOKEN: opens at $(python3 -c "import json;print(round(json.load(open('params.json'))['openMarketCapEth'],2))") ETH market cap, buys with $BUY_ETH ETH"
    tx $LAUNCH 'launch(bytes32,address,uint160,uint256,address)' $SALT $TOKEN $SP $MIN $LAUNCH --value $V --gas-limit 4000000
    echo "live: $(c $LAUNCH 'token()(address)') · bought $(m $(c $LAUNCH 'launchBought()(uint256)')) · kept for the timelock $(m $(c $LAUNCH 'excessHeld()(uint256)'))"
    ;;
  programmable)
    need LAUNCH deploy; need TOKEN mine
    if [ ! -f "$PACKER" ]; then mkdir -p "$(dirname "$PACKER")"; curl -sS -m 120 "$API/custom-launch-contract/request-packer.mjs" -o "$PACKER"; fi
    grep -q "sha256:3cd25308629f932d6a75e4a7694e6bcb67e4471fd2c1782d3b11ba5a7e3f8b61" "$PACKER" || { echo "the packer is for another manifest: refetch it and check the plan"; exit 1; }
    python3 script/params.py --buy "$BUY_ETH" > params.json
    ROBINHOOD_RPC_URL="$RPC" python3 script/programmable_plan.py --launch $LAUNCH --salt $SALT --token $TOKEN --params params.json --excess-to $LAUNCH --out plan.json
    rm -f request.canonical.json pack-report.json
    node "$PACKER" --input "$PWD/plan.json" --out "$PWD/request.canonical.json" --report "$PWD/pack-report.json"
    python3 -c "import json; r=json.load(open('pack-report.json')); print('packed:', r['status'], len(r['findings']), 'findings')"
    curl -sS -m 300 -X POST "$API/custom-launch-plans:preflight" -H "Authorization: Bearer $(key)" -H "Content-Type: application/json" \
      -H "Programmable-Launch-Response-Version: 1.2" --data-binary @request.canonical.json -o preflight.json
    python3 -c "
import json; d=json.load(open('preflight.json')); f=d.get('findings',[])
print('preflight:', len(f), 'findings'); [print(' -', x.get('code'), x.get('jsonPointer'), json.dumps(x.get('constraint'))[:160]) for x in f]"
    ;;
  submit)
    [ -f request.canonical.json ] || { echo "run programmable first"; exit 1; }
    IK=$(python3 -c "import json;print(json.load(open('pack-report.json'))['idempotencyKey'])")
    curl -sS -m 300 -X POST "$API/custom-launch-plans" -H "Authorization: Bearer $(key)" -H "Content-Type: application/json" \
      -H "Programmable-Launch-Response-Version: 1.2" -H "Idempotency-Key: $IK" --data-binary @request.canonical.json -o submitted.json -w "HTTP %{http_code}\n"
    python3 -c "
import json; d=json.load(open('submitted.json')); print(json.dumps({k: d.get(k) for k in ('planId','id','launchId','status','manualReview','walletUrl','resumeUrl')}, indent=1))"
    ID=$(python3 -c "import json;d=json.load(open('submitted.json'));print(d.get('planId') or d.get('launchId') or d.get('id') or '')")
    [ -n "$ID" ] && save PLAN_ID "$ID"
    ;;
  review)
    need PLAN_ID submit
    curl -sS -m 120 "$API/custom-launch-plans/$PLAN_ID" -H "Authorization: Bearer $(key)" -H "Programmable-Launch-Response-Version: 1.2" -o review.json
    python3 -c "
import json; d=json.load(open('review.json')); print(json.dumps({k: d.get(k) for k in ('status','manualReview','walletUrl','continuation')}, indent=1)[:2000])"
    ;;
  *) sed -n 2,19p "$0"; exit 1 ;;
esac
