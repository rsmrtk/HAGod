# Drill 12: Lose the Sentinel quorum

**Goal.** Understand why Sentinel can see the master is down and still do nothing.

## The story
A maintenance mistake stops two of the three sentinels, and later the Redis master fails.

## Predict first (write it down)
- Will the surviving sentinel fail over alone?
- What does it say about the master?

## Run
```sh
make drill-12
make verify-12
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
redis-cli -h sentinel1 -p 26379 sentinel master mymaster      # flags: s_down (not o_down)
redis-cli -h sentinel1 -p 26379 sentinel ckquorum mymaster    # NOQUORUM ... not enough to reach the majority
docker logs sentinel1 2>&1 | tail
```

## What you should see
The master is flagged **`s_down`** by the one sentinel, never `o_down`, and **no failover happens** while the other sentinels are down. `CKQUORUM` reports `NOQUORUM 1 usable Sentinels`. Once the sentinels return, the failover completes within seconds and the total outage is the time you took to fix them.

## Understand
Two different thresholds: the **quorum** (2) is how many sentinels must agree the master is down; but to actually fail over, one sentinel must be **authorised by a majority of all known sentinels** (2 of 3). With one sentinel left neither is reachable. Lowering the quorum to 1 would not help: the majority rule still needs 2.

## Fix
Bring sentinels back; never run production with fewer than 3 (on different hosts). Monitor the **sentinel count**, not only the Redis master.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. With 3 sentinels and quorum 2, how many can you lose? With 2 sentinels? With quorum 1?
2. Why should sentinels be on separate machines from each other, and not only with the Redis nodes?
3. What would you alert on?

---

### Answers (read after you tried)
1. Lose 1 of 3. With 2 sentinels you cannot lose any (majority is 2). Quorum 1 does not change the majority needed to authorise the failover.
2. So one host failure takes out at most one sentinel; if sentinels share a host with a Redis node, losing that host removes both the master and a guard.
3. `SENTINEL CKQUORUM` not OK, fewer than 3 known sentinels, a sentinel flagged `s_down`.
