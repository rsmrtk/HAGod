# Progress and scoreboard

Copy a row each time you finish a drill. Numbers beat feelings.

## Drill log

| Drill | Date | My prediction | What happened (numbers) | Did I fix it without the README? | Runbook written |
|---|---|---|---|---|---|
| 01 kill primary | | | failover ___ s, lost ___ writes | | |
| 02 switchover | | | ___ s total, client down ___ s | | |
| 03 etcd quorum | | | writes stopped after ___ s | | |
| 04 partition primary | | | new primary after ___ s | | |
| 05 async | | | lost ___ acknowledged writes | | |
| 05 strict | | | lost ___, writes blocked for ___ s | | |
| 06 replication lag | | | lag ___ MB, caught up in ___ s | | |
| 07 rebuild replica | | | ___ s for ___ MB | | |
| 08 WAL / slot | | | pg_wal ___ → ___ | | |
| 09 locks | | | found blocker in ___ s | | |
| 10 PITR | | | restore took ___ s, rows ___ / ___ | | |
| 11 Redis master kill | | | failover ___ s, lost ___ | | |
| 12 Sentinel quorum | | | stuck for ___ s | | |
| 13 split brain plain | | | lost ___ | | |
| 13 split brain protected | | | lost ___, refused ___ | | |
| 14 Redis OOM | | | | | |
| 15 slow command | | | failover after ___ s | | |

## Game days

| # | Date | Failure (revealed after) | Time to diagnose | Time to fix | What I missed |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |

Target: diagnose any game-day failure in under 3 minutes using only `make watch`, `patronictl list`, `psql`, `redis-cli`.

## Skills checklist

Postgres / Patroni
- [ ] I can explain why failover takes ~25 s and switchover ~3 s
- [ ] I know what happens when etcd is lost, and why it is a feature
- [ ] I can find replication lag in bytes and seconds, on the primary and on a replica
- [ ] I can find what is blocking a query and stop it safely
- [ ] I can find out why `pg_wal` is growing (slot / archive / lag) and fix each
- [ ] I can restore a dropped table with PITR, and I know how long it takes
- [ ] I can change a setting the Patroni way and know if it needs a restart
- [ ] I can read `EXPLAIN (ANALYZE, BUFFERS)` and choose an index
- [ ] I can vacuum, and I know why `VACUUM FULL` is dangerous
- [ ] I know the difference between sync, async and strict, and what each costs

Redis / Sentinel
- [ ] I can explain quorum vs majority
- [ ] I can find the master, the replicas and their lag without a dashboard
- [ ] I know why `KEYS *` is forbidden and what to use
- [ ] I know the eviction policies and which workload each suits
- [ ] I can explain how a split brain loses writes and how to limit it
- [ ] I can read a Sentinel log and tell the story of a failover
- [ ] I can find the biggest keys and explain what to do about them
- [ ] I know RDB vs AOF and what each loses on a crash

Habits
- [ ] I predict before I break
- [ ] I write the runbook
- [ ] I check for exactly one primary / master before anything else
