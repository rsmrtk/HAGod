# Questions to answer out loud (with the short answer)

Practise explaining, not reciting. If your answer takes more than 30 seconds, you probably do not own it yet.

## Patroni and Postgres HA

1. **How does Patroni decide who is the primary?** One TTL'd leader key in the DCS (etcd/Consul/ZooKeeper/Raft). Holder = primary, renews every `loop_wait`; if it cannot, the key expires and replicas race for it.
2. **Why does a crash take ~25 s but a switchover ~3 s?** Crash: the key must expire (`ttl`). Switchover: the old primary releases the key voluntarily after the candidate caught up.
3. **What are `ttl`, `loop_wait`, `retry_timeout`, and the rule between them?** `loop_wait + 2*retry_timeout <= ttl`, so a primary that loses the DCS has time to fence itself before anyone else can be elected.
4. **What happens when the DCS is down?** The primary demotes itself (no lock, no writes). Postgres is running but read-only everywhere. `failsafe_mode` can soften it.
5. **How do you prevent split brain?** Self-fencing on lost lock, a TTL longer than the fencing time, optionally a watchdog; never promote by hand outside Patroni.
6. **What is the cost of asynchronous replication, in plain words?** Acknowledged transactions can be lost on failover. Measured here: ~100 writes for a 20 s cut.
7. **What do `synchronous_mode` and `synchronous_mode_strict` change?** Sync prefers a sync standby and only that node can be promoted, but falls back to async when none is available; strict never acknowledges without a standby (no loss, writes stop).
8. **A replica is 400 MB behind and the primary dies. What happens?** Patroni will not promote a replica beyond `maximum_lag_on_failover`; if all are, there is no automatic failover.
9. **Failover vs switchover?** Switchover = planned, cooperative, no loss; failover = emergency when there is no healthy leader, may lose data.
10. **How do you change `shared_buffers` on a Patroni cluster?** `patronictl edit-config -s postgresql.parameters.shared_buffers=...`, then restart replicas first and the leader last (or switchover first). Check the *Pending restart* column.
11. **A replica says `start failed`. Steps?** Read the log; if the data directory is damaged `patronictl reinit`; consider a restore if the database is huge.
12. **Why not `pg_ctl restart` or edit `postgresql.conf` on a Patroni node?** Patroni owns the lifecycle and the config; manual changes are overwritten or cause a conflict and, in the worst case, two primaries.
13. **`pg_wal` is growing. Where do you look?** Inactive replication slot (`pg_replication_slots`), failing `archive_command` (`pg_stat_archiver`), a far-behind replica with a large `wal_keep_size`.
14. **How do you find what blocks a query?** `pg_blocking_pids`, `pg_locks`, `pg_stat_activity`; kill the **root blocker** (`pg_terminate_backend`), usually an `idle in transaction` session.
15. **What does an old open transaction do to the database?** Holds locks, blocks VACUUM from cleaning newer dead tuples (bloat), can hold back replicas and `xmin`.
16. **VACUUM vs VACUUM FULL?** Plain makes space reusable without a long lock; FULL rewrites the table, shrinks it, and takes an exclusive lock.
17. **How do you take and restore a point-in-time backup?** Base backup + continuous WAL archive; restore the base, `recovery_target_time`, `restore_command`, `recovery.signal`; do it on a separate server.
18. **Is replication a backup?** No. A DROP replicates in milliseconds.
19. **What are RPO and RTO of your setup, and how do you know?** Measured: failover time and lost writes from the probe; restore time from a real restore test.
20. **What would you monitor first?** Number of primaries (exactly 1), replica lag (bytes and seconds), etcd health, `pg_stat_archiver` failures, inactive slots, disk of `pg_wal`, connection count, long/idle-in-transaction sessions.

## Redis and Sentinel

21. **How does Sentinel work?** Three or more processes monitor the master; `down-after-milliseconds` → SDOWN; quorum agree → ODOWN; one sentinel elected by a majority runs the failover and the clients are told the new address.
22. **Quorum vs majority?** Quorum = sentinels that must agree the master is down; majority of *all* sentinels must authorise the failover. Both are needed.
23. **Why three sentinels, on different hosts?** Majority tolerates one failure; separate hosts so one failure does not remove two guards (or a guard and the master).
24. **Is Redis replication synchronous?** No. Writes can be lost on failover; `WAIT` and `min-replicas-to-write` narrow, not remove, the window.
25. **How can two masters exist and what is lost?** A partition: Sentinel promotes a replica on the majority side while clients still write to the old master; when it heals the old master resyncs and drops what it accepted.
26. **What does `min-replicas-to-write` do and what does it cost?** The master refuses writes if fewer than N replicas acked within `min-replicas-max-lag`; shrinks loss, reduces availability.
27. **Why is `KEYS *` dangerous?** Single-threaded: it blocks; Sentinel can mistake a busy master for a dead one and fail over. Use `SCAN`.
28. **`noeviction` vs `allkeys-lru`?** Refuse writes (safe for data) vs silently delete (right for caches only).
29. **RDB vs AOF?** Snapshot (fast restart, may lose minutes) vs log (`everysec` loses ~1 s, slower restart); you can use both. Neither is an off-host backup.
30. **A restarted old master: how does it rejoin?** It must start as a replica of the current master (ask Sentinel first); Sentinel also reconfigures stragglers.
31. **What is Sentinel TILT?** Sentinel detects its own timing problems (clock jump, blocked loop) and stops acting for 30 s. A cause: DNS resolution blocking the loop when a hostname stops resolving.
32. **How should a client connect?** Through a Sentinel-aware library that asks for the master address on every reconnect, with timeouts and retries.
33. **What would you monitor?** Exactly one master, replicas linked, replica lag/offset, memory vs `maxmemory`, evictions, slowlog, `connected_clients`, sentinel count / quorum.
34. **How do you find a big key without blocking?** `redis-cli --bigkeys` / `--memkeys` (SCAN based), `MEMORY USAGE`, and use `UNLINK` to delete.
35. **How do you stop a developer running `FLUSHALL`?** ACLs for the application user, `rename-command` or disabling it, and keep off-host backups.

## System design / judgement

36. **A payment must never be lost but must also be available. What do you do?** State the trade-off, choose per data class (ledger: strict sync and accept brief unavailability; cache: async), and make the application idempotent with retries.
37. **A failover happened at 03:00. What goes in the post-mortem?** Timeline (`patronictl history`), detection time, the cause, what clients experienced (errors, duration, lost writes), what to change (timers, monitoring, runbook).
38. **How do you test that your HA works?** Regular game days: kill/partition/pause components on a staging copy, measure RTO/RPO, restore a backup, fix what surprised you. This repo is that practice.
