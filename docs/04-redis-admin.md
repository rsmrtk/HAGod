# Redis and Sentinel administration on the lab data

Open a session: `make rcli` (connects to whichever node Sentinel says is the master; it tells you which). Password is set for you
(`REDISCLI_AUTH`). Redis 7.4. Add a node to look at a replica: `./scripts/rcli.sh redis2`.

> Redis commands are case-insensitive. Keys are case-sensitive. Everything is a string on the wire; the **type** of a key decides
> which commands work on it. `WRONGTYPE` means you used a command for the wrong type.

## 1. What is in here, safely

```
DBSIZE                          how many keys (cheap, O(1))
INFO keyspace                   keys, how many have a TTL, average TTL
SCAN 0 MATCH account:* COUNT 100    walk the keyspace in small steps; repeat with the cursor it returns until it returns 0
TYPE account:1                  hash | string | list | set | zset | stream
TTL session:...                 seconds left; -1 = no expiry; -2 = key does not exist
OBJECT ENCODING account:1       how it is stored internally (listpack = small & compact, hashtable = large)
MEMORY USAGE bigkey:audit_blob  bytes this key costs
```
`make overview` prints keys grouped by pattern, with type, count and whether they expire. Study it first.

> **Never run `KEYS *` on a real server.** It walks every key in one blocking command; on millions of keys Redis stops answering
> for seconds and Sentinel may fail over (drill 15). Use `SCAN` (or `redis-cli --scan --pattern 'x:*'`).

## 2. The data types, on the seeded keys

| Key pattern | Type | Used for | Try |
|---|---|---|---|
| `session:*` | string with TTL | login sessions | `TTL <one>`; `SET session:x u1 EX 60`; `GET`, `EXPIRE`, `PERSIST` |
| `account:<id>` | hash | cached account | `HGETALL account:1`; `HGET account:1 balance`; `HINCRBY account:1 balance -100`; `HSET account:1 status frozen` |
| `leaderboard:top_spenders` | sorted set | ranking | `ZREVRANGE leaderboard:top_spenders 0 4 WITHSCORES`; `ZRANK`; `ZINCRBY`; `ZCARD` |
| `queue:payments` | list | a FIFO queue | `LLEN`; `LRANGE queue:payments 0 4`; `LPOP`; `RPUSH` (use `BLPOP` for a blocking consumer) |
| `set:online_users` | set | membership | `SCARD`; `SISMEMBER set:online_users customer:7`; `SRANDMEMBER` |
| `stream:events` | stream | an event log with consumer groups | `XLEN`; `XRANGE stream:events - + COUNT 3`; `XINFO STREAM stream:events`; `XINFO GROUPS stream:events`; `XREADGROUP GROUP workers c1 COUNT 2 STREAMS stream:events >`; `XACK` |
| `hll:daily_visitors` | hyperloglog (a string) | unique counts in 12 KB | `PFCOUNT hll:daily_visitors` (≈1000, 1% error) |
| `bitmap:logins:2026-10-18` | string used as bits | yes/no per user id | `GETBIT`, `BITCOUNT bitmap:logins:2026-10-18` |
| `geo:atms` | sorted set | coordinates | `GEODIST geo:atms atm-kyiv atm-lviv km`; `GEOSEARCH geo:atms FROMLONLAT 30.5 50.4 BYRADIUS 600 km` |
| `ratelimit:<ip>` | string with 60 s TTL | rate limiting | `INCR`, `TTL` |
| `cache:rates:pair-*` | string, **no TTL** | a cache that never expires | `OBJECT IDLETIME`; why is this a risk? (section 5) |
| `hotkey:config:fees` | string | read thousands of times/s | `redis-cli --hotkeys` (needs an LFU policy) |
| `bigkey:audit_blob` | hash with 20,000 fields | a deliberately huge key | `HLEN`; `MEMORY USAGE`; `HSCAN`; never `HGETALL` |

**Exercise 1.** Which `account:*` hashes have the highest balance? You cannot query by value in Redis (this is not a database).
Try it with SCAN + HGET in a shell loop, then answer: what would you add so this query is cheap? (Hint: a sorted set indexed by balance.)

**Exercise 2.** A payment consumer: `LPOP queue:payments` vs. `BLPOP queue:payments 5`; what happens if the consumer crashes after popping?
(The payment is gone. That is why a stream with consumer groups and `XACK` is safer for payments; look at `XPENDING`.)

