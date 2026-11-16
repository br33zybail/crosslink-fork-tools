# crosslink-fork-tools

Shell scripts I wrote to notice when my Zcash Crosslink testnet node leaves the
canonical chain, to catch a second process signing with my finalizer key, and to
fill in the fork reports the Crosslink team asked operators for.

Crosslink is Shielded Labs' design for adding a finality layer (a BFT committee
of finalizers) on top of Zcash proof of work. It runs as a public testnet, and
I ran a miner and finalizer on it through 2026.

This is one operator's tooling for a testnet. Most scripts grew out of a
specific failure on my node. I tested them only as described under "Testing" below. They
come with no warranty (see LICENSE).

## What each tool checks

| Script | Checks | Why |
|---|---|---|
| `bin/tip-track.sh` | Compares the node's block hashes with two outside references at several depths. Writes a recovery checkpoint while aligned, and an incident file with the exact split height when not. Also warns when the node has fewer than two peers. | A fork that nobody sees grows until it needs a restore. |
| `bin/node-watch.sh` | systemd unit up, RPC answers, tip within 20 blocks of the best peer, at least one peer, the peer log line still present, no miner segfault, no wallet genesis-retry storm. | The no-peers check came from an outage where the node had zero peers and nothing paged. |
| `bin/identity-guard.sh` | Pages if a zebrad process other than the node's unit holds the finalizer's state cache open, or runs anywhere outside the unit and an allowlist. | Two processes with one finalizer key is equivocation. |
| `bin/fork-report.sh` | Prints the team's fork-report template from node data: version, total uptime on that version, confirmed fork count, and on a fork the tip, finalized height, PoS height and split point. `mark <h>` records a confirmed fork. | The team needed a fork rate per node per day, so nodes that never fork must report too. |
| `bin/version-uptime.sh` | Adds a tick of uptime to a per-version counter whenever the node unit is active. | systemd resets its uptime on every restart; the report needs total time on the version. |
| `docs/fork-heal.md` | A runbook for getting back onto the canonical chain. | My heal scripts act on one machine, so I wrote the steps down instead of publishing them. |

## The incidents behind them

**A self-fork nobody saw for 18 hours (July 2026).** My miner won a block two
seconds before the network accepted a different block at the same height. The
node never reorged and mined about 2,268 blocks alone over roughly 18 hours.
Every watcher said OK. One compared hashes at a pinned checkpoint about 15,000
blocks below the fork. The other read a reference that had been frozen since
3 July. The lesson: check the live tip, against a reference that is moving
right now. That is the core of `tip-track.sh`.

**A reference that went quiet, and a check that passed on nothing (July 2026).**
When one reference froze and its block API began to answer "not found", the first
version of the tracker skipped every comparison and still logged "OK aligned".
The rewrite counts comparisons. Zero comparisons across both references is
BLIND, and four BLIND runs in a row page.

**An explorer that cannot be a fork oracle (July 2026).** One public block
explorer kept serving orphan blocks after reorgs and never rewrote them. Its own
index failed its prev-hash links, and its mismatches with my node were scattered
rather than a suffix, which a real fork cannot produce. It falsely tripped my
miner watchdog and cost about 2.5 hours of mining. Later it served a same-height
sibling during tip churn, and on another night it froze holding an orphan as its
tip, which made my tracker page DIVERGED all night. So in `tip-track.sh`, a
mismatch at reference B's tip counts only when a deeper anchor also mismatches,
or the streak runs to six; and the tip probe is skipped while that reference
lags more than 150 blocks. I treat any one explorer's hashes as advice, not proof.

**A test process that double-signed for several days (July 2026).** During a smoke
test I started a second zebrad with a copy of my production config. It outlived
the test and signed as my finalizer for several days in July 2026. Other operators saw the
faults on the network. It was the leading suspect for a finality stall and a
fork in that window, though one node's logs could not prove it. `identity-guard.sh` exists so this pages within five
minutes. Its first version paged falsely twice an hour for a day, because a
backup `cp` reading the cache looked like a second process. It now counts only
zebrad binaries. A new alert needs its own log read a few hours after install.

**A seven hour outage and a private chain (October 2026).** My internet link
dropped for seven hours. The node kept mining on its own and built a private
chain of more than 600 blocks, too deep to reorg back. The best-peer check could
not fire because with no peers the best peer tip was zero. `node-watch.sh` now
pages on an empty peer list. The recovery was a restore from backup and a short
sync, written up in `docs/fork-heal.md`.

## Setup

