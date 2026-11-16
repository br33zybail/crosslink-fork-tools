#!/usr/bin/env bash
# fork-report.sh — fill in the fork-report template the Crosslink team sent to
# testnet operators on 2026-07-31.
#
# They are hunting a needless-divergence bug and need a per-node-per-day fork RATE,
# so nodes that never fork must report too. Everything here is read from the node
# itself; the only human input is confirming that a divergence was real.
#
#   ./fork-report.sh              print the report (no-fork template while the count is 0)
#   ./fork-report.sh mark <h>     record a confirmed fork, diverging at height <h>
#
# Fork count is deliberately NOT derived from tip-track.sh incident files: those
# include tip races and reference-freeze false positives, and an overstated count
# poisons exactly the trend line they are trying to build. Only confirmed forks
# are marked.
#
# Uptime comes from version-uptime.sh, which must run from cron on the same
# STATE_DIR and VERSION_FILE. All settings come from the environment; see
# config.example.env.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$HERE/../state}"
RPC="${RPC_URL:-http://127.0.0.1:PORT}"
VERSION_FILE="${VERSION_FILE:-/path/to/installed-version}"   # one line: the release tag you run
ZEBRAD_TOML="${ZEBRAD_TOML:-/path/to/zebrad.toml}"
# The tag names state files, so keep only characters that are safe in a file name.
ver="$(head -c 100 "$VERSION_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._+-')"
ver="${ver:-unknown}"
stamp="$STATE_DIR/version-start.$ver"
count="$STATE_DIR/version-uptime.$ver"
forks="$STATE_DIR/version-forks.$ver"
log="$STATE_DIR/version-forks.$ver.log"

rpc() { curl -s -m 15 -X POST -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "$RPC"; }

if [ "${1:-}" = "mark" ]; then
    h="${2:-}"
    [[ "$h" =~ ^(0|[1-9][0-9]{0,11})$ ]] || { echo "usage: fork-report.sh mark <divergence_height>" >&2; exit 2; }
    mkdir -p "$STATE_DIR"
    n=$(( $(tr -dc 0-9 2>/dev/null < "$forks" || echo 0) + 1 ))
    echo "$n" > "$forks"
    echo "$(date -u +%FT%TZ) fork #$n on $ver, diverged at h$h" >> "$log"
    echo "recorded fork #$n at h$h"
    exit 0
fi

started="$(cat "$stamp" 2>/dev/null || echo unknown)"
secs=$(tr -dc 0-9 2>/dev/null < "$count" || echo 0); secs=${secs:-0}
nforks=$(tr -dc 0-9 2>/dev/null < "$forks" || echo 0); nforks=${nforks:-0}
d=$(( secs / 86400 )); hh=$(( (secs % 86400) / 3600 )); mm=$(( (secs % 3600) / 60 ))

tip=$(rpc getblockchaininfo | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r["blocks"],r["bestblockhash"])' 2>/dev/null)
fin=$(rpc get_tfl_final_block_height_and_hash | python3 -c '
import sys,json
r=json.load(sys.stdin)["result"]
print(r["height"], bytes(r["hash"])[::-1].hex())' 2>/dev/null)
pos=$(rpc get_tfl_recency_status | python3 -c 'import sys,json;r=json.load(sys.stdin)["result"];print(r["my_height"],"round",r["my_round"])' 2>/dev/null)
mining=off; grep -qE '^\s*internal_miner\s*=\s*true' "$ZEBRAD_TOML" 2>/dev/null && mining=on

# What we run has to be declared accurately or the study's disaggregation breaks:
# $STATE_DIR/version-patches.<ver> describes any divergence from the release tag.
patches="$STATE_DIR/version-patches.$ver"
desc="$(cat "$patches" 2>/dev/null || echo 'unaltered build from the release tag (no PRs, no local patches)')"
echo "Your software version release tag (as well as any code forks/PRs that you have applied to your build): $ver, $desc"
echo "Approximately how long the node has been online and running on this version (total time online, not time since last boot): ${d}d ${hh}h ${mm}m (counting from $started)"
echo "Approximately how many times the node has forked while running on this version so far: $nforks"
if [ "$nforks" -gt 0 ] 2>/dev/null; then
    echo "The forked node's PoW tip: ${tip:-unreadable}"
    echo "Its finalized PoW height: ${fin:-unreadable}"
    echo "Its latest PoS height: ${pos:-unreadable}"
    echo "Its PoW fork/divergence point, if possible: $(tail -1 "$log" 2>/dev/null | sed 's/.*diverged at //' || echo unknown)"
    echo "Whether it was mining: $mining"
fi
