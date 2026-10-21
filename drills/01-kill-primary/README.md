# Drill 01: Kill the primary

**Goal.** See exactly what a Postgres crash looks like, and measure the failover.

## The story
The primary's host loses power. Nobody touches anything. The application should recover on its own, but how long does it take, and was anything lost?

## Predict first (write it down)
- Which node becomes primary? Is it the same every time?
- How many seconds without writes? Write a number.
- Will any **acknowledged** write be lost?

## Run
```sh
make watch                 # second terminal
make drill-01
make verify-01
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
patronictl list -W                                  # live: leader disappears, a replica is promoted, timeline goes up
docker logs pg1 2>&1 | grep -E "promoted|lock|demot"   # what the survivors decided (run it on every node)
docker exec etcd1 etcdctl get /hagod/hagod/leader --print-value-only   # the lock changing hands
curl -s localhost:7100/ | head   # or open http://localhost:7100: HAProxy turning a server red then another green
make report                                         # what the application saw
```

## What you should see
In our runs the new primary appeared after **22-26 s**, and the application saw about **25-30 s of failed writes**. The timeline went up by one. `LOST WRITES: 0` in this drill because replication was streaming, but nothing guarantees that (see drill 05). When you start the dead node again it comes back as a **replica**, repaired by `pg_rewind` if its WAL had diverged.

## Understand
The primary renews the leader key in etcd every `loop_wait` (10 s). When it dies the key is not released: it must **expire** (`ttl` = 30 s). Only then do the replicas race for the lock, and the winner promotes. So failover time is roughly `ttl` minus how long ago the last renewal was, plus promotion, plus HAProxy's health checks (`rise 2` = ~2 s).

The fastest replica is not necessarily the winner: Patroni prefers the one with the most WAL, and refuses any that is more than `maximum_lag_on_failover` behind.

## Fix
Nothing to fix: it is automatic. Your job is to **bring the old primary back** (`docker start pgN`), confirm it re-joins as a streaming replica (`patronictl list`), and check why it died. If it comes back with `start failed`, see drill 07.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. What decided the failover time? Which setting would you lower to make it faster, and what is the risk?
2. Why did the old primary not simply continue as primary when it came back?
3. Could a write be lost, and under which setting is that impossible?
4. What would your monitoring have shown?

---

### Answers (read after you tried)
1. `ttl` (and `loop_wait`/`retry_timeout`). Lowering them speeds failover but raises the risk of **false failovers** on a slow or jittery network or a short etcd hiccup. Rule: `loop_wait + 2*retry_timeout <= ttl`.
2. A new primary exists on a **new timeline**. The old node's timeline is behind; two primaries would be split brain. Patroni sees the leader key belongs to another node and starts the old one as a replica (running `pg_rewind` first when needed).
3. Yes, with asynchronous replication, anything the dead primary acknowledged but had not yet shipped. Strict synchronous mode (`synchronous_mode_strict`) makes it impossible, at the cost of availability (drill 05).
4. `PatroniNoLeader` (after ~20 s), HAProxy backend down, application errors on port 5000, timeline change.
