# HAgod

A training ground for running **PostgreSQL with Patroni** and **Redis with Sentinel** in production.
You break a real cluster on purpose, watch what happens, fix it, and write the runbook. Everything runs
on your laptop in Docker, nothing is simulated.

```
 your app (the "probe")
      |                     |
 HAProxy :5000 (writes)   Sentinel (who is the master?)
 HAProxy :5001 (reads)         |
      |                   redis1 (master) -> redis2, redis3
 pg1  pg2  pg3  <-- Patroni on each, deciding who leads
      \   |   /
   etcd1 etcd2 etcd3   <-- the leader lock
```

**What you get**

| | |
|---|---|
| A bank-like database `bank` | 10k customers, 25k accounts, 400k transactions, a partitioned audit table, practice tables for indexes, vacuum and locks, and a set of `ops.*` views that answer "what is going on?" |
| A Redis full of realistic keys | sessions, hashes, sorted sets, a stream, a queue, a huge key, keys with and without TTL |
| 15 drills | each breaks something real, with a measured result (failover time, lost writes) |
| A game day | a random failure you are not told about |
| A probe | an application writing to both databases that reports **RTO** and **RPO** |
| A live dashboard | `make watch` shows Postgres, Patroni, etcd, Redis, Sentinel and the probe at once |
| Optional Prometheus + Grafana | with the alerts a real team would have |
| Cheat sheets | the commands you will actually type, explained, in `docs/` |

## Start in five minutes

You need Docker (Colima, OrbStack or Docker Desktop) with about 4 GB of memory for it.

```sh
make up              # builds the Patroni image the first time; waits until everything is healthy
make seed            # loads the bank data into Postgres and the keys into Redis
make writer-start    # starts the probe (an app that keeps writing to both databases)
make watch           # live dashboard: keep it open in a second terminal
```

Then read **[docs/00-START-HERE.md](docs/00-START-HERE.md)**: the plan, how to practise, and the order of the drills.

## Everyday commands

| Command | What it does |
|---|---|
| `make watch` | live dashboard of the whole lab |
| `make status` | the same, once |
| `make shell` | a shell with `psql`, `patronictl` and `redis-cli` already pointed at the lab |
| `make psql` | `psql` on the primary (through HAProxy) |
| `make rcli` | `redis-cli` on the current Redis master |
| `make overview` | what is in the databases: tables, sizes, Redis keys by type |
| `make drill-01` … `make drill-15` | break something (read the drill's README first) |
| `make verify-01` … | check the result and see the numbers |
| `make report` | RTO / RPO from the probe |
| `make gameday` / `make gameday-reveal` | a random failure you must diagnose |
| `make heal` | put everything back after any drill |
| `make reset` | wipe all data and start from scratch |
| `make obs-up` | optional: Prometheus + Grafana (`http://localhost:3300`) |

## Ports on your machine

| | |
|---|---|
| `localhost:5440` | Postgres primary through HAProxy (`postgres` / `hagod-super`, database `bank`) |
| `localhost:5441` | Postgres replicas through HAProxy (read only) |
| `localhost:7100` | HAProxy statistics page |
| `localhost:8101-8103` | Patroni REST API of pg1, pg2, pg3 (`/patroni`, `/cluster`, `/primary`, `/replica`) |
| `localhost:6401-6403` | redis1, redis2, redis3 (password `hagod-redis`) |
| `localhost:26401-26403` | sentinel1, sentinel2, sentinel3 |
| `localhost:3300`, `localhost:9191` | Grafana, Prometheus (after `make obs-up`) |

(5000 and 7000 are taken by macOS AirPlay, and 9090 is often used by other tools, so the lab avoids them.)

## Layout

```
compose.yml            the lab
images/                Patroni image, HAProxy config, the probe
config/redis/          redis.conf and sentinel.conf
seed/                  the bank database and the Redis keys
scripts/               watch, status, heal, report, overview, game day
drills/NN-name/        README.md (the lesson), break.sh, verify.sh
docs/                  plan, architecture, command cheat sheets, runbooks, failure catalogue
obs/                   optional Prometheus, alerts, Grafana
```

## Safety

This is a lab. Passwords are in the files, `enable-debug-command` is on, and the network is wide open. Never copy the
configuration into production as it is; each setting that matters is explained in `docs/01-architecture.md`.
