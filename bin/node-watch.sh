#!/bin/bash
# node-watch.sh — basic health watcher for a Crosslink node, including the
# no-peers check. Every 5 min: unit active, RPC answers, tip within BEHIND_LIMIT
# of the best peer, node has peers at all, no new miner segfault, no wallet
# genesis-retry storm, peer line missing for several runs. Pages once per
# condition change (state file), not every tick.
#
# Peer data comes from the node's own periodic log line, which looks like
#   tip height: Height(1000), finalized height: Height(990), peers: ["ab12@990/1002", ...]
# so this reads the unit's journal, not an RPC.
#
# All settings come from the environment; see config.example.env.
NODE_UNIT="${NODE_UNIT:-crosslink-node.service}"
SYSTEMD_SCOPE="${SYSTEMD_SCOPE:---system}"   # --system or --user
RPC="${RPC_URL:-http://127.0.0.1:PORT}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$HERE/../state}"
S="$STATE_DIR/node-watch.state"; LOG="${NODE_WATCH_LOG:-$STATE_DIR/node-watch.log}"
BEHIND_LIMIT="${BEHIND_LIMIT:-20}"           # blocks behind the best peer before paging
JOURNAL_LINES="${JOURNAL_LINES:-300}"        # how far back to look for the latest peer line
GENESIS_STORM="${GENESIS_STORM:-50}"         # "failed to get genesis block" lines in 5 min that count as a storm
NOLINE_RUNS="${NOLINE_RUNS:-3}"              # consecutive runs with no peer line before paging
if [ "$SYSTEMD_SCOPE" = "--user" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi
JSCOPE=""; [ "$SYSTEMD_SCOPE" = "--user" ] && JSCOPE="--user"
for v in BEHIND_LIMIT JOURNAL_LINES GENESIS_STORM NOLINE_RUNS; do
  [[ "${!v}" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "node-watch: $v must be a positive integer, got '${!v}'" >&2; exit 2; }
done
mkdir -p "$STATE_DIR"

# page TITLE MESSAGE [PRIORITY]. ALERT_CMD is split on whitespace (no globbing, no eval).
page(){
  if [ -n "${ALERT_CMD:-}" ]; then
    local -a cmd; read -r -a cmd <<< "$ALERT_CMD"
    [ "${#cmd[@]}" -gt 0 ] && { "${cmd[@]}" "Crosslink node: $1" "${3:-high}" "$2" >/dev/null 2>&1 || true; }
  elif [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -s -m 10 -H "Title: Crosslink node: $1" -H "Priority: ${3:-high}" --data-raw "$2" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi
  return 0
}
# journal reader for the node unit; extra args are passed through
# shellcheck disable=SC2086
jnode(){ journalctl $JSCOPE -u "$NODE_UNIT" --no-pager "$@" 2>/dev/null; }

now=$(date -u +%FT%TZ); bad=""
systemctl "$SYSTEMD_SCOPE" is-active --quiet "$NODE_UNIT" || bad="$bad unit-inactive"
tip=$(curl -s -m 8 -X POST "$RPC" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null)
[[ "$tip" =~ ^(0|[1-9][0-9]{0,11})$ ]] || tip=""   # no leading zeros: "08" is invalid octal in arithmetic
[ -z "$tip" ] && bad="$bad rpc-down"
# Peer data: the latest periodic peer line. If none shows up for NOLINE_RUNS runs
# in a row, the journal is unreadable or the format changed, and the peer checks
# below would pass on nothing, so that pages too (fail closed). Single misses
# around restarts are normal, hence the streak.
peerline=$(jnode -n "$JOURNAL_LINES" | grep 'tip height' | tail -1)
NL="$STATE_DIR/node-watch.noline"
if [ -n "$peerline" ]; then
  echo 0 > "$NL"
  ptip=$(grep -oE '@[0-9]+/[0-9]+' <<< "$peerline" | awk -F'[@/]' '{if($3>m)m=$3} END{print m+0}')
  [ -n "$tip" ] && [ "$ptip" -gt 0 ] && [ "$tip" -lt $((ptip-BEHIND_LIMIT)) ] && bad="$bad behind-peers($((ptip-tip)))"
  # 2026-10-15: a 7 h WAN outage left the node with zero peers, mining a private fork; ptip was 0 so nothing paged.
  grep -q 'peers: \[\]' <<< "$peerline" && bad="$bad no-peers"
else
  ptip=0
  nl=$(tr -dc 0-9 < "$NL" 2>/dev/null | head -c 9); nl=$(( 10#${nl:-0} + 1 )); echo "$nl" > "$NL"
  [ "$nl" -ge "$NOLINE_RUNS" ] && bad="$bad no-peer-line($nl)"
fi
seg=$(journalctl -k --since '10 minutes ago' --no-pager 2>/dev/null | grep -c 'zebra-miner.*segfault'); [ "$seg" != 0 ] && bad="$bad miner-segfault"
gen=$(jnode --since '5 minutes ago' | grep -o 'failed to get genesis block' | wc -l); [ "$gen" -gt "$GENESIS_STORM" ] && bad="$bad wallet-genesis-storm($gen)"
won=$(jnode --since '1 hour ago' | grep -c 'successfully mined')
state="${bad:-OK}"
# Compare conditions without their counts, so "behind-peers(31)" then
# "behind-peers(33)" is one page, not one page per run.
key=$(sed 's/([0-9]*)//g' <<< "$state"); prev=$(cat "$S" 2>/dev/null)
echo "$now tip=$tip peers_tip=$ptip won_1h=$won state=$state" >> "$LOG"
if [ "$key" != "$prev" ]; then echo "$key" > "$S"; if [ "$state" = OK ]; then page "recovered" "node healthy again: tip $tip, $won blocks in the last hour" default; else page "PROBLEM:$bad" "tip=$tip peers_tip=$ptip won_1h=$won. journalctl $JSCOPE -u $NODE_UNIT" urgent; fi; fi
exit 0
