# Fork heal runbook

This is how I got my Crosslink testnet node back onto the canonical chain after
it forked off, written as steps rather than scripts. My own heal scripts act on
one machine, with its paths, unit names and backups, and with workarounds for
quirks in the builds I ran in 2026. Run on someone else's node, they would do
harm. The steps below carry over; the scripts would not.

Nothing in this repo runs any of these steps. `tip-track.sh` only detects and
records. Every step here changes node state, so a person should run it, awake,
with the rollback written down first.

## 0. Before you need it

- Keep backups of the node's state directory at regular heights, and take one
  before every planned stop. Include the BFT data the node keeps beside the
  chain state. A restore from a backup that predates the fork is the only fix
  for a deep fork, and it is far faster than a sync from zero.
- Know your node's reorg limit. Zebra will not switch to a branch that forks
  more than 99 blocks below the blocks it has committed as final. In Crosslink
  that line follows BFT finality, not depth below the tip, so while finality is
  stalled a deeper branch can still switch on its own once finality resumes.
  I saw both: a 600 block private chain that could never rejoin, and a 135
  block branch that snapped back in one step when the committee resumed.
- Run `tip-track.sh` often (I used every 3 minutes). With blocks every 25
  seconds or so, 100 blocks is about 40 minutes. A fork found at depth 5 is a
  small problem; one found at depth 1,000 is a restore.

## 1. Confirm the fork is real

A page is a claim, not a fact.

- Check that `divergence.incident` has a `split_height=` line. tip-track writes
  it only when a bisect against reference A found the first block where the two
  chains differ. No split line means tip churn, a lagging reference, or an
  explorer serving an orphan. Wait for the next run.
- Recheck by hand at the split height: our `getblockhash` against the reference,
  now, not from the incident file.
- Real divergence is a suffix: every height from the split up differs, and stays
  different. Scattered mismatches with matches in between point at a polluted
  reference index, not a fork. I hit this with a public explorer that kept
  orphan records after reorgs.
- Ignore incidents more than a few hours old. Archive them; don't act on them.

## 2. Stop digging

- Turn the internal miner off and restart once, so the live process matches the
  config. A miner on the wrong branch extends it, and two large miners extend it
  faster. In one fork my two miners built the wrong branch about five times
  faster than the network built the right one.
- Do this restart before step 3, never after it. Once, my miner watchdog
  restarted the node at the same moment my heal step invalidated the bad block,
  and the restart wiped out the invalidation.
- Do not flip the config as a signal to other watchers without restarting the
  process. I did this once by accident: the config said mining was off, so my
  miner watchdog went quiet, while the live process kept mining for 70 minutes.
- Leave mining off until a person turns it back on after review.

## 3. Shallow fork: invalidate our first wrong block

This works when the fork is inside the window the node can still reorg (see
step 0). It changes no files and can be undone.

1. Read our block hash at `split_height` fresh from the node.
2. Call `invalidateblock` with that hash. The node drops that block and
   everything built on it and switches to the best other branch it knows.
3. Do not restart the node afterwards. In the builds I ran, the set of
   invalidated blocks lived in memory only. A restart forgot it and the node
   went straight back to the wrong branch. If the node restarts for any reason
   while still diverged, invalidate again.
4. Check the parameter format on your build. On mine the RPC rejected a hex
   string and wanted the hash as a JSON array of 32 bytes in internal order,
   which is the reverse of the hex shown by `getblockhash`. Display order
   answered "not found". Test against a harmless block first.
5. Try a bounded number of times (I used three) and then stop and page. Repeat
   attempts that fail mean the fork is deeper than it looks or the node lacks
   the canonical blocks.
6. To undo, call `reconsiderblock` with the same hash.

When it works, the hash at the split height matches the reference on the next
`tip-track.sh` run and its log line goes back to `OK aligned`.

## 4. Deep fork: restore from a backup and resync

Past the reorg limit, the node will never rejoin by itself. In October 2026 a
seven hour internet outage left my node mining a private chain of more than 600
blocks. The fix was a restore and a short sync, not a sync from zero.

1. Write the rollback first: the exact commands that put the forked state back.
   Keep the forked state for later study rather than deleting it.
2. Pick the newest backup from before the split height, made by the same build
   family and database format as the binary you will run.
3. Check that the backup carries the same node identity as the live node before
   you swap anything. If it does not, stop.
4. Pause anything else that acts on the node (bots, schedulers) for the length
   of the resync.
5. Stop the node and wait for the process to exit fully. Zebra holds its state
   lock through a clean shutdown; starting again after a few seconds aborted on
   mine.
6. Move the forked state aside, copy the backup into place, start the node.
7. Watch the tip climb toward the peers' tip. Mine synced about 5,700 blocks in
   under an hour.
8. Verify: our hash at the old split height equals the reference's; finality
   advances; the peer count is normal; the network upgrade schedule the node
   reports is the one you expect.
9. Resume the paused jobs.

## 5. Afterwards

- Turn mining back on deliberately, once `tip-track.sh` has said `OK aligned`
  for a while.
- Record the fork with `bin/fork-report.sh mark <split_height>` so the per
  version fork count stays honest.
- Archive the incident file under a name that says how it ended (healed, false
  positive, stale).
- Write down what the watchers missed. Each script in this repo came from a
  line in such a note.