## 3. Is it healthy: `INFO`

`INFO` has sections; ask for one: `INFO replication`, `INFO memory`, `INFO stats`, `INFO persistence`, `INFO clients`, `INFO commandstats`.

| What you want | Command | Healthy |
|---|---|---|
| role and replicas | `INFO replication` | master: `connected_slaves:2`; replica: `master_link_status:up` |
| memory | `INFO memory` | `used_memory_human` well below `maxmemory_human`; `mem_fragmentation_ratio` near 1-1.5 (the lab shows >1 because the data is tiny) |
| are we evicting / expiring | `INFO stats` → `evicted_keys`, `expired_keys` | `evicted_keys` should be 0 unless you chose an eviction policy on purpose |
| cache effectiveness | `INFO stats` → `keyspace_hits`, `keyspace_misses` | hit ratio = hits / (hits+misses) |
| throughput | `INFO stats` → `instantaneous_ops_per_sec` | |
| is persistence working | `INFO persistence` | `aof_last_write_status:ok`, `rdb_last_bgsave_status:ok` |
| connections | `INFO clients` | `blocked_clients` should be low |
| which commands cost the most | `INFO commandstats` | one command dominating total time |

`INFO replication` on a master shows each replica as `slave0:ip=…,state=online,offset=…,lag=…`; **`lag` is seconds since its last ack.**
Compare `master_repl_offset` with each replica's `offset`: the difference is bytes the replica has not applied.

## 4. Finding what is slow or big

```
SLOWLOG GET 10             the last slow commands (threshold: slowlog-log-slower-than = 10 ms here)
SLOWLOG LEN / SLOWLOG RESET
LATENCY LATEST             spikes the server noticed (latency-monitor-threshold 100 ms here)
LATENCY DOCTOR             a human-readable analysis
CLIENT LIST                every connection: age, idle, the last command, what it is blocked on
CLIENT KILL ID <id>        close one
MONITOR                    streams EVERY command live. Powerful and heavy: use for seconds, never leave it running
redis-cli --bigkeys        sample the keyspace for the biggest key of each type (uses SCAN: safe)
redis-cli --memkeys        the same, by memory
redis-cli --latency        measures round-trip latency continuously (Ctrl-C to stop)
redis-cli --latency-history -i 5
redis-cli --stat           a one-line-per-second dashboard of keys, memory, clients
MEMORY DOCTOR              gives advice
```
The lab has `DEBUG SLEEP` enabled (drill 15) so you can make Redis slow on purpose and watch the slow log and latency react.

## 5. Memory and eviction

```
CONFIG GET maxmemory                 0 = unlimited; the lab sets 256mb
CONFIG GET maxmemory-policy          what Redis does when memory is full
CONFIG SET maxmemory 100mb           changes it live (NOT permanent, see CONFIG REWRITE)
CONFIG REWRITE                       writes the running config back to redis.conf
```

| Policy | When full | Use for |
|---|---|---|
| `noeviction` (default) | **refuse writes** with `OOM command not allowed` | queues, anything you cannot lose |
| `allkeys-lru` | delete the least recently used key | a pure cache |
| `allkeys-lfu` | delete the least frequently used | a cache with hot keys |
| `volatile-lru` / `volatile-ttl` | delete only keys that **have a TTL** | a mix of cache keys (with TTL) and permanent data |
| `allkeys-random` / `volatile-random` | random | rare |

Rule of thumb: **one Redis for caches, another for data you cannot lose.** If they share an instance, `volatile-*` is the only safe policy,
and every cache key **must** have a TTL: look at `cache:rates:*`, which has none, so under `volatile-lru` it would never be evicted and
would fill memory (drill 14).

Also count memory that is not keys: replication output buffers and the AOF rewrite buffer. Rule: keep `used_memory` under ~60% of the machine because a
background save (`BGSAVE`/AOF rewrite) forks and can briefly double memory in the worst case.

## 6. Persistence

