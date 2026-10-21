# Drill 13: Redis split brain

**Goal.** See how a network split creates two masters and loses acknowledged writes, and how min-replicas-to-write limits it.

## The story
The network between the Redis master and everything else breaks, but some clients still reach the old master. Both sides think they are right.

## Predict first (write it down)
- How many of the writes accepted by the old master survive?
- How does protection change it?

## Run
```sh
./drills/13-redis-split-brain/break.sh plain       ; make verify-13
make heal
./drills/13-redis-split-brain/break.sh protected   ; make verify-13
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
redis-cli -h <old master> role                    # still says master
redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster   # says the new one
docker exec tools tail /tmp/stale-writes.log      # the stale client: OK or NOREPLICAS errors
```

## What you should see
Plain: the stale client's **~130 writes were accepted** by the isolated master and **0 survived** the heal. Protected (`min-replicas-to-write 1`, `min-replicas-max-lag 5`): the master refused writes after about 5 s, only **~25 were accepted** and the rest got `NOREPLICAS`. Still not zero: replication is asynchronous.

## Understand
When the partition heals, the old master is reconfigured as a replica of the new master and **performs a full resync, discarding whatever it accepted while isolated**. There is no merge. `min-replicas-to-write` makes an isolated master stop accepting writes once it has had no replica ack for `min-replicas-max-lag` seconds: it shrinks the loss window but makes the master write-unavailable when its replicas are down.

## Fix
Decide the policy: availability (accept writes, risk loss) or safety (refuse writes). Make clients use Sentinel-aware connections that refresh the master address.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Which clients keep writing to an old master in real life?
2. What is the trade-off of `min-replicas-to-write`?
3. Could the lost writes be merged back?

---

### Answers (read after you tried)
1. Connection pools that never refresh, clients with a hard-coded address, DNS-cached addresses, long-lived connections in batch jobs.
2. Less loss, but the master becomes unavailable for writes whenever replicas are lagging or down.
3. No. The old master's changes are overwritten by the resync; you would need application-level reconciliation (idempotent writes, an outbox, or event sourcing).
