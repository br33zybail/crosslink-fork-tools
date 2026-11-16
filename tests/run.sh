#!/usr/bin/env bash
# tests/run.sh — exercise every script against fake commands and canned data.
# No network, no node, no real systemd: tests/stubs/ shadows curl, systemctl,
# journalctl, fuser, pgrep, ps, readlink and cat, and every script runs under
# `env -i` with only the variables set here.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$REPO/tests/stubs"
WORKROOT="$REPO/tests/.work"
TPATH="$STUBS:/usr/bin:/bin"
pass=0; fail=0

# Refuse to run unless every command that could reach a real system resolves to a stub.
for c in curl systemctl journalctl fuser pgrep ps readlink cat; do
  got="$(PATH="$TPATH" command -v "$c")"
  if [ "$got" != "$STUBS/$c" ]; then echo "ABORT: $c resolves to '$got', not the stub"; exit 1; fi
done

rm -rf "$WORKROOT"; mkdir -p "$WORKROOT"
trap 'rm -rf "$WORKROOT"' EXIT

ok(){ pass=$((pass+1)); echo "  ok   $1"; }
no(){ fail=$((fail+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ # check NAME COMMAND...
  local name="$1"; shift
  if "$@"; then ok "$name"; else no "$name" "${OUT:-}"; fi
}
has(){ grep -q -- "$2" <<< "$1"; }
lines(){ if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

new_case(){ # new_case NAME -> sets W (work dir) and resets alert log
  W="$WORKROOT/$1"; mkdir -p "$W/state"; ALERTS="$W/alerts.log"; : > "$ALERTS"
}
# run SCRIPT [ARGS...] with a clean environment; extra VAR=value pairs come from $EXTRA (array)
run(){
  local script="$1"; shift
  OUT="$(cd "$W" && env -i PATH="$TPATH" HOME="$W" \
    RPC_URL="http://127.0.0.1:PORT" \
    REF_A_API="https://reference-a.invalid/api" \
    REF_B_URL="https://reference-b.invalid/fork-monitor" \
    STATE_DIR="$W/state" ALERT_CMD="$STUBS/record-alert" ALERT_LOG="$ALERTS" \
    PEER_RETRY_SLEEP=0 FAKE_PROC="$W/proc" \
    "${EXTRA[@]}" bash "$REPO/bin/$script" "$@" 2>&1)"
  RC=$?
}

echo "tip-track.sh"
# ---------------------------------------------------------------------------
new_case aligned
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000)
run tip-track.sh
check "aligned: logs OK aligned" has "$OUT" "OK aligned: ours=10000"
check "aligned: 5 ref A comparisons" has "$OUT" "refA\[tip=10000 lag=0 cmp=5\]"
check "aligned: 5/5 ref B anchors and tip match" has "$OUT" "probe=match anchors=5/5"
check "aligned: checkpoint pinned at deepest corroborated anchor" grep -qx 'height=8500' "$W/state/agreed-checkpoint"
check "aligned: no alerts" [ "$(lines "$ALERTS")" = 0 ]
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000)    # ref B gone: ref A alone would certify 8000
run tip-track.sh
check "monotonic pin: lower certification does not replace 8500" grep -qx 'height=8500' "$W/state/agreed-checkpoint"
check "monotonic pin: log says kept-h8500" has "$OUT" "kept-h8500"

new_case diverged
EXTRA=(FAKE_OUR_TIP=10000 FAKE_OUR_FORK_AT=9990 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000)
run tip-track.sh
check "diverged: logs DIVERGED" has "$OUT" "DIVERGED: ref A depth-scan mismatch at h9995"
check "diverged: ref B anchor mismatch also reported" has "$OUT" "ref B anchor mismatch: h9995"
check "diverged: bisect found split_height=9990" grep -qx 'split_height=9990' "$W/state/divergence.incident"
check "diverged: last_common_height=9989" grep -qx 'last_common_height=9989' "$W/state/divergence.incident"
check "diverged: ours_hash is our forked block" grep -q '^ours_hash=e' "$W/state/divergence.incident"
check "diverged: recovery pin moved to last common block" grep -qx 'height=9989' "$W/state/agreed-checkpoint"
check "diverged: one urgent alert" bash -c "[ \$(grep -c '^urgent|Crosslink: OFF canonical chain|' '$ALERTS') = 1 ]"