Needs bash, curl, python3, and for some scripts systemd, journalctl, fuser,
pgrep and ps. Linux only (`identity-guard.sh` reads `/proc`).

1. Copy `config.example.env` to `config.env` and fill it in. Every path, URL,
   unit name and threshold comes from there. Unset values fall back to
   placeholders that fail closed: BLIND, rpc-down, or exit code 2.
2. Pick alerts. `ALERT_CMD` is split on whitespace (no globbing, no eval) and
   run with three more arguments: `"<title>" "<priority>" "<message>"`, priority
   `default`, `high` or `urgent`. `ALERT_WEBHOOK` gets a POST with the message as
   the raw body and `Title` and `Priority` headers (the ntfy format). With
   neither set, scripts only log. Anything a script takes from a reference or
   the node reaches an alert only after it passes a digits-only or 64-hex check.
   Keep `STATE_DIR` private to the node's user (`mkdir -m 700`).
3. Run them from cron as the same user as the node (identity-guard needs to read
   the node's `/proc` entries):

```
*/3 * * * * set -a; . /path/to/config.env; set +a; /path/to/bin/tip-track.sh      >> /path/to/state/tip-track.log 2>&1
*/5 * * * * set -a; . /path/to/config.env; set +a; /path/to/bin/node-watch.sh
*/5 * * * * set -a; . /path/to/config.env; set +a; /path/to/bin/identity-guard.sh >> /path/to/state/identity-guard.log 2>&1
*/5 * * * * set -a; . /path/to/config.env; set +a; /path/to/bin/version-uptime.sh
```

4. When asked for a fork report, run `bin/fork-report.sh`. When a fork is
   confirmed by hand, run `bin/fork-report.sh mark <split_height>`. A tip-track
   incident alone is not a confirmed fork: incidents include tip races and false
   alarms from references.

### Reference formats

`tip-track.sh` reads two references:

- **A**, a block API: `GET $REF_A_API/tip` returns `{"tip": <height>}` and
  `GET $REF_A_API/block/<height>` returns `{"block": {"hash": "<hex>"}}`.
  Only this reference is used to bisect the split height.
- **B**, a fork-monitor document at `$REF_B_URL`:
  `{"cipherscan": {"tip": <height>, "tip_hash": "<hex>"}, "anchors": [{"height": <h>, "cipherscan_hash": "<hex>"}]}`.
  The key names are those of the explorer I used; adapt the two small Python
  blocks in the script if yours differ.

## Testing

`tests/run.sh` runs every script against stubs: a fake `curl` that serves a
synthetic chain and both references, and fake `systemctl`, `journalctl`,
`fuser`, `pgrep`, `ps`, `readlink` and `cat`. It refuses to start unless each of
those resolves to the stub, and it runs each script under `env -i`. No network,
no node, no real systemd. It covers 86 checks, among them: aligned, diverged
with bisect, BLIND and its repage rule, RPC down, peer isolation, the frozen
explorer and tip churn cases above, a reference B fetch that fails after a
good one, hostile reference data (a `tip_hash` carrying a shell command,
anchor hashes carrying newlines and JSON, a reference A hash and tip carrying
extra lines), bad numeric settings, the webhook path, the report template
before and after `mark`, a version tag carrying a path, each identity-guard
case, and each node-watch condition.

What I have not tested here: any script against a live node or live reference,
the real journal format beyond the one line shown in `node-watch.sh`, identity
guard against real `/proc`, and shellcheck (not run).

## Limits

- The JSON-RPC calls send no credentials. Keep the RPC on loopback.
- `node-watch.sh` depends on the node's periodic `tip height: ... peers: [...]`
  log line as printed by the zebra-crosslink builds I ran in late 2026. If that
  line stops appearing (format change, unreadable journal), it pages
  `no-peer-line` after `NOLINE_RUNS` runs. It pages on an empty peer list, not
  on a short one; `tip-track.sh` covers fewer than `MIN_PEERS`.
- `identity-guard.sh` checks open files at the top level of the cache directory,
  and it skips any process whose `/proc/<pid>/exe` it cannot read. Run it as the
  node's user or as root, or it can miss a signer owned by someone else.
- `node-watch.sh` sends a "recovered" alert on its first run, because the state
  goes from empty to OK.
- The references are only as good as their operators. Both of mine failed in the
  ways described above.

## Upstream

One of my pull requests to ShieldedLabs/crosslink_monolith has been merged
(#60), and one is open (#59).

## License

MIT. See LICENSE.
