# Patroni, etcd and HAProxy: the commands you will actually type

Run these from `make shell` (a container with `patronictl`, `psql`, `redis-cli`) or prefix with `docker exec tools`.
Patroni 4.1, etcd 3.5, HAProxy 3.0.

## The twelve to learn first

| # | Command | What it answers | When you reach for it |
|---|---|---|---|
| 1 | `patronictl list` | who is leader, who streams, what lag | **always first** |
| 2 | `patronictl list -W` | the same, refreshed every 2 s | watching a failover |
| 3 | `patronictl topology` | the replication tree | cascaded replicas |
| 4 | `patronictl switchover --leader pg1 --candidate pg2` | move leadership **gracefully** | maintenance, patching the primary |
| 5 | `patronictl failover --candidate pg2` | force leadership when there is no leader | the primary is dead and nothing took over |
| 6 | `patronictl restart hagod pg2` | restart Postgres **under** Patroni | parameter that needs a restart |
| 7 | `patronictl reload hagod pg2` | reload config without restart | parameter that only needs a reload |
| 8 | `patronictl reinit hagod pg2` | wipe a replica and re-copy it from the leader | a broken/corrupt replica |
| 9 | `patronictl edit-config` | change the cluster-wide settings (stored in etcd) | any `postgresql.parameters` change |
| 10 | `patronictl show-config` | what the cluster-wide settings are now | before you change anything |
| 11 | `patronictl pause` / `resume` | turn auto-failover off/on | planned work where you do not want Patroni to react |
| 12 | `patronictl history` | every failover, with timeline and time | the post-mortem |

## `patronictl list`: read the table

```
+ Cluster: hagod (7697...) ---+--------------+-----------+----+-------------+-----+------------+-----+
| Member | Host | Role         | State        | TL | Receive LSN | Lag | Replay LSN | Lag |
| pg1    | pg1  | Sync Standby | streaming    |  9 |  0/1E01..   |   0 |  0/1E01..  |   0 |
| pg2    | pg2  | Leader       | running      |  9 |             |     |            |     |
| pg3    | pg3  | Replica      | streaming    |  9 |  0/1E01..   |   0 |  0/1E01..  |   0 |
```

| Column | Healthy value | If it is not |
|---|---|---|
| Role | exactly one `Leader` | none = no primary (writes down); look at etcd |
| State | leader `running`, replicas `streaming` | `start failed` = Postgres will not start (drill 07); `stopped`; `in archive recovery` = catching up from the archive |
| TL | the same on all | a lower TL on one node = it was an old primary and must be rewound |
| Lag (receive) | 0 | WAL not arriving: network, or the primary is overloaded |
| Lag (replay) | 0 | WAL arrives but is not applied: paused replay, long query on the replica, I/O |

Useful flags: `-e` (extended: tags, pending restart), `-f json` (for scripts: `patronictl list -f json | jq`), `-t` (timestamp).

## Planned work: the right order

```sh
patronictl show-config                          # 1. know the current settings
patronictl list                                 # 2. confirm everything is streaming and lag is 0
patronictl switchover --leader pg1 --candidate pg2 --force   # 3. move the primary off the node you will work on
# ... patch, reboot, resize pg1 ...
patronictl list                                 # 4. pg1 must come back as a streaming replica
```

`--force` skips the confirmation prompt. In production **omit it** and read the prompt: it prints exactly what will happen.
`--scheduled "2026-10-20T03:00"` plans it for later. `patronictl flush hagod switchover` cancels a scheduled one.

**Switchover vs failover:**

| | switchover | failover |
|---|---|---|
| Needs a healthy leader | yes | no |
| Data loss | none | possible (async) |
| Downtime | ~3 s | until a replica is promoted |
| Use | planned | emergency |

## Changing settings the Patroni way

Never edit `postgresql.conf` by hand and never `ALTER SYSTEM` on a Patroni cluster: Patroni writes its own parameters and will
overwrite or fight you. Use **one source of truth, etcd**:

```sh
patronictl edit-config                                          # opens your editor on the YAML
patronictl edit-config --force -s postgresql.parameters.work_mem=64MB     # non-interactive, one value
patronictl edit-config --force -s ttl=20 -s loop_wait=5                   # Patroni's own timers
patronictl list -e                                                        # "Pending restart" column: does anything need a restart?
patronictl restart hagod pg2 --pending                                    # restart only nodes that need it
```

