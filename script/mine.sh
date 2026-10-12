#!/usr/bin/env bash
# The coin's 0x6900… address, mined for the deployed launch: the launch creates the coin with CREATE2 from its own
# address, so the salt can only be mined once the swarm has deployed it.
#
#   LAUNCH=<the launch's address> script/mine.sh          # prints the salt and the address it gives
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
: "${LAUNCH:?set LAUNCH to the deployed IMD6900RobinhoodLaunch}"
H=$(cast call "$LAUNCH" 'tokenInitCodeHash()(bytes32)' --rpc-url "$RPC")
echo "init code hash $H"
cast create2 --starts-with "${PREFIX:-6900}" --deployer "$LAUNCH" --init-code-hash "$H"
