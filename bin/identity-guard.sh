#!/usr/bin/env bash
# identity-guard.sh — page if ANY signer process other than the node's systemd
# unit holds the finalizer's state cache open, or if any zebrad-family process
# runs outside the unit and an allowlist of known instances.
#
# Two processes sharing that cache means two live signers with the same
# finalizer key: equivocation and damage to the committee. In July 2026 an
# orphaned smoke-test zebrad of mine started with a copy of the production
# config, outlived its test, and double-signed as my finalizer for several
# days. It was the leading suspect for a finality stall and a fork
# in that window. Never again. Cron: */5.
#
# All settings come from the environment; see config.example.env.
set -uo pipefail
CACHE="${FINALIZER_CACHE_DIR:-/path/to/zebra/state-cache}"
NODE_UNIT="${NODE_UNIT:-crosslink-node.service}"
SYSTEMD_SCOPE="${SYSTEMD_SCOPE:---system}"            # --system or --user
SIGNER_EXE_GLOB="${SIGNER_EXE_GLOB:-zebrad*}"          # binaries that can sign
SIGNER_PGREP="${SIGNER_PGREP:-zebrad}"                 # pgrep -f pattern for the census
ALLOW_CWDS="${ALLOW_CWDS:-}"                           # colon-separated working dirs of known, own-identity instances
STATE="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../state}/.identity-guard-alerted"
if [ "$SYSTEMD_SCOPE" = "--user" ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
fi

# push TITLE PRIORITY MESSAGE. ALERT_CMD is split on whitespace (no globbing, no eval).
push(){
  if [ -n "${ALERT_CMD:-}" ]; then
    local -a cmd; read -r -a cmd <<< "$ALERT_CMD"
    [ "${#cmd[@]}" -gt 0 ] && { "${cmd[@]}" "$1" "$2" "$3" >/dev/null 2>&1 || true; }
  elif [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -s -m 10 -H "Title: $1" -H "Priority: $2" --data-raw "$3" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi
  return 0
}

# A guard pointed at a path that does not exist, or missing the tools it looks
# with, checks nothing. Refuse to run.
[ -d "$CACHE" ] || { echo "identity-guard: FINALIZER_CACHE_DIR not found: $CACHE" >&2; exit 2; }
for c in fuser pgrep readlink ps systemctl; do
  command -v "$c" >/dev/null 2>&1 || { echo "identity-guard: required command not found: $c" >&2; exit 2; }
done
mkdir -p "$(dirname "$STATE")"

main_pid=$(systemctl "$SYSTEMD_SCOPE" show "$NODE_UNIT" -p MainPID --value 2>/dev/null)
offenders=""
for pid in $(fuser "$CACHE" "$CACHE"/* 2>/dev/null | tr ' ' '\n' | sort -u); do
  [ -n "$pid" ] || continue
  [ "$pid" = "$main_pid" ] && continue
  # Only zebrad-family binaries can SIGN; a cp/rsync/indexer reading the cache
  # is not a signer. Without this filter a */30 state-backup cp overlapped the
  # guard tick and paged URGENT twice an hour for a day.
  # shellcheck disable=SC2254
  case "$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)")" in $SIGNER_EXE_GLOB) ;; *) continue;; esac
  # children of the unit (e.g. a wrapper process) share its cgroup — allow those
  cg=$(cat "/proc/$pid/cgroup" 2>/dev/null)
  case "$cg" in *"$NODE_UNIT"*) continue;; esac
  offenders="$offenders $pid:$(ps -p "$pid" -o comm= 2>/dev/null)"
done

# Census: the cache check misses a clone whose config merely COPIES the
# production network_identity_seed_string (the finalizer key derives from it)
# while using its own state — which is what the July 2026 orphan actually did
# for its first 2.4 days of BFT catch-up before faulting. So: any zebrad-family
# process outside the systemd unit and the known-instance allowlist pages too.
for pid in $(pgrep -f "$SIGNER_PGREP" 2>/dev/null); do
  [ "$pid" = "$main_pid" ] && continue
  # only real zebrad binaries — shells/editors merely mentioning the word don't count
  # shellcheck disable=SC2254
  case "$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)")" in $SIGNER_EXE_GLOB) ;; *) continue;; esac
  case "$(cat "/proc/$pid/cgroup" 2>/dev/null)" in *"$NODE_UNIT"*) continue;; esac
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
  allowed=0
  IFS=':' read -r -a allow <<< "$ALLOW_CWDS"
  for a in "${allow[@]}"; do
    [ -n "$a" ] && [ "$cwd" = "$a" ] && allowed=1
  done
  [ "$allowed" -eq 1 ] && continue   # known, own-identity instances
  offenders="$offenders $pid:census:$(ps -p "$pid" -o comm= 2>/dev/null):${cwd:-unknown-cwd}"
done

if [ -n "$offenders" ]; then
  if [ ! -f "$STATE" ]; then
    touch "$STATE"
    push "FINALIZER IDENTITY DUPLICATED" "urgent" \
      "Process(es) other than $NODE_UNIT hold the finalizer cache open or run outside it:$offenders — a second signer with the same finalizer key. Stop it NOW (kill <pid>)."
  fi
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') OFFENDERS:$offenders"
else
  rm -f "$STATE"
fi
