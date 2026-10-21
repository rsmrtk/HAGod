# Drill 06: Replication lag

**Goal.** Learn to see lag, and understand why a lagging replica is dangerous.

## The story
A reporting replica shows yesterday's numbers. Is replication broken, slow, or paused? And what happens if the primary dies right now?

## Predict first (write it down)
- How many MB behind will the paused replica be?
- Does the primary suffer? Does the other replica?

## Run
```sh
make drill-06       # pauses WAL replay on one replica and generates a lot of WAL
make verify-06      # resumes it and times the catch-up
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
select * from ops.replication;                                   -- on the primary: replay_lag_bytes, replay_lag
patronictl list                                                  -- Lag columns
-- on the paused replica (docker exec -e PGPASSWORD=hagod-super pg2 psql -h localhost -U postgres -d bank):
select pg_is_wal_replay_paused(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();
select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());
```

## What you should see
The paused replica falls **hundreds of MB** behind in bytes and seconds, while still `streaming`. It does not even have the new table. The primary is unaffected (a slot keeps the WAL it needs). Resuming replay catches up in a few seconds to a minute.

## Understand
A replica has three stages: it **receives** WAL, **flushes** it to disk, **replays** it so queries see it. `streaming` only says the first is working. Lag can sit in any stage: network (receive), disk (flush), a long query or `pg_wal_replay_pause()` (replay).

Patroni will not promote a replica more than `maximum_lag_on_failover` (1 MB) behind. If **every** replica is further behind than that when the primary dies, Patroni refuses to fail over rather than promote stale data: you have no automatic recovery and must decide.

## Fix
Find the cause (paused replay, long-running query on the replica holding back replay: `select * from pg_stat_activity` there, I/O, network), remove it, and watch lag fall. Never promote a lagging node to "fix" lag.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. If both replicas were further behind than `maximum_lag_on_failover` and the primary died, what would happen?
2. Which metric would have caught this first: byte lag, `replay_lag` seconds, or Patroni state?
3. Why can an application reading from replicas see a payment as missing?

---

### Answers (read after you tried)
1. Patroni would not promote anyone: the cluster stays without a primary until a human decides (raise the limit and accept loss, or restore the primary).
2. Alert on **both** bytes and seconds; Patroni state stays `streaming` throughout, so it alone would not alert. Seconds-based lag is the one users feel.
3. Replicas apply WAL after the primary commits; a read right after a write can hit a replica that has not replayed it yet (stale read). Read your own writes from the primary, or wait for replay.
