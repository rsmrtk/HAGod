# Runbook template (and one filled in)

A runbook is for **tired you at 3 a.m.** Short, ordered, with the exact commands, and a clear "stop and escalate" line.
Write one after every drill. If you cannot write it in half a page, you did not understand the failure yet.

```
# <Name of the problem, as an alert or a symptom would say it>

## Symptom
What do you see? (alert name, error message, dashboard)

## First, confirm (30 seconds, read-only)
1. command  → what a BAD result looks like
2. command  → ...

## Why this usually happens
One or two lines.

## Fix
1. command            (state what it changes)
2. command
Expect: how you know it worked.

## Do NOT
- the tempting wrong move, and why

## Escalate when
- the situation in which you stop and call someone

## After
- what to check tomorrow, what to improve so it does not recur
```

---

## Example: "Postgres has no primary: writes fail" (from drills 01, 03, 04)

### Symptom
`PatroniNoLeader` alert, or the application logs `connection refused` / `read-only transaction` on port 5000. `patronictl list` shows no `Leader`.

### First, confirm
1. `patronictl list` → **no Leader row**, or all members `Replica`.
2. `docker exec etcd1 etcdctl endpoint health --cluster` → **any "unhealthy" / fewer than 2 healthy.** If so this is an *etcd* problem, not a Postgres problem: go to "etcd" below.
3. `docker logs pg1 2>&1 | grep -E "demoting|lost|DCS" | tail -5` → `demoting self because DCS is not accessible` confirms it.
4. `curl -s localhost:8101/patroni | jq .state` for each node → is Postgres running on any of them?

### Why this usually happens
(a) The primary died or was cut off: wait up to `ttl` (30 s), a replica should be promoted by itself. (b) etcd lost its quorum: Patroni demotes the primary **on purpose**.

### Fix
- **If less than 40 s since the failure and etcd is healthy: wait. Do nothing.** A premature manual failover is the usual cause of data loss.
- etcd down: restore etcd first (`docker start etcd2 etcd3` here; on real hosts, start the member and read its log). Patroni recovers on its own within one `loop_wait`.
- etcd healthy but no leader for > 60 s and a replica is streaming with 0 lag: `patronictl failover --candidate pg2`. Read the confirmation prompt.
- A node shows `start failed`: see "replica will not start".

### Do NOT
- Do not `pg_ctl promote` by hand on a Patroni node: Patroni and Postgres disagree and you get two primaries.
- Do not run `patronictl failover` while the old primary may still be alive and reachable by clients (you create a split brain).
- Do not restart etcd members all at once.

### Escalate when
etcd has lost data (members do not agree), or two nodes both claim to be primary, or the only up-to-date node is the one that will not start.

### After
`patronictl history` for the timeline; `make report` equivalent from your monitoring for the outage window; check the old primary rejoined (`patronictl list`: all `streaming`).
