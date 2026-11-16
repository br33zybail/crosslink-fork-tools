#!/usr/bin/env bash
# tip-track.sh — live dual-reference alignment tracker for a Crosslink node.
# Certify, every few minutes, that the node is on the SAME chain as two outside
# references, and page the moment it is not.
#
# Reference A: a block API with
#   GET $REF_A_API/tip        -> {"tip": <height>}
#   GET $REF_A_API/block/<h>  -> {"block": {"hash": "<hex>"}}
# Reference B: a fork-monitor JSON document with
#   {"cipherscan": {"tip": <height>, "tip_hash": "<hex>"},
#    "anchors": [{"height": <h>, "cipherscan_hash": "<hex>"}, ...]}
#
# WHY TWO REFERENCES: one reference degraded (tip frozen thousands of blocks
# behind, block API flapping between real data and "not found"). The first,
# single-reference version failed OPEN in that state: with a readable tip but
# no block data, every depth comparison was skipped and it still logged "OK
# aligned" with zero comparisons behind it. So: track BOTH, show each source's
# lag, and fail CLOSED. Zero successful hash comparisons across both sources is
# BLIND, never "aligned".
#
# WHY THIS EXISTS AT ALL: the node's fork choice under sparse or competing tips
# had no code fix at the time; it WILL drift again. The realistic defense is to
# catch a fork at depth 3, not depth 1250, and recover fast.
#
# SAFETY:
#   * READ-ONLY toward the node. Touches no chain state, restarts nothing.
#   * Compares real block HASHES, never tip numbers alone.
#   * Fail closed: unreadable local RPC, or ZERO successful comparisons across
#     both references, counts toward a BLIND page, never "aligned".
#   * Everything parsed from a reference or from the node is validated before
#     use: heights must be plain integers, hashes exactly 64 hex digits. Anything
#     else counts as "no data", never as evidence, and never reaches a shell
#     expansion, an RPC request body, a state file or an alert.
#   * Certifies the deepest corroborated agreement into $STATE_DIR/agreed-checkpoint
#     (a recovery pin: height=/hash=/certified_utc= first).
#   * Incident file keys (split_height=/ours_hash=/last_common_height=) are a
#     CONTRACT for any heal step that reads them: split_height is written only
#     when a real bisect found it. See docs/fork-heal.md. Read them with grep;
#     never source the file.
#
# Run from cron every 3 minutes. All settings come from the environment; see
# config.example.env.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC="${RPC_URL:-http://127.0.0.1:PORT}"
REFA="${REF_A_API:-https://reference-a.invalid/api}"
REFB="${REF_B_URL:-https://reference-b.invalid/fork-monitor}"
UA="${USER_AGENT:-crosslink-fork-tools}"
STATE_DIR="${STATE_DIR:-$HERE/../state}"
STATE="$STATE_DIR/tip-track"
CKPT="$STATE_DIR/agreed-checkpoint"
INCIDENT="$STATE_DIR/divergence.incident"
read -r -a DEPTHS <<< "${REF_A_DEPTHS:-5 20 100 500 2000}"   # tip-minus offsets for the reference A depth scan
SAFE_DEPTH="${SAFE_DEPTH:-500}"                  # a certified checkpoint must be at least this deep
MAX_BLACKOUT="${MAX_BLACKOUT:-4}"                # consecutive zero-evidence runs before paging
BLIND_REPAGE="${BLIND_REPAGE:-120}"              # runs between repeat BLIND pages while still blind
LAG_WARN="${LAG_WARN:-150}"                      # a reference this many blocks behind can't vouch for our tip
TIP_STRIKES="${REF_B_TIP_STRIKES:-2}"            # consecutive B tip-probe mismatches before a churn warning
TIP_ESCALATE="${REF_B_TIP_ESCALATE:-6}"          # B tip-probe streak that counts as divergence even with green anchors
MIN_PEERS="${MIN_PEERS:-2}"                      # fewer connected peers than this = peer-isolated warning

