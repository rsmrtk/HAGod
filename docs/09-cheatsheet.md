# Cheat sheet: the commands you will type at 3 a.m.

Keep this open. Run inside `make shell` (psql, patronictl, redis-cli ready). Details and explanations are in docs 02, 03, 04.

## First 60 seconds of ANY incident

```sh
make watch                                    # (lab) or your own dashboard
patronictl list                               # who leads, who streams, lag
redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster
redis-cli -h sentinel1 -p 26379 sentinel ckquorum mymaster
docker exec etcd1 etcdctl endpoint health --cluster
```
Questions in this order: **Is there exactly ONE primary / master? Can clients reach it? Are replicas following? What changed?**

## Postgres / Patroni

| I want to | Command |
|---|---|
| see the cluster | `patronictl list` · `patronictl list -W` (live) · `patronictl topology` |
| who is primary | `curl -s localhost:8101/primary -o /dev/null -w '%{http_code}'` (200 = yes) per node |
| move the primary (planned) | `patronictl switchover --leader pg1 --candidate pg2` |
| promote when there is no primary | `patronictl failover --candidate pg2` |
| restart / reload a node | `patronictl restart hagod pg2` · `patronictl reload hagod pg2` |
| see / change settings | `patronictl show-config` · `patronictl edit-config -s postgresql.parameters.work_mem=64MB` |
| does anything need a restart | `patronictl list -e` (Pending restart column) |
| maintenance mode on/off | `patronictl pause` · `patronictl resume` |
| rebuild a broken replica | `patronictl reinit hagod pg2` |
| failover history | `patronictl history` |
| run SQL on a role | `patronictl query hagod -r replica -c "select pg_is_in_recovery()"` |
| Patroni's own view | `curl -s localhost:8101/patroni \| jq` |
| the leader lock | `docker exec etcd1 etcdctl get /hagod/hagod/leader --print-value-only` |

## Postgres SQL (on the primary unless noted)

| I want to | SQL |
|---|---|
| node, role, timeline | `select * from ops.node;` |
| replication state and lag | `select * from ops.replication;` |
| replication slots, WAL retained | `select * from ops.slots;` |
| archiving ok? | `select * from ops.archiver;` |
| who is connected / busy | `select * from ops.activity;` |
| who blocks whom | `select * from ops.blocked;` |
| kill a session | `select pg_terminate_backend(<pid>);` (`pg_cancel_backend` is gentler) |
| idle in transaction | `select * from ops.activity where state='idle in transaction';` |
| biggest tables | `select * from ops.table_sizes limit 10;` |
| dead tuples, vacuum candidates | `select * from ops.dead_tuples limit 10;` |
| top queries | `select * from ops.top_queries;` |
| cache hit ratio | `select * from ops.cache_hit;` |
| am I a replica | `select pg_is_in_recovery();` |
| replica: bytes not yet applied | `select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());` |
| WAL size on disk | `docker exec pg1 du -sh /var/lib/postgresql/data/pgdata/pg_wal` |
| why is it slow | `explain (analyze, buffers) <query>;` |
| drop an unused slot | `select pg_drop_replication_slot('name');` |
| force WAL archive now | `select pg_switch_wal();` |

## Redis

| I want to | Command |
|---|---|
| keys, TTLs | `DBSIZE` · `INFO keyspace` · `SCAN 0 MATCH pat:* COUNT 100` · `TTL key` |
| what is it | `TYPE key` · `OBJECT ENCODING key` · `MEMORY USAGE key` |
| role, replicas, lag | `ROLE` · `INFO replication` |
| memory | `INFO memory` · `CONFIG GET maxmemory*` · `redis-cli --bigkeys` |
| what is slow | `SLOWLOG GET 10` · `LATENCY LATEST` · `LATENCY DOCTOR` |
| who is connected | `CLIENT LIST` · `INFO clients` |
| persistence | `INFO persistence` · `LASTSAVE` · `BGSAVE` |
| semi-sync a write | `SET k v` then `WAIT 1 100` |
| live view | `redis-cli --stat` · `redis-cli --latency` |
| **Sentinel**: master now | `SENTINEL GET-MASTER-ADDR-BY-NAME mymaster` |
| Sentinel: full state | `SENTINEL MASTER mymaster` (flags: s_down/o_down) |
| Sentinel: replicas, other sentinels | `SENTINEL REPLICAS mymaster` · `SENTINEL SENTINELS mymaster` |
| Sentinel: can we fail over | `SENTINEL CKQUORUM mymaster` |
| Sentinel: planned failover | `SENTINEL FAILOVER mymaster` |
| Sentinel: forget stale nodes | `SENTINEL RESET mymaster` |
| story of a failover | `docker logs sentinel1 \| grep -E 'sdown\|odown\|elected\|switch-master\|tilt'` |

## Logs

```sh
docker logs pg1 2>&1 | grep -E "promoted|demoted|lock|rewind|failed" | tail     # Patroni decisions
docker logs pg1 2>&1 | grep -iE "ERROR|FATAL|still waiting|archive command failed" | tail
docker logs sentinel1 2>&1 | tail -30
docker logs haproxy | tail
```

## Dangerous commands: stop and think

| Command | Why it hurts |
|---|---|
| `patronictl failover` | can lose committed writes (async) |
| `patronictl reinit` | deletes that node's data directory |
| `patronictl remove` | deletes the whole cluster's state from etcd |
| `patronictl pause` and forgetting `resume` | a dead primary is never replaced |
| `DROP/TRUNCATE/DELETE` without `where` | no undo except a restore (drill 10) |
| `vacuum full` | exclusive lock on the table |
| `select pg_terminate_backend(pid) from pg_stat_activity` (no filter) | kills **everyone**, including replication |
| `REPLICAOF` on a Sentinel-managed node | fights Sentinel |
| `FLUSHALL` / `FLUSHDB` | replicated to every replica instantly |
| `KEYS *` | blocks Redis; Sentinel may fail over |
| `DEBUG SLEEP`, `SHUTDOWN` | outage by your own hand |
| `etcdctl del --prefix ...` | erases Patroni's state |

## Numbers to remember (this lab)

| | |
|---|---|
| Postgres crash failover | ~25 s (ttl 30) |
| Planned switchover | ~3 s, ~4 s of client errors |
| etcd quorum lost | writes stop **at once**; nothing is lost |
| Redis master crash failover | ~6 s (`down-after` 5 s) |
| Redis `min-replicas-to-write` | isolated master refuses writes after `min-replicas-max-lag` |
| Async replication loss in the lab | ~100 writes in a 20 s cut (drill 05); ~130 in a Redis split brain (drill 13) |