new_case blind
EXTRA=(FAKE_OUR_TIP=10000 MAX_BLACKOUT=4)
for i in 1 2 3; do run tip-track.sh; done
check "blind: three dark runs log BLIND 3/4" has "$OUT" "BLIND: 0 hash comparisons possible.*(blackout 3/4)"
check "blind: no page before MAX_BLACKOUT" [ "$(lines "$ALERTS")" = 0 ]
run tip-track.sh
check "blind: page on reaching MAX_BLACKOUT" grep -q '^high|Crosslink: alignment BLIND|' "$ALERTS"
run tip-track.sh
check "blind: no repeat page on the next run" [ "$(lines "$ALERTS")" = 1 ]
EXTRA=(FAKE_OUR_TIP=10000 MAX_BLACKOUT=4 FAKE_REFA_TIP=10000)
run tip-track.sh
check "blind: evidence back -> RESUMED page" grep -q '|Crosslink: alignment evidence RESUMED|' "$ALERTS"
check "blind: blackout counter reset" grep -qx 0 "$W/state/tip-track.blackout"

new_case staleB    # a failed reference B fetch must not leave the last good copy in play
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFA_MODE=dataless FAKE_REFB_TIP=10000)
run tip-track.sh
check "stale B: first run aligned on fresh B data" has "$OUT" "OK aligned"
EXTRA=(FAKE_OUR_TIP=10300 FAKE_OUR_FORK_AT=10100 FAKE_REFA_TIP=10300 FAKE_REFA_MODE=dataless)
run tip-track.sh
check "stale B: B gone + A dataless -> BLIND, not aligned on old anchors" has "$OUT" "BLIND: 0 hash comparisons possible"

new_case rpcdown
EXTRA=(FAKE_OUR_TIP=0 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000)
run tip-track.sh
check "rpc down: counts as BLIND, never aligned" has "$OUT" "BLIND: our RPC unreadable"

new_case isolated
EXTRA=(FAKE_OUR_TIP=10000 FAKE_PEERS=1 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000)
run tip-track.sh
check "peers=1: WARN peer-isolated" has "$OUT" "WARN peer-isolated: peers=1"
check "peers=1: high alert" grep -q '^high|Crosslink: peer-isolated|' "$ALERTS"
EXTRA=(FAKE_OUR_TIP=10000 FAKE_PEERS=down FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000)
run tip-track.sh
check "getpeerinfo failing twice: peer-count unreadable" has "$OUT" "WARN peer-count unreadable"

new_case frozenB   # regression for 2026-07-21: frozen reference B holding an orphan tip
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=9800 FAKE_REFB_TIP_ORPHAN=1)
run tip-track.sh
check "frozen B: probe skipped as stale" has "$OUT" "probe=stale"
check "frozen B: still OK aligned" has "$OUT" "OK aligned"
check "frozen B: lag alert once" [ "$(grep -c 'reference B lagging' "$ALERTS")" = 1 ]
run tip-track.sh
check "frozen B: no repeat lag alert" [ "$(grep -c 'reference B lagging' "$ALERTS")" = 1 ]

new_case churn     # regression for 2026-07-16: same-height sibling at B's tip, anchors green
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000 FAKE_REFB_TIP_ORPHAN=1)
run tip-track.sh
check "churn x1: aligned, no alert" bash -c "grep -q 'OK aligned' <<< '$OUT' && [ \$(wc -l < '$ALERTS') = 0 ]"
run tip-track.sh
check "churn x2: churn warning, not divergence" grep -q '^default|Crosslink: tip-probe churn (not divergence)|' "$ALERTS"
check "churn x2: no incident file" [ ! -f "$W/state/divergence.incident" ]
for i in 3 4 5 6; do run tip-track.sh; done
check "churn x6: escalates to DIVERGED" has "$OUT" "DIVERGED: ref B tip-probe mismatch x6"
check "churn x6: incident has no split_height (nothing bisected)" bash -c "! grep -q '^split_height=' '$W/state/divergence.incident'"

new_case injection # reference B is remote input; its tip_hash must never reach eval as code
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000 "FAKE_REFB_TIP_HASH=00;touch $WORKROOT/injection/PWNED")
run tip-track.sh
check "hostile tip_hash: no command executed" [ ! -e "$W/PWNED" ]
check "hostile tip_hash: tip ignored, anchors still checked" has "$OUT" "OK aligned"

