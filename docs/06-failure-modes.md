# Failure-mode catalogue

For every failure: what you **see**, how to **confirm**, what to **do**, and which drill rehearses it. Print it.

## Postgres / Patroni

| Failure | Symptom | Confirm | Do | Drill |
|---|---|---|---|---|
| Primary crashes | writes fail ~25 s then recover | `patronictl list` (new leader, TL+1), `patronictl history` | wait; then bring the old node back, it rejoins as a replica | 01 |
| Planned maintenance | none if done right | `patronictl list` | `switchover` first, then work on the old primary | 02 |
| etcd loses quorum | **all nodes are replicas, writes fail at once**, Postgres still runs | `etcdctl endpoint health --cluster`; Patroni log `DCS is not accessible` | fix etcd; Patroni recovers by itself | 03 |
| Primary partitioned | the node stops Postgres; others elect a new primary | node unreachable; `patronictl list` | restore the network; the old node rewinds or re-clones | 04 |
| Async replica lost data on failover | acknowledged writes missing | compare with application logs; `LOST WRITES` in `make report` | accept, or run `synchronous_mode_strict` | 05 |
| Replica lag grows | stale reads, `ops.replication` lag climbs | `ops.replication`, `pg_stat_wal_receiver`, long query on the replica | find paused replay / heavy query / slow disk; do not fail over to a lagging node | 06 |
| Replica will not start | `State: start failed` | `docker logs pgN` | `patronictl reinit hagod pgN` | 07 |
| `pg_wal` fills the disk | disk alarm, then Postgres stops | `du pg_wal`; `ops.slots` (inactive slot?); `ops.archiver` (failing?) | drop the orphan slot / fix `archive_command` | 08 |
| Sessions pile up behind a lock | app "hangs", connections rise | `ops.blocked`, `ops.activity` (`idle in transaction`) | terminate the **blocker**; set `idle_in_transaction_session_timeout` | 09 |
| Someone drops a table | missing relation errors | `select to_regclass(...)` | PITR to a scratch server, copy the table back | 10 |
| HAProxy dies | all clients fail; Postgres and Patroni look fine | `docker ps`, `curl :7100` | restart it; run two with a VIP in production | game day |
| Two primaries (split brain) | writes land on two nodes | `curl /primary` on every node; `patronictl list` | stop the wrong one **immediately**, then rebuild it. Should never happen with a healthy DCS | n/a |
| Disk full on the primary | writes fail, Postgres crashes | `df`, `pg_wal` | free space (never delete WAL by hand), find the cause (slots/archive) | 08 |
| Max connections reached | `FATAL: sorry, too many clients` | `select count(*) from pg_stat_activity` | find the leak; add a pooler (PgBouncer) | |
| Wraparound approaching | `autovacuum to prevent wraparound` in log | `select age(datfrozenxid) from pg_database` | let autovacuum finish; never cancel it; add resources | |

## Redis / Sentinel

| Failure | Symptom | Confirm | Do | Drill |
|---|---|---|---|---|
| Master crashes | writes fail ~6 s | `SENTINEL GET-MASTER-ADDR-BY-NAME`, sentinel log `+switch-master` | wait; restart the old node: it rejoins as a replica | 11 |
| Sentinel quorum lost | master flagged `s_down`, **no failover** | `SENTINEL CKQUORUM` says `NOQUORUM` | bring sentinels back; never run with fewer than 3 | 12 |
| Network split | two masters; clients disagree | `ROLE` on both; stale writes | heal; accept the loss on the minority side; set `min-replicas-to-write` | 13 |
| Out of memory | `OOM command not allowed` | `INFO memory`, `INFO stats` evicted_keys | right policy per workload; TTLs; find big keys | 14 |
| Slow command | latency spike, a **failover with a healthy node** | `SLOWLOG GET`, `LATENCY LATEST`, sentinel log | find and ban the command; `SCAN`, `UNLINK`; tune `down-after` | 15 |
| Replica lost link | `master_link_status:down` | `INFO replication` on the replica | check network, `repl-backlog-size`, output buffer limits | |
| Full resync loop | CPU/IO spikes, replica keeps resyncing | master log `Client ... scheduled to be closed ASAP for overcoming of output buffer limits` | raise `client-output-buffer-limit replica` and the backlog | |
| Data loss after restart | keys missing | `INFO persistence` | AOF on, `appendfsync everysec`; restore from backup | |
| Sentinel TILT | no failovers for 30 s, repeated | `+tilt` in sentinel log | find the blocked loop (DNS, CPU starvation, VM clock) | (see architecture) |

## Decision trees

**"The application cannot write to Postgres"**
```
patronictl list
 ├─ no Leader ───────────► etcd healthy? ─ no ─► fix etcd (drill 03)
 │                                        └ yes ─► wait ttl (30 s); then failover only if a replica streams with lag 0
 ├─ Leader ok ──────────► curl :5000 through HAProxy fails? ─ yes ─► HAProxy down/unaware (:7100)
 │                                                          └ no ─► app: connection pool, DNS, credentials
 └─ Leader ok, writes slow ─► ops.blocked (locks) · ops.activity · disk latency · ops.replication (sync standby behind?)
```

**"The application cannot reach Redis / it is slow"**
```
SENTINEL GET-MASTER-ADDR-BY-NAME mymaster ─► is that node alive?
 ├─ no ──► SENTINEL MASTER (s_down? o_down?) ─► CKQUORUM ─► sentinel log
 ├─ yes, slow ─► SLOWLOG GET · LATENCY LATEST · INFO commandstats · CLIENT LIST (blocked?)
 └─ yes, errors ─► INFO memory (OOM?) · min-replicas-to-write refusing? (NOREPLICAS)
```
