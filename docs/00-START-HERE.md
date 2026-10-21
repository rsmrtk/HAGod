# Start here: the plan

You said the hard part of the job is **PostgreSQL with Patroni** and **Redis with Sentinel**. Knowing the commands is not
enough; what matters is what you do at 3 a.m. when one of them is on fire. So this lab trains the thing that is hard to get
anywhere else: **being calm and correct while it breaks.**

## The method (the same for every drill)

1. **Predict.** Before you press anything, write down (even one line) what you think will happen and how long it will take.
   A wrong prediction is the most valuable thing the lab can give you: it shows exactly what you do not understand yet.
2. **Break.** `make drill-NN`. It tells you what it did, and starts a clock.
3. **Observe.** Watch `make watch`. Then look with your own commands (the drill's README lists them). Do not use `make heal`.
4. **Fix.** Bring it back by hand. The drill's README says what a good fix looks like.
5. **Measure.** `make verify-NN` prints the numbers: how long it took, how many writes were lost.
6. **Write the runbook.** Three lines is enough: symptom, how to confirm, what to do. Use `docs/07-runbook-template.md`.
7. **Log it** in `docs/08-progress.md` (your scoreboard).

Do each drill **twice**: once reading the README, once without it. Only the second time counts as learned.

## Setup (once)

```sh
cd ~/s/hub/HAgod
make up && make seed && make writer-start
make obs-up          # optional but worth it: Grafana http://localhost:3300 (login admin / admin)
```

Keep two terminals: one for `make watch`, one for your commands (`make shell` gives you `psql`, `patronictl`, `redis-cli`).

Check that everything is healthy before each drill: `make status` should show 1 primary and 2 streaming replicas, 1 Redis master
with 2 replicas, `quorum check: OK`. If not: `make heal`.

## The four-week plan (about 1 hour on a working evening)

### Week 1: Postgres and Patroni, the happy path and the first failures
| Day | Do | You should be able to say afterwards |
|---|---|---|
| 1 | Read `01-architecture.md`. Run `make overview`. Open `make psql` and try every view in `ops.*` | "Writes go client → HAProxy → whoever Patroni says is primary" |
| 2 | `docs/03-postgres-admin.md` sections 1-3 (look around, find slow queries, indexes) | I can read `EXPLAIN` and add an index that gets used |
| 3 | **Drill 02** (planned switchover), then **Drill 01** (kill the primary) | A switchover takes ~3 s, a crash takes ~25 s, and why (ttl) |
| 4 | **Drill 04** (partition the primary), **Drill 03** (lose etcd) | Why a healthy Postgres can be read-only, and why that is a feature |
| 5 | Write the runbooks for drills 01-04 | |
| 6-7 | Repeat 01-04 without the README | |

### Week 2: Postgres data safety and daily operations
| Day | Do | Learn |
|---|---|---|
| 1 | **Drill 05** (async vs strict sync) | The real trade-off between availability and data loss, in numbers |
| 2 | **Drill 06** (replication lag), **Drill 07** (rebuild a replica) | How to see lag, what `reinit` does, what it costs |
| 3 | **Drill 08** (orphan slot, full disk) and the `archive_command` bonus | Two classic ways pg_wal eats a disk |
| 4 | **Drill 09** (locks, idle in transaction) | Find the blocker, kill it, prevent it |
| 5 | **Drill 10** (backup and point-in-time recovery) | Restore to 1 second before a `DROP TABLE` |
| 6-7 | `docs/03-postgres-admin.md` sections 4-8; vacuum the bloat demo | |

### Week 3: Redis and Sentinel
| Day | Do | Learn |
|---|---|---|
| 1 | `docs/04-redis-admin.md` sections 1-4 on the seeded keys; `make overview` | Types, TTLs, big keys, `SCAN` not `KEYS` |
| 2 | **Drill 11** (kill the master) | ~6 s failover, how Sentinel decides, how the old master rejoins |
| 3 | **Drill 12** (lose the Sentinel quorum) | Quorum vs majority |
| 4 | **Drill 13** twice: plain, then protected | Split brain, lost writes, `min-replicas-to-write` |
| 5 | **Drill 14** (out of memory), **Drill 15** (slow command causes a failover) | Eviction policies; why `KEYS *` can cause an outage |
| 6-7 | Runbooks for 11-15 | |

### Week 4: put it together
| Day | Do |
|---|---|
| 1-3 | **Game days**: `make gameday`, diagnose with no hints, then `make gameday-reveal`. Do at least six. Time yourself |
| 4 | Turn on `make obs-up`; for each drill, find the moment on the Grafana dashboard and the alert that should have fired |
| 5 | Combine failures by hand: kill a Postgres replica, then the primary; pause the Redis master during a switchover |
| 6 | Walk through `docs/06-failure-modes.md` and the questions in `docs/10-interview-questions.md` out loud |
| 7 | Write a one-page "how our HA works and how it fails" for your own team, from your runbooks |

## Rules that make it work

- **Never skip step 1.** Predict first.
- **Do not use `make heal` while you are practising.** It is for between drills. Fixing by hand is the skill.
- **Keep numbers.** "Failover took 25 s" is knowledge; "it was fast" is not.
- **Break one thing at a time first, then combine.**
- **Read the logs** (`docker logs pg1`, `docker logs sentinel1`). In production you will mostly have logs and metrics, not a debugger.

## What is different from your bank (and what to ask there)

This lab uses **etcd** for Patroni and **HAProxy** in front. Your bank may use Consul, ZooKeeper or Patroni's built-in Raft,
and may use `vip-manager` or `pgbouncer`/`pgpool` instead of HAProxy. The lessons carry over, but check:

- Which DCS do we use, how many nodes, and on which hosts? (drill 03)
- Is replication synchronous? Strict? (drill 05)
- What is `ttl`, `loop_wait`, `retry_timeout`, `maximum_lag_on_failover`? (`patronictl show-config`)
- Where do backups go, how often are they restored as a test, and what is the PITR procedure? (drill 10)
- How do Redis clients find the master: Sentinel-aware client, or a proxy? (drills 11, 13)
- Are Sentinels on separate hosts from Redis? Is `min-replicas-to-write` set? Is persistence AOF or RDB? (drills 12, 13)

Bring those questions to work: they are what a senior reviewer asks.

## Reading order for the docs

1. `01-architecture.md`: what every box does and the timers that matter
2. `09-cheatsheet.md`: one page; keep it open
3. `02-patroni-commands.md`, `03-postgres-admin.md`, `04-redis-admin.md`: the commands, explained, with exercises
4. `05-backup-pitr.md`, `06-failure-modes.md`, `07-runbook-template.md`
5. `10-interview-questions.md`: when you feel ready