Which parameters need a restart? `shared_buffers`, `max_connections`, `wal_level`, `max_wal_senders`, `shared_preload_libraries`…
Patroni shows `*` in the *Pending restart* column. Restart replicas first, the leader last (or switchover first).

## Maintenance mode

```sh
patronictl pause            # Patroni stops reacting: no failover, no restart of a dead Postgres
# ... do the risky work ...
patronictl resume --wait
```
While paused, **a crashed primary will not be replaced.** Use it briefly and always resume. Check with `patronictl list`
(a `Maintenance mode: on` line appears).

## Rebuilding

```sh
patronictl reinit hagod pg2 --force     # destroys pg2's data and re-clones it from the leader (pg_basebackup)
```
It takes as long as copying the database over the network; on a big database consider restoring from a backup instead.
Patroni usually repairs a returning old primary itself with `pg_rewind`; you only need `reinit` when that cannot work.

## Asking Patroni's REST API directly (no `patronictl` needed)

Ports on your machine: pg1 `8101`, pg2 `8102`, pg3 `8103`.

| URL | Meaning | Returns HTTP 200 when… |
|---|---|---|
| `/primary` | this is the leader | it is the primary |
| `/replica` | this is a healthy replica | it is a running replica |
| `/sync` | a synchronous standby | it is the sync standby |
| `/health` | Postgres is running | it is running |
| `/patroni` | JSON with role, state, timeline, WAL position | always (read it) |
| `/cluster` | JSON of all members | always |
| `/history` | failover history | always |
| `/metrics` | Prometheus metrics | always |

```sh
curl -s localhost:8101/patroni | jq '{role, state, timeline, replication_state: .replication_state}'
curl -s -o /dev/null -w '%{http_code}\n' localhost:8102/primary      # 200 or 503
```
HAProxy uses exactly these endpoints. When a node is wrongly missing from HAProxy, call the URL yourself.

## etcd: the leader lock

```sh
docker exec etcd1 etcdctl endpoint health --cluster                      # is every member healthy?
docker exec etcd1 etcdctl endpoint status --cluster -w table             # who is the etcd leader, DB size, raft index
docker exec etcd1 etcdctl member list -w table                           # who is in the cluster
docker exec etcd1 etcdctl get /hagod/hagod/leader --print-value-only     # which Postgres node holds the lock
docker exec etcd1 etcdctl get /hagod/hagod/ --prefix --keys-only         # every key Patroni keeps
docker exec etcd1 etcdctl get /hagod/hagod/config --print-value-only | jq    # the cluster-wide settings, raw
```
Rules: keep an **odd** number of members (3 or 5), on separate hosts; lose a majority and Patroni cannot decide. Back up the
etcd data if you rely on it for more than Patroni. Never `etcdctl del --prefix /` on a real cluster.

## HAProxy

```sh
curl -s 'localhost:7100/;csv' | awk -F, 'NR>1 && $2!="FRONTEND" && $2!="BACKEND" {print $1,$2,$18}'   # who is UP/DOWN per backend
docker exec haproxy sh -c 'echo "show servers state" | nc -U /var/run/haproxy.sock'                # (needs a stats socket; see haproxy.cfg)
docker logs haproxy | tail                                                                          # health check changes: "is UP", "is DOWN"
```
Open `http://localhost:7100`: green = UP, red = DOWN, the "Last check" column says why (`L7STS/503` = the node answered 503 on `/primary`,
which is correct for a replica).

## Reading Patroni's log

```sh
docker logs pg1 2>&1 | grep -E "promoted|demoted|acquired|lost|failed|rewind|bootstrap|Lock owner" | tail
```
| Line | Meaning |
|---|---|
| `no action. I am (pg1), the leader with the lock` | normal heartbeat |
| `following a different leader because I am not the healthiest node` | normal replica loop |
| `promoted self to leader by acquiring session lock` | this node just became primary |
| `Lock owner: pg1; I am pg2` | who holds the lock |
| `demoting self because DCS is not accessible and I was a leader` | etcd lost; this is drill 03/04 |
| `Could not rewind` / `starting a basebackup` | the old primary could not be repaired; it is being re-cloned |
| `failed to start postgres` | drill 07 |

## Safe vs dangerous

| Safe (read only) | Changes things | Dangerous |
|---|---|---|
| `list`, `topology`, `history`, `show-config`, REST `GET`s, `etcdctl get`, `endpoint health` | `switchover`, `restart`, `reload`, `edit-config`, `pause` | `failover`, `reinit`, `remove`, `etcdctl del`, `docker kill` on the wrong node, `pg_ctl` on a node Patroni manages |
