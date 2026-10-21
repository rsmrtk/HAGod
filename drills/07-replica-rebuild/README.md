# Drill 07: Rebuild a broken replica

**Goal.** Fix a replica whose data is unusable without touching the cluster.

## The story
A replica's disk had a problem and its data directory is damaged. It will not start. Production keeps running on the others.

## Predict first (write it down)
- What state will `patronictl list` show?
- What is the right command to repair it, and how long will it take?

## Run
```sh
make drill-07       # removes pg_control on one replica and kills Postgres
make verify-07      # runs the repair if you did not
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
patronictl list                    # State: start failed
docker logs pgN 2>&1 | grep -iE "start|control|FATAL" | tail
patronictl reinit hagod pgN        # the repair
docker logs pgN 2>&1 | grep -iE "basebackup|replica|clone"
```

## What you should see
State shows **`start failed`**. `patronictl reinit hagod pgN --force` wipes the node and clones it from the leader with `pg_basebackup`, then it streams again. On this lab's data (a few hundred MB) it took **minutes**; the application noticed nothing.

## Understand
Patroni keeps trying to start Postgres, which keeps failing: that is the `start failed` state. `reinit` is the supported way to rebuild a replica: it removes the data directory, takes a base backup from the leader, and re-attaches it. Cost: copying the whole database over the network and extra load on the leader (use `clonefrom: true` on a replica to clone from it instead).

On a multi-terabyte database a full re-clone can take hours. Faster options: restore from a recent physical backup then let it catch up from the WAL archive (what pgBackRest's delta restore does).

## Fix
Run `reinit` and wait for `streaming`. Then ask: how long would this take on your biggest database, and do you have a faster path?

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. What did reinit do, step by step?
2. What is faster than a full copy?
3. Did the application notice?

---

### Answers (read after you tried)
1. Stopped Postgres, deleted the data directory, ran `pg_basebackup` from the leader (with a replication slot), wrote the recovery settings, started it as a replica.
2. Restoring a backup plus WAL replay (pgBackRest delta restore), or `pg_rewind` if the node merely diverged.
3. No. Replicas are not in the write path; reads on port 5001 are balanced over the remaining replicas.
