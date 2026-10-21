# Drill 11: Kill the Redis master

**Goal.** See Sentinel fail over and measure it.

## The story
The Redis master host dies. Sessions and caches depend on it.

## Predict first (write it down)
- Which replica is promoted? How long does it take?
- Does the old master come back as master?

## Run
```sh
make drill-11
make verify-11
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
docker logs sentinel1 2>&1 | grep -E "sdown|odown|elected|selected-slave|promoted|switch-master"
redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster
redis-cli -h <node> role
make report
```

## What you should see
A new master appears after **~6 s** (5 s `down-after-milliseconds` + the election, ~1 s). The application sees ~6 s without Redis writes. The restarted old master rejoins as a **replica** (the entrypoint asks Sentinel who the master is).

## Understand
Each sentinel pings the master. After `down-after-milliseconds` without a valid reply it flags `+sdown` (subjectively down). When `quorum` (2) sentinels agree it is `+odown`. Then the sentinels **elect one of themselves** as the failover leader (it needs a majority: 2 of 3), which picks the best replica (priority, offset, run id), sends `REPLICAOF NO ONE`, and tells the others (`+switch-master`). Replication is asynchronous, so the last writes before the crash can be lost.

## Fix
Restart the dead node and verify it is a replica of the new master (`ROLE`). If it ever starts as a master by itself (a stale config), Sentinel demotes it, but any writes it took in that moment are lost.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Which writes can be lost, and can you make the number smaller?
2. Why did the restarted old master not come back as master?
3. How do clients find the new master?

---

### Answers (read after you tried)
1. Writes acknowledged by the master but not yet received by the replicas. Smaller: `min-replicas-to-write` plus `WAIT` for important writes, but there is no zero in async replication.
2. Our entrypoint asks Sentinel first, and Sentinel would reconfigure it as a replica of the new master anyway. A node that returns as master with old data would be demoted and its data discarded.
3. By asking Sentinel (`GET-MASTER-ADDR-BY-NAME`) on every reconnect; a Sentinel-aware client library does this automatically. There is no proxy.
