# Drill 03: Lose etcd

**Goal.** Understand that Patroni depends on its DCS and what happens when the DCS is gone.

## The story
A rack outage takes down two of the three etcd hosts. Postgres is running fine on all three database hosts. What does the application see?

## Predict first (write it down)
- Does the primary keep serving writes?
- Does a replica get promoted?
- Is any data lost?

## Run
```sh
make drill-03        # stops etcd2 and etcd3
make verify-03       # shows the state, then restores etcd
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
docker exec etcd1 etcdctl endpoint health --cluster     # unhealthy: no quorum
patronictl list                                          # hangs or errors: it reads from etcd
for p in 8101 8102 8103; do curl -s localhost:$p/patroni | jq -c '{role,state}'; done   # every node says: replica
docker logs pg1 2>&1 | grep -iE "DCS|demot|failsafe" | tail    # the reason, in Patroni's words
```

## What you should see
**All three nodes become read-only replicas within about a `ttl`**, and writes fail. Postgres processes are still running and no data is lost. When etcd is back, the previous primary takes the lock again and writes resume, usually without a new timeline.

## Understand
Patroni's rule: *a primary must prove it still owns the lock.* Without etcd it cannot, so it demotes itself to avoid the chance of a second primary appearing on the other side. The cost is that **an etcd outage is a database outage**. That is why etcd must run on separate, reliable hosts and be monitored first.

Patroni has `failsafe_mode`: if all members can still reach each other directly, the primary may keep running without the DCS. Try it: `patronictl edit-config --force -s failsafe_mode=true`, then repeat the drill and compare.

## Fix
Restore etcd quorum (`docker start etcd2 etcd3`). Then confirm one leader, replicas streaming. Think about what you would have done in production if etcd data were lost (restore from an etcd snapshot: `etcdctl snapshot save/restore`).

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Why does a healthy Postgres go read-only?
2. What does `failsafe_mode` change and what risk does it add?
3. How many etcd members can you lose out of 3? Out of 5? Out of 2?

---

### Answers (read after you tried)
1. To guarantee there is never more than one primary: no lock, no writes.
2. The primary keeps serving as long as it can still talk to the other Patroni members directly. The risk: if the real cause is a partition, you rely on those direct links to decide, which is weaker than a consensus store.
3. Out of 3: one. Out of 5: two. Out of 2: none (and 2 is worse than 1: either failure loses quorum). Always use an odd number.