# no leading zeros: bash arithmetic would read "08" as invalid octal and abort the run
is_uint(){ [[ "$1" =~ ^(0|[1-9][0-9]{0,11})$ ]]; }
is_hash(){ [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# Numeric settings feed arithmetic; refuse to run on anything but positive integers.
for v in SAFE_DEPTH MAX_BLACKOUT BLIND_REPAGE LAG_WARN TIP_STRIKES TIP_ESCALATE MIN_PEERS; do
  [[ "${!v}" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "tip-track: $v must be a positive integer, got '${!v}'" >&2; exit 2; }
done
[ "${#DEPTHS[@]}" -gt 0 ] || { echo "tip-track: REF_A_DEPTHS is empty" >&2; exit 2; }
for d in "${DEPTHS[@]}"; do
  [[ "$d" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "tip-track: REF_A_DEPTHS entry '$d' is not a positive integer" >&2; exit 2; }
done
mkdir -p "$STATE_DIR"

ts(){ date -u '+%Y-%m-%dT%H:%M:%SZ'; }
# read a counter file written by this script; anything but digits reads as 0
counter(){ local v; v=$(tr -dc 0-9 < "$1" 2>/dev/null | head -c 9); echo "$(( 10#${v:-0} ))"; }

# push TITLE PRIORITY MESSAGE  (priority: default|high|urgent)
# ALERT_CMD is split on whitespace (no globbing, no eval) so it can carry arguments.
push(){
  if [ -n "${ALERT_CMD:-}" ]; then
    local -a cmd; read -r -a cmd <<< "$ALERT_CMD"
    [ "${#cmd[@]}" -gt 0 ] && { "${cmd[@]}" "$1" "$2" "$3" >/dev/null 2>&1 || true; }
  elif [ -n "${ALERT_WEBHOOK:-}" ]; then
    curl -s -m10 -H "Title: $1" -H "Priority: $2" --data-raw "$3" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi
  return 0
}
rpc(){ curl -s -m8 --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"t\",\"method\":\"$1\",\"params\":${2:-[]}}" -H 'content-type: text/plain;' "$RPC"; }
jget(){ python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
print($1)" 2>/dev/null; }
# Both hash readers print a lowercase 64-hex hash or nothing.
our_hash(){
  is_uint "$1" || return 0
  local h; h=$(rpc getblockhash "[$1]" | jget '(d.get("result") or "")'); h="${h,,}"
  is_hash "$h" && printf '%s' "$h"; return 0
}
refa_hash(){
  is_uint "$1" || return 0
  local h; h=$(curl -s -m10 -A "$UA" "$REFA/block/$1" | jget 'd.get("block",{}).get("hash","")'); h="${h,,}"
  is_hash "$h" && printf '%s' "$h"; return 0
}

BLK="$STATE.blackout"
blind_tick(){  # $1 = reason (built only from validated values)
  local n; n=$(( $(counter "$BLK") + 1 )); echo "$n" > "$BLK"
  echo "$(ts) BLIND: $1 (blackout $n/$MAX_BLACKOUT)"
  # page on entering the blackout, then once per BLIND_REPAGE runs. Paging every
  # run burned a push service's whole daily cap by mid-morning during long blackouts.
  if [ "$n" -eq "$MAX_BLACKOUT" ] || { [ "$n" -gt "$MAX_BLACKOUT" ] && [ $(( (n - MAX_BLACKOUT) % BLIND_REPAGE )) -eq 0 ]; }; then
    push "Crosslink: alignment BLIND" "high" \
      "No reference evidence for $n runs: $1. Alignment UNKNOWN — check the node and both references. Repages every $BLIND_REPAGE runs while blind."
  fi
  exit 0
}

# ── 0. our own tip (nothing works without it) ─────────────────────────────────
info=$(rpc getblockchaininfo)
ours_h=$(jget '(d.get("result") or {}).get("blocks",0)' <<< "$info")
ours_top=$(jget '(d.get("result") or {}).get("bestblockhash","")' <<< "$info"); ours_top="${ours_top,,}"
is_hash "$ours_top" || ours_top="?"
if ! is_uint "${ours_h:-}" || [ "$ours_h" -eq 0 ]; then
  blind_tick "our RPC unreadable"
fi

# fail closed: peer isolation makes "the network" unknowable
peers=$(rpc getpeerinfo | jget 'len(d.get("result") or [])')
if ! is_uint "$peers"; then
  sleep "${PEER_RETRY_SLEEP:-5}"   # transient RPC failure is not the same as isolation — retry once
  peers=$(rpc getpeerinfo | jget 'len(d.get("result") or [])')
fi
if ! is_uint "$peers"; then
  peers="?"
  echo "$(ts) WARN peer-count unreadable (rpc failed twice)"
  push "Crosslink: peer-count unreadable" "high" "getpeerinfo failed twice — cannot verify peer connectivity this run."
elif [ "$peers" -lt "$MIN_PEERS" ]; then
  echo "$(ts) WARN peer-isolated: peers=$peers"
  push "Crosslink: peer-isolated" "high" "Only ${peers} peers connected — our view of the network may be wrong; alignment unreliable."
fi

# ── 1. reference A: tip + depth scan ──────────────────────────────────────────
refa_h=$(curl -s -m10 -A "$UA" "$REFA/tip" | jget 'd.get("tip",0)')
is_uint "$refa_h" && [ "$refa_h" -gt 0 ] || refa_h=""
refa_cmp=0; refa_last_agree=""; refa_first_bad=""; refa_cert_h=""; refa_cert_hash=""; refa_lag=""
if [ -n "$refa_h" ]; then
  refa_lag=$(( ours_h - refa_h ))
  base=$(( ours_h < refa_h ? ours_h : refa_h ))
  for d in "${DEPTHS[@]}"; do
    h=$(( base - d )); [ "$h" -lt 1 ] && continue
    o=$(our_hash "$h"); c=$(refa_hash "$h")
    [ -z "$c" ] && continue          # reference A has no data here: no evidence either way
    [ -z "$o" ] && continue
    refa_cmp=$(( refa_cmp + 1 ))
    if [ "$o" = "$c" ]; then
      refa_last_agree="$h"
      [ "$d" -ge "$SAFE_DEPTH" ] && { refa_cert_h="$h"; refa_cert_hash="$o"; }
    else
      [ -z "$refa_first_bad" ] && refa_first_bad="$h"
    fi
  done
fi

# ── 2. reference B: fork-monitor — live tip probe + deep anchors ──────────────
fm="$STATE.fm.json"
# A failed fetch drops the previous copy too: parsing yesterday's anchors as if
# they were current would count stale agreement as evidence and hide BLIND.
if curl -s -m15 "$REFB" -o "$fm.tmp" 2>/dev/null; then mv "$fm.tmp" "$fm"; else rm -f "$fm.tmp" "$fm"; fi
refb_tip=""; refb_hash=""; refb_lag=""; refb_probe="skip"; refb_cmp=0
refb_anch_ok=0; refb_anch_bad=0; refb_bad_detail=""; refb_last_good_anchor=""; refb_first_bad_anchor=""
refb_cert_h=""; refb_cert_hash=""
refb_anchors=()
if [ -s "$fm" ]; then
  # First line: "<tip> <tip_hash>" (or blank); then one "<height> <hash>" per anchor.
  # Python filters on type and shape; bash re-checks every field below.
  mapfile -t refb_lines < <(python3 - "$fm" <<'PY' 2>/dev/null
import json, re, sys
HEX = re.compile(r"[0-9a-fA-F]{64}")
def height(v):
    return isinstance(v, int) and not isinstance(v, bool) and 0 < v < 10**12
def hexhash(v):
    return isinstance(v, str) and HEX.fullmatch(v) is not None
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit()
if not isinstance(d, dict):
    sys.exit()
cs = d.get("cipherscan")
cs = cs if isinstance(cs, dict) else {}
t, h = cs.get("tip"), cs.get("tip_hash")
print(f"{t} {h.lower()}" if height(t) and hexhash(h) else "")
anchors = d.get("anchors")
for a in anchors if isinstance(anchors, list) else []:
    if isinstance(a, dict) and height(a.get("height")) and hexhash(a.get("cipherscan_hash")):
        print(f"{a['height']} {a['cipherscan_hash'].lower()}")
PY
)
  if [ "${#refb_lines[@]}" -gt 0 ]; then
    read -r t th <<< "${refb_lines[0]}"
    if is_uint "${t:-}" && is_hash "${th:-}"; then refb_tip="$t"; refb_hash="$th"; fi
    refb_anchors=("${refb_lines[@]:1}")
  fi
fi

if [ -n "$refb_tip" ]; then
  refb_lag=$(( ours_h - refb_tip ))
  # live tip probe: only meaningful if we already have that block AND B is fresh
  # enough to vouch for our recent chain. A frozen or lagging B serves one stale
  # (often orphaned) tip forever; probing it builds an endless MISMATCH streak
  # that trips the escalation hatch with all anchors green (seen 2026-07-21: B
  # frozen on an orphan, DIVERGED x171 pages overnight while A agreed with us at
  # tip).
  if [ "$refb_lag" -gt "$LAG_WARN" ]; then
    refb_probe="stale"   # skip: no strike counted; strike counter resets below
  else
    o=$(our_hash "$refb_tip")
    if [ -n "$o" ]; then
      refb_cmp=$(( refb_cmp + 1 ))
      if [ "$o" = "$refb_hash" ]; then refb_probe="match"; else refb_probe="MISMATCH"; fi
    fi
  fi
fi
for line in "${refb_anchors[@]}"; do
  read -r ah ahash <<< "$line"
  is_uint "${ah:-}" && is_hash "${ahash:-}" || continue
  [ "$ah" -gt "$ours_h" ] && continue
  o=$(our_hash "$ah"); [ -z "$o" ] && continue
  refb_cmp=$(( refb_cmp + 1 ))
  if [ "$o" = "$ahash" ]; then
    refb_anch_ok=$(( refb_anch_ok + 1 ))
    refb_last_good_anchor="$ah"
    [ $(( ours_h - ah )) -ge "$SAFE_DEPTH" ] && { refb_cert_h="$ah"; refb_cert_hash="$o"; }
  else
    refb_anch_bad=$(( refb_anch_bad + 1 ))
    [ -z "$refb_first_bad_anchor" ] && { refb_first_bad_anchor="$ah"; refb_bad_detail="h$ah ours=${o:0:16} refB=${ahash:0:16}"; }
  fi
done

# ── 3. fail closed on zero evidence ───────────────────────────────────────────
total_cmp=$(( refa_cmp + refb_cmp ))
if [ "$total_cmp" -eq 0 ]; then
  blind_tick "0 hash comparisons possible (ref A tip='${refa_h:-?}' blocks-dataless; ref B tip='${refb_tip:-?}')"
fi
prev_blind=$(counter "$BLK")
[ "$prev_blind" -ge "$MAX_BLACKOUT" ] && push "Crosslink: alignment evidence RESUMED" "default" \
  "Reference hash comparisons are back after $prev_blind blind runs ($total_cmp this run)."
echo 0 > "$BLK"

# ── 4. per-source lag flags (page once on entering/leaving lag, not every run) ─
LAGF="$STATE.lagflags"   # one line: "<refA lagging 0|1> <refB lagging 0|1>"
prev_a=0; prev_b=0
pa=""; pb=""; [ -r "$LAGF" ] && read -r pa pb < "$LAGF"
[[ "${pa:-}" =~ ^[01]$ ]] && prev_a="$pa"
[[ "${pb:-}" =~ ^[01]$ ]] && prev_b="$pb"
refa_lagging=0; refb_lagging=0
[ -n "$refa_lag" ] && [ "$refa_lag" -gt "$LAG_WARN" ] && refa_lagging=1
[ -n "$refb_lag" ] && [ "$refb_lag" -gt "$LAG_WARN" ] && refb_lagging=1
if [ "$refa_lagging" -ne "$prev_a" ]; then
  if [ "$refa_lagging" -eq 1 ]; then
    push "Crosslink: reference A lagging" "default" "ref A tip $refa_h is $refa_lag blocks behind ours ($ours_h) — its tip verdicts can't vouch for our tip; deep checks still count."
  else
    push "Crosslink: reference A caught up" "default" "ref A tip ${refa_h:-?} within $LAG_WARN of ours ($ours_h)."
  fi
fi
if [ "$refb_lagging" -ne "$prev_b" ]; then
  if [ "$refb_lagging" -eq 1 ]; then
    push "Crosslink: reference B lagging" "default" "ref B tip $refb_tip is $refb_lag blocks behind ours ($ours_h)."
  else
    push "Crosslink: reference B caught up" "default" "ref B tip ${refb_tip:-?} within $LAG_WARN of ours ($ours_h)."
  fi
fi
echo "$refa_lagging $refb_lagging" > "$LAGF"

# ── 5. B tip-probe strike counter (orphan-churn guard) ────────────────────────
MISS="$STATE.refb-tip.miss"
if [ "$refb_probe" = "MISMATCH" ]; then
  strikes=$(( $(counter "$MISS") + 1 )); echo "$strikes" > "$MISS"
else
  strikes=0; echo 0 > "$MISS"
fi

# ── 6. verdict ────────────────────────────────────────────────────────────────
# human-readable per-source summary for every log line
refa_lag_tag=""; [ "$refa_lagging" -eq 1 ] && refa_lag_tag=" lagging"
refb_lag_tag=""; [ "$refb_lagging" -eq 1 ] && refb_lag_tag=" lagging"
if [ -n "$refa_h" ]; then
  refa_sum="refA[tip=$refa_h lag=${refa_lag}${refa_lag_tag} cmp=$refa_cmp]"
else
  refa_sum="refA[unreachable]"
fi
if [ -n "$refb_tip" ]; then
  refb_sum="refB[tip=$refb_tip lag=${refb_lag}${refb_lag_tag} probe=$refb_probe anchors=$refb_anch_ok/$((refb_anch_ok+refb_anch_bad))]"
else
  refb_sum="refB[unreachable]"
fi

diverged=0; why=""
[ -n "$refa_first_bad" ] && { diverged=1; why="ref A depth-scan mismatch at h$refa_first_bad"; }
[ "$refb_anch_bad" -gt 0 ] && { diverged=1; why="${why:+$why; }ref B anchor mismatch: $refb_bad_detail"; }
# Tip-probe strikes alone are NOT divergence unless a deep anchor corroborates:
# 2026-07-16 false positive — B served a same-height sibling during tip churn
# (probe MISMATCH x2, all anchors OK, lag 0) and the incident cascaded into a
# heal step disabling mining in config. A real fork mismatches anchors (tip-5,
# tip-20, ...) within minutes, so require that corroboration; page a warning and
# keep counting otherwise, escalating only if the streak persists implausibly.
if [ "$strikes" -ge "$TIP_STRIKES" ]; then
  if [ "$refb_anch_bad" -gt 0 ] || [ "$strikes" -ge "$TIP_ESCALATE" ]; then
    diverged=1; why="${why:+$why; }ref B tip-probe mismatch x$strikes (h$refb_tip ours-hash != refB-hash)"
  elif [ "$strikes" -eq "$TIP_STRIKES" ]; then
    push "Crosslink: tip-probe churn (not divergence)" "default" "ref B tip-probe mismatch x$strikes at h$refb_tip but all $refb_anch_ok anchors match — treating as tip churn, watching (incident only if an anchor breaks or streak reaches $TIP_ESCALATE)"
  fi
fi

# ── 7. ALIGNED path: certify the freshest corroborated checkpoint ─────────────
if [ "$diverged" -eq 0 ]; then
  cert_h=""; cert_hash=""; cert_src=""
  if [ -n "$refa_cert_h" ]; then cert_h="$refa_cert_h"; cert_hash="$refa_cert_hash"; cert_src="refA"; fi
  if [ -n "$refb_cert_h" ] && { [ -z "$cert_h" ] || [ "$refb_cert_h" -gt "$cert_h" ]; }; then
    cert_h="$refb_cert_h"; cert_hash="$refb_cert_hash"; cert_src="refB"
  fi
  if [ -n "$refa_cert_h" ] && [ "$refa_cert_h" = "$refb_cert_h" ]; then cert_src="refA+refB"; fi
  # monotonic pin: with reference A flapping, don't replace a higher corroborated
  # pin with a lower one (diverged-path bisect pins DO overwrite unconditionally)
  prev_pin=$(grep -m1 '^height=' "$CKPT" 2>/dev/null | cut -d= -f2)
  if [ -n "$cert_h" ] && is_uint "${prev_pin:-}" && [ "$cert_h" -lt "$prev_pin" ]; then
    cert_h=""; cert_hash=""; cert_src="kept-h$prev_pin"
  fi
  if [ -n "$cert_h" ]; then
    printf '%s\n' "height=$cert_h" "hash=$cert_hash" "certified_utc=$(ts)" \
      "sources=$cert_src" "ours_tip=$ours_h" "refa_tip=$refa_h" "refb_tip=$refb_tip" > "$CKPT"
  fi
  echo "$(ts) OK aligned: ours=$ours_h $refb_sum $refa_sum peers=$peers certified=[$cert_h ${cert_hash:0:16} $cert_src]"
  exit 0
fi

# ── 8. DIVERGED path ──────────────────────────────────────────────────────────
# reference A bisect (only possible where A serves data): exact split for a heal step
split=""; lo=""; o_split=""; c_split=""
if [ -n "$refa_first_bad" ]; then
  lo="$refa_last_agree"; hi="$refa_first_bad"
  if [ -z "$lo" ]; then lo=$(( (ours_h<refa_h?ours_h:refa_h) - ${DEPTHS[-1]} - 1 )); [ "$lo" -lt 1 ] && lo=1; fi
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    o=$(our_hash "$mid"); c=$(refa_hash "$mid")
    if [ -z "$c" ] || [ -z "$o" ]; then break; fi
    if [ "$o" = "$c" ]; then lo="$mid"; else hi="$mid"; fi
  done
  split="$hi"; o_split=$(our_hash "$split"); c_split=$(refa_hash "$split")
  # bisected last-common block = the recovery pin, even mid-divergence
  lo_hash=$(our_hash "$lo")
  if [ -n "$lo_hash" ] && [ "$lo_hash" = "$(refa_hash "$lo")" ]; then
    printf '%s\n' "height=$lo" "hash=$lo_hash" "certified_utc=$(ts)" "sources=bisect-last-common" \
      "ours_tip=$ours_h" "refa_tip=$refa_h" "refb_tip=$refb_tip" > "$CKPT"
  fi
fi
# fall back to the anchor bracket when reference A couldn't bisect
[ -z "$lo" ] && lo="${refb_last_good_anchor:-$refa_last_agree}"

{
  echo "detected_utc=$(ts)"
  [ -n "$lo" ]    && echo "last_common_height=$lo"
  [ -n "$split" ] && echo "split_height=$split"          # only when truly bisected (heal-step contract)
  [ -n "$o_split" ] && echo "ours_hash=$o_split"
  [ -n "$c_split" ] && echo "refa_hash=$c_split"
  echo "reason=$why"
  echo "ours_tip=$ours_h  ours_top=$ours_top"
  echo "refa_tip=$refa_h  refb_tip=$refb_tip"
  echo "peers=$peers"
} > "$INCIDENT"

echo "$(ts) DIVERGED: $why | ours=$ours_h $refb_sum $refa_sum ${split:+split=$split }${lo:+last_common=$lo}"
push "Crosslink: OFF canonical chain" "urgent" \
  "$why. ours_tip=$ours_h. ${split:+Split bisected at h$split (last common h$lo).} ${split:-No exact split yet — wait for a bisect before acting.} Recovery pin: see agreed-checkpoint; follow docs/fork-heal.md."
exit 0
