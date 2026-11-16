#!/usr/bin/env bash
# version-uptime.sh — accumulate "total time online on THIS software version".
#
# Why: the Crosslink team's fork-rate study (2026-07-31) needs total time online
# per version, NOT time since last boot, so a per-node-per-day fork rate can be
# computed. systemd's ActiveEnterTimestamp resets on every restart and cannot be
# reconstructed after the fact, so the counting has to start when the version does.
#
# Cron: every TICK seconds (default */5). Adds one tick's worth of seconds whenever
# the node unit is active. Reset happens implicitly: a new VERSION_FILE value means
# new counter files. fork-report.sh reads what this writes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$HERE/../state}"
VERSION_FILE="${VERSION_FILE:-/path/to/installed-version}"
NODE_UNIT="${NODE_UNIT:-crosslink-node.service}"
SYSTEMD_SCOPE="${SYSTEMD_SCOPE:---system}"   # --system or --user
TICK="${TICK:-300}"
[[ "$TICK" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "version-uptime: TICK must be a positive integer, got '$TICK'" >&2; exit 2; }
if [ "$SYSTEMD_SCOPE" = "--user" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi
# The tag names state files, so keep only characters that are safe in a file name.
ver="$(head -c 100 "$VERSION_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._+-')"
ver="${ver:-unknown}"
stamp="$STATE_DIR/version-start.$ver"
count="$STATE_DIR/version-uptime.$ver"
mkdir -p "$STATE_DIR"

[ -f "$stamp" ] || date -u +%FT%TZ > "$stamp"
[ -f "$count" ] || echo 0 > "$count"

systemctl "$SYSTEMD_SCOPE" is-active --quiet "$NODE_UNIT" || exit 0
now=$(tr -dc 0-9 < "$count" | head -c 12); now=${now:-0}
echo $(( 10#$now + TICK )) > "$count"