new_case hostileanchor # anchor hashes are remote input: a newline must not smuggle in a fake anchor
cat > "$W/refb.json" <<JSON
{"cipherscan": {"tip": 10000, "tip_hash": "$(printf '%064x' 10000)"},
 "anchors": [
  {"height": 9995, "cipherscan_hash": "$(printf '%064x' 9995)\n1],\"method\":\"stop\",\"params\":[ x"},
  {"height": 9980, "cipherscan_hash": "$(printf '%064x' 9980)\na[\$(touch $WORKROOT/hostileanchor/PWNED)] y"},
  {"height": "9900", "cipherscan_hash": "$(printf '%064x' 9900)"},
  {"height": 9500, "cipherscan_hash": "$(printf '%064x' 9500)"}
 ]}
JSON
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_BODY_FILE="$W/refb.json" FAKE_CURL_LOG="$W/curl.log")
run tip-track.sh
check "hostile anchors: no command executed" [ ! -e "$W/PWNED" ]
check "hostile anchors: nothing but a plain height reaches the node RPC" bash -c "! grep -q 'stop' '$W/curl.log'"
check "hostile anchors: only the well-formed anchor counts" has "$OUT" "probe=match anchors=1/1"

new_case hostilerefa  # reference A is remote input too: its hash and tip must be validated
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000 "FAKE_REFA_BLOCK_HASH=$(printf '%064x' 1)
split_height=1")
run tip-track.sh
check "hostile ref A hash: no evidence, not a mismatch" has "$OUT" "OK aligned: .*refA\[tip=10000 lag=0 cmp=0\]"
# no reference B, so this run goes BLIND and its log line names ref A's tip
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 'FAKE_REFA_TIP_RAW="9999\n2026-01-01T00:00:00Z OK aligned: forged"')
run tip-track.sh
check "hostile ref A tip: treated as unreachable" has "$OUT" "BLIND: 0 hash comparisons possible (ref A tip='?'"
check "hostile ref A tip: no forged log line" bash -c "! grep -q forged <<< \"\$1\"" _ "$OUT"
# a tip sent as the string "08" is all digits but invalid octal in bash arithmetic: it must not kill the run
EXTRA=(FAKE_OUR_TIP=10000 FAKE_REFA_TIP=10000 'FAKE_REFA_TIP_RAW="08"')
run tip-track.sh
check "leading-zero ref A tip: run still reports, no silent crash" has "$OUT" "BLIND: 0 hash comparisons possible"
EXTRA=(FAKE_OUR_TIP=10000 BLIND_REPAGE=0)
run tip-track.sh
check "bad numeric setting: exit 2 before any check" [ "$RC" = 2 ]

