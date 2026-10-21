# Architecture: what every box does

## Postgres side

```
 client ──► HAProxy ─┬─ :5000  "primary"   asks every node: GET :8008/primary   (HTTP 200 = I am the primary)
                     └─ :5001  "replicas"  asks every node: GET :8008/replica   (HTTP 200 = I am a replica)
                          │
        ┌─────────────────┼─────────────────┐
       pg1               pg2               pg3          each container = Postgres + Patroni
   Patroni+Postgres  Patroni+Postgres  Patroni+Postgres   Patroni starts, stops, promotes, demotes Postgres
        └─────────────────┼─────────────────┘
                 etcd1  etcd2  etcd3                    the leader lock and the cluster state
```

**Who decides who the primary is?** Patroni, with the help of etcd. There is one key in etcd, `/hagod/hagod/leader`, with a
TTL. The node that holds it is the primary. It must **renew** the key every `loop_wait` seconds. If it cannot (crashed,
partitioned, etcd down), the key expires and the replicas race to take it. Whoever wins promotes its Postgres.

That one fact explains almost every behaviour you will see:

| Situation | What happens | Why |
|---|---|---|
| Primary crashes | ~25 s until a new primary | the leader key must expire first (`ttl`) |
| You run `switchover` | ~3 s | the old primary **releases** the key on purpose, nobody waits for expiry |
| etcd loses quorum | primary demotes itself; **nobody** can write | it cannot renew the key, so it cannot prove it is the primary |
| Primary is cut off from the network | it stops Postgres by itself; others elect a new one | same: cannot renew, must stop before a second primary appears |

### The timers (in `images/patroni/patroni.yml.tpl`, stored in etcd, change with `patronictl edit-config`)

| Setting | Value here | Meaning |
|---|---|---|
| `ttl` | 30 | how long the leader key lives without renewal. Failover can take up to about this long |
| `loop_wait` | 10 | how often every Patroni runs its decision loop |
| `retry_timeout` | 10 | how long Patroni retries etcd/Postgres calls before giving up. **Must satisfy `loop_wait + 2 × retry_timeout <= ttl`** |
| `maximum_lag_on_failover` | 1 MB | a replica further behind than this is **not** eligible to become primary |
| `use_pg_rewind` | true | a returning old primary is repaired with `pg_rewind` instead of re-copying everything |
| `use_slots` | true | each replica has a replication slot, so the primary keeps the WAL it still needs |
| `synchronous_mode` | false | async by default; drill 05 turns it on (and `synchronous_mode_strict`) |

Lower `ttl` = faster failover but more false failovers on a slow network. That is the trade-off you will be asked about.

### What the client sees
- HAProxy checks Patroni every second (`inter 1s fall 2 rise 2`). After a failover it needs 2 good checks, so add ~2 s.
- `on-marked-down shutdown-sessions` kills existing connections to a node that stops being primary. Without that a client could
  keep writing into a demoted node. Applications must **reconnect and retry**: that is the application's half of HA.

### WAL archive and backups
- `archive_command` copies every finished WAL segment to the shared volume `/archive` (a stand-in for S3 or a backup server).
- Base backups go to `/backup`. Together they give you point-in-time recovery (drill 10).
- `archive_timeout = 60` forces a WAL switch at least every minute, which bounds how much you can lose if only the archive survives.

## Redis side

```
 client ──► asks Sentinel: "who is the master of 'mymaster'?" ──► connects to that address
 redis1 (master) ──replication──► redis2 (replica)
        └────────replication──► redis3 (replica)
 sentinel1  sentinel2  sentinel3     three guards that watch the master and agree on a failover
```

| Setting (`config/redis/sentinel.conf`) | Value | Meaning |
|---|---|---|
| `monitor mymaster <ip> 6379 2` | quorum **2** | how many sentinels must agree the master is down (ODOWN) |
| `down-after-milliseconds` | 5000 | no valid answer for 5 s = this sentinel thinks the master is down (SDOWN) |
| `failover-timeout` | 15000 | how long a failover attempt may take; also the pause before a retry |
| `parallel-syncs` | 1 | how many replicas resync from the new master at the same time |

**Two numbers decide a failover**: the **quorum** (2) says the master is *really* down; but one sentinel must then be
**authorised by a majority of all sentinels** (2 of 3) to run it. Lose two sentinels and you cannot fail over, even with
quorum 1. (Drill 12.)

Sentinel does **not** proxy traffic. The client library asks Sentinel for the master's address. A client that does not
(or that caches the address) will keep writing to the old master. (Drill 13.)

Replication is **asynchronous**: the master answers the client before replicas have the write. So a failover can lose the
last writes. `min-replicas-to-write` narrows that window by making an isolated master refuse writes.

## Why static IPs in this lab

Sentinel resolves hostnames inside its single event loop. When a name stops resolving (a network partition does exactly that),
every attempt blocks it, it enters **TILT** mode and stops failing over. You can see it: `+tilt` in `docker logs sentinel1`.
The lab therefore monitors the master by IP, and every container has a fixed address on `172.30.0.0/24`. (Production lesson:
if you use hostnames with Sentinel, test what happens when DNS fails.)

## What to look at

| I want to know | Look at |
|---|---|
| Who is the Postgres primary | `make watch`, `docker exec tools patronictl list`, `curl localhost:8101/primary` |
| Is replication healthy | `select * from ops.replication` on the primary |
| What does HAProxy think | `http://localhost:7100` |
| Is etcd healthy | `docker exec etcd1 etcdctl endpoint health --cluster` |
| Who is the Redis master | `make watch`, `redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster` |
| What did Sentinel decide and why | `docker logs sentinel1` (look for `+sdown`, `+odown`, `+elected-leader`, `+switch-master`, `+tilt`) |
| What did the application experience | `make report` |