| | RDB (snapshot) | AOF (append-only file) |
|---|---|---|
| What | a point-in-time dump every N seconds/changes (`save 60 1000`) | every write appended; `appendfsync everysec` = at most ~1 s lost |
| Restart | fast | slower, replays the log |
| Loss on crash | up to a few minutes | ~1 s (`always` = none, but slow) |
```
INFO persistence      last save time, status, whether a rewrite is running
BGSAVE                snapshot in the background
BGREWRITEAOF          compact the AOF in the background
LASTSAVE              unix time of the last successful save
```
Files live in `/data` on each node: `docker exec redis1 ls -la /data /data/appendonlydir`. Check an AOF: `redis-check-aof /data/appendonlydir/<file>`.
**A replica is not a backup**: `FLUSHALL` on the master is replicated to every replica in milliseconds. Back up the RDB/AOF files off the machine.

## 7. Replication by hand

```
ROLE                                   master/slave, with offset and replicas
REPLICAOF NO ONE                       make this node a master (a manual promotion: Sentinel normally does it)
REPLICAOF <host> 6379                  make this node a replica of that master
WAIT 1 100                             block until 1 replica has acked all my writes, or 100 ms pass; returns how many did
```
`WAIT` is how a client can get **semi-synchronous** writes: `SET x 1` then `WAIT 1 100`. It narrows loss but does not remove it (Redis can still fail over to a replica that missed it).

Danger: running `REPLICAOF` by hand on a Sentinel-managed set fights Sentinel. Make changes **through Sentinel** (`SENTINEL FAILOVER`).

## 8. Sentinel

Connect: `redis-cli -h sentinel1 -p 26379` (password is the same `hagod-redis`).

```
SENTINEL GET-MASTER-ADDR-BY-NAME mymaster      who is the master RIGHT NOW (this is what clients ask)
SENTINEL MASTER mymaster                       full state: flags, quorum, num-slaves, num-other-sentinels, down-after-milliseconds, failover-timeout
SENTINEL REPLICAS mymaster                     replicas as Sentinel sees them (look for flags: s_down, and slave-repl-offset)
SENTINEL SENTINELS mymaster                    the other sentinels
SENTINEL CKQUORUM mymaster                     "OK 3 usable Sentinels..." = enough sentinels to fail over; otherwise it tells you what is missing
SENTINEL FAILOVER mymaster                     start a failover now (like a switchover; no master crash needed)
SENTINEL RESET mymaster                        forget replicas/sentinels and rediscover (fixes stale entries after a rebuild)
SENTINEL CONFIG GET down-after-milliseconds    / SET to change it live
INFO sentinel                                  one-line summary
```
Reading the master's `flags`: `master` fine; `s_down` = THIS sentinel thinks it is down (subjectively); `o_down` = a quorum agrees (objectively): failover starts.
`+tilt` in the log = Sentinel's clock jumped or its loop was blocked; it **stops acting for 30 s**. Frequent TILT = a sentinel that is overloaded or on a flaky clock.

The log (`docker logs sentinel1`) tells the whole story: `+sdown` → `+odown` → `+try-failover` → `+elected-leader` → `+selected-slave` → `+promoted-slave` → `+switch-master`.

How a client should connect: ask Sentinel for the master address **every time it reconnects**, not once at start-up. Test your own application's behaviour with drill 11.

## 9. Users and safety

```
ACL LIST                       users and their permissions
ACL SETUSER app on >pw ~session:* +get +set +del +expire    an app user that can only touch session:* with four commands
ACL WHOAMI
CONFIG GET requirepass         (never print it in a ticket)
```
Lock down what can hurt: `rename-command`/ACLs for `FLUSHALL`, `FLUSHDB`, `KEYS`, `DEBUG`, `CONFIG`, `SHUTDOWN`. Production never has `enable-debug-command yes`.

## 10. Exercises

1. Use `redis-cli --scan --pattern 'session:*' | head` to take one session key. How many seconds until it expires? Change it with `EXPIRE`. Watch it vanish.
2. Run `redis-cli --bigkeys` and `MEMORY USAGE` for `bigkey:audit_blob`. How much would `HGETALL` on it cost? Try `HSCAN bigkey:audit_blob 0 COUNT 100` instead.
3. With `redis-cli --stat` running in one window, run `redis-cli -h <master> DEBUG SLEEP 2` in another. What shows in `--stat`, in `SLOWLOG`, in `LATENCY LATEST`?
4. `FLUSHALL` on a replica (it refuses: why?) then on the master (what happens to the replicas? Do `make seed-redis` to recover).
5. `SENTINEL FAILOVER mymaster` while `make watch` is open and the probe is running. Compare the downtime with drill 11 (a crash).