new_case webhook
EXTRA=(FAKE_OUR_TIP=10000 FAKE_PEERS=1 FAKE_REFA_TIP=10000 FAKE_REFB_TIP=10000
       ALERT_CMD= ALERT_WEBHOOK=https://alerts.invalid/hook FAKE_WEBHOOK_LOG="$WORKROOT/webhook/hook.log")
run tip-track.sh
check "webhook: POST carries Title and Priority headers" grep -q '"Title: Crosslink: peer-isolated", "Priority: high"' "$W/hook.log"
check "webhook: message sent verbatim as the body" grep -q '"body": "Only 1 peers connected' "$W/hook.log"

echo "fork-report.sh / version-uptime.sh"
new_case vertag    # the version tag names state files; it must not escape STATE_DIR
echo "../../escaped" > "$W/version"
EXTRA=(VERSION_FILE="$W/version" FAKE_UNIT_ACTIVE=1)
run version-uptime.sh
check "version tag: path characters stripped" test -f "$W/state/version-uptime.....escaped"
check "version tag: nothing written outside STATE_DIR" [ ! -e "$WORKROOT/escaped" ]

# ---------------------------------------------------------------------------
new_case report
echo "v0.0.0-test" > "$W/version"
printf '[mining]\ninternal_miner = true\n' > "$W/zebrad.toml"
EXTRA=(VERSION_FILE="$W/version" ZEBRAD_TOML="$W/zebrad.toml" FAKE_OUR_TIP=10000 FAKE_UNIT_ACTIVE=1)
run version-uptime.sh
check "uptime: counter created and advanced one tick" grep -qx 300 "$W/state/version-uptime.v0.0.0-test"
check "uptime: start stamp written" test -s "$W/state/version-start.v0.0.0-test"
EXTRA=(VERSION_FILE="$W/version" FAKE_UNIT_ACTIVE=0)
run version-uptime.sh
check "uptime: inactive unit adds nothing" grep -qx 300 "$W/state/version-uptime.v0.0.0-test"
echo 90061 > "$W/state/version-uptime.v0.0.0-test"
EXTRA=(VERSION_FILE="$W/version" ZEBRAD_TOML="$W/zebrad.toml" FAKE_OUR_TIP=10000)
run fork-report.sh
check "report: no-fork template is 3 lines" [ "$(wc -l <<< "$OUT")" = 3 ]
check "report: version and unaltered-build line" has "$OUT" "v0.0.0-test, unaltered build from the release tag"
check "report: uptime 1d 1h 1m" has "$OUT" "running on this version.*: 1d 1h 1m"
check "report: fork count 0" has "$OUT" "forked while running on this version so far: 0$"
run fork-report.sh mark '9990; rm -rf /'
check "mark: rejects a non-numeric height" [ "$RC" = 2 ]
run fork-report.sh mark 9990
check "mark: records fork #1" has "$OUT" "recorded fork #1 at h9990"
echo "v0.0.0-test plus one local patch (test)" > "$W/state/version-patches.v0.0.0-test"
run fork-report.sh
check "report after mark: 8 lines" [ "$(wc -l <<< "$OUT")" = 8 ]
check "report: patches file is declared" has "$OUT" "v0.0.0-test, v0.0.0-test plus one local patch"
check "report: PoW tip from getblockchaininfo" has "$OUT" "PoW tip: 10000 0\{60\}2710$"
check "report: finalized hash byte order reversed to display order" has "$OUT" "finalized PoW height: 9995 0\{60\}270b$"
check "report: PoS height" has "$OUT" "latest PoS height: 77 round 0"
check "report: divergence point from the mark log" has "$OUT" "divergence point, if possible: h9990$"
check "report: mining read from config" has "$OUT" "Whether it was mining: on"

echo "identity-guard.sh"
# ---------------------------------------------------------------------------
mkproc(){ # mkproc PID EXE CGROUP [CWD]
  mkdir -p "$W/proc/$1"; echo "$2" > "$W/proc/$1/exe"; echo "$3" > "$W/proc/$1/cgroup"
  echo "${4:-/}" > "$W/proc/$1/cwd"
}
new_case guard
mkdir -p "$W/cache"
UNIT_CG="0::/system.slice/crosslink-node.service"
mkproc 100 /opt/node/zebrad "$UNIT_CG"
mkproc 200 /usr/bin/cp "0::/user.slice"
mkproc 300 /opt/smoke/zebrad "0::/user.slice/session-1.scope" /srv/smoke
mkproc 400 /opt/node/zebrad-wrapped "$UNIT_CG"
mkproc 500 /opt/rig/zebrad "0::/user.slice" /srv/own-identity-rig
G=(FINALIZER_CACHE_DIR="$W/cache" NODE_UNIT=crosslink-node.service FAKE_MAIN_PID=100)
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100" FAKE_PGREP_PIDS="100")
run identity-guard.sh
check "guard: only the unit's process -> silent" bash -c "[ -z '$OUT' ] && [ \$(wc -l < '$ALERTS') = 0 ]"
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100 200" FAKE_PGREP_PIDS="100")
run identity-guard.sh
check "guard: a cp reading the cache is not a signer" [ -z "$OUT" ]
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100 400" FAKE_PGREP_PIDS="100 400")
run identity-guard.sh
check "guard: zebrad child inside the unit's cgroup is allowed" [ -z "$OUT" ]
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100 300" FAKE_PGREP_PIDS="100 300")
run identity-guard.sh
check "guard: orphan zebrad on the cache is an offender" has "$OUT" "OFFENDERS: 300:zebrad 300:census:zebrad:/srv/smoke"
check "guard: one urgent page" grep -q '^urgent|FINALIZER IDENTITY DUPLICATED|' "$ALERTS"
run identity-guard.sh
check "guard: no repeat page while it persists" [ "$(lines "$ALERTS")" = 1 ]
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100" FAKE_PGREP_PIDS="100")
run identity-guard.sh
check "guard: clean run re-arms the page" [ ! -f "$W/state/.identity-guard-alerted" ]
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100" FAKE_PGREP_PIDS="100 500" ALLOW_CWDS="/srv/other:/srv/own-identity-rig")
run identity-guard.sh
check "guard: census skips allowlisted working dir" [ -z "$OUT" ]
EXTRA=("${G[@]}" FAKE_FUSER_PIDS="100" FAKE_PGREP_PIDS="100 500")
run identity-guard.sh
check "guard: census flags a zebrad clone outside unit and allowlist" has "$OUT" "500:census:zebrad:/srv/own-identity-rig"
EXTRA=(FINALIZER_CACHE_DIR="$W/no-such-dir")
run identity-guard.sh
check "guard: missing cache dir -> exit 2, not a silent pass" [ "$RC" = 2 ]

echo "node-watch.sh"
# ---------------------------------------------------------------------------
new_case watch
J="$W/journal"
line(){ echo "Nov 01 00:00:00 host zebrad[1]: INFO tip height: Height(1000), finalized height: Height(990), peers: $1"; }
N=(FAKE_JOURNAL="$J" FAKE_KERNEL_LOG="$W/kern" FAKE_UNIT_ACTIVE=1)
: > "$W/kern"
line '["ab12@990/1002", "cd34@988/1001"]' > "$J"
EXTRA=("${N[@]}" FAKE_OUR_TIP=1000)
run node-watch.sh
check "watch: healthy state OK" grep -q 'tip=1000 peers_tip=1002 won_1h=0 state=OK' "$W/state/node-watch.log"
check "watch: first OK run sends 'recovered' (state change from empty)" grep -q '^default|Crosslink node: recovered|' "$ALERTS"
run node-watch.sh
check "watch: no page while state is unchanged" [ "$(lines "$ALERTS")" = 1 ]
line '[]' >> "$J"
run node-watch.sh
check "watch: empty peer list -> no-peers, urgent" grep -q '^urgent|Crosslink node: PROBLEM: no-peers|' "$ALERTS"
line '["ab12@990/1102"]' > "$J"
run node-watch.sh
check "watch: 102 behind the best peer -> behind-peers" grep -q 'PROBLEM: behind-peers(102)' "$ALERTS"
EXTRA=("${N[@]}" FAKE_OUR_TIP=0 FAKE_UNIT_ACTIVE=0)
run node-watch.sh
check "watch: unit down and RPC silent" grep -q 'PROBLEM: unit-inactive rpc-down' "$ALERTS"
line '["ab12@990/1002"]' > "$J"
for i in $(seq 1 51); do echo "Nov 01 00:00:01 host zebrad[1]: WARN failed to get genesis block" >> "$J"; done
echo "Nov 01 00:00:02 host kernel: zebra-miner[9]: segfault at 0 ip 0 sp 0 error 4" > "$W/kern"
EXTRA=("${N[@]}" FAKE_OUR_TIP=1000)
run node-watch.sh
check "watch: segfault and genesis storm" grep -q 'PROBLEM: miner-segfault wallet-genesis-storm(51)' "$ALERTS"

new_case watch2
J="$W/journal"; N=(FAKE_JOURNAL="$J" FAKE_KERNEL_LOG="$W/kern" FAKE_UNIT_ACTIVE=1); : > "$W/kern"
line '["ab12@990/1050"]' > "$J"
EXTRA=("${N[@]}" FAKE_OUR_TIP=1000)
run node-watch.sh
line '["ab12@990/1060"]' > "$J"
run node-watch.sh
check "watch: behind count changing is one page, not two" [ "$(grep -c 'PROBLEM: behind-peers' "$ALERTS")" = 1 ]
echo "Nov 01 00:00:00 host zebrad[1]: INFO something else" > "$J"
run node-watch.sh; run node-watch.sh
check "watch: two runs without a peer line stay quiet" [ "$(grep -c 'no-peer-line' "$ALERTS")" = 0 ]
run node-watch.sh
check "watch: third run without a peer line pages (fail closed)" grep -q 'PROBLEM: no-peer-line(3)' "$ALERTS"
EXTRA=("${N[@]}" FAKE_OUR_TIP=1000 NOLINE_RUNS=0)
run node-watch.sh
check "watch: bad numeric setting -> exit 2" [ "$RC" = 2 ]

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
