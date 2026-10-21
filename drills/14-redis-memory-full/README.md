# Drill 14: Redis out of memory

**Goal.** See what noeviction and allkeys-lru really do, and what each costs.

## The story
A batch job loads data and Redis starts rejecting writes. Or worse, it quietly deletes data you needed.

## Predict first (write it down)
- What error will clients get?
- After you change the policy, what disappears?

## Run
```sh
make drill-14
make verify-14      # changes the policy, then reloads the training keys
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```
INFO memory
CONFIG GET maxmemory-policy
INFO stats          # evicted_keys
redis-cli --bigkeys
MEMORY USAGE bigkey:audit_blob
DBSIZE
```

## What you should see
With `noeviction` writes fail: `OOM command not allowed when used memory > 'maxmemory'`, and reads still work. After `allkeys-lru` writes succeed again but **thousands of existing keys are evicted** (`evicted_keys` rises): in the lab many of the training keys vanish and `make seed-redis` restores them.

## Understand
`noeviction` protects data and stops writes; `allkeys-lru` keeps writing and **silently deletes the least recently used keys, including ones you wanted**. `volatile-*` policies only delete keys with a TTL: safe for a cache/permanent mix, but then every cache key must have a TTL (look at `cache:rates:*`, which does not).

Also, `CONFIG SET` is lost on restart unless you `CONFIG REWRITE`, and on a failover the new master has **its own** configuration.

## Fix
Use the right policy for the workload, put TTLs on cache keys, find the big keys, size `maxmemory` for the data plus replication buffers, and put queue-like data on a separate Redis.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Which policy for (a) a session cache (b) a queue of payments (c) a rate limiter?
2. What happens to the limit after a failover?
3. Why is memory for replication counted too?

---

### Answers (read after you tried)
1. (a) `allkeys-lru` or `volatile-lru` with TTLs; (b) `noeviction` on its own instance; (c) `volatile-ttl` or `allkeys-lru` (counters expire anyway).
2. The new master uses **its own** config; if you changed it only with `CONFIG SET` on the old master, it is gone. Put it in `redis.conf` on every node (and `CONFIG REWRITE`).
3. Replica output buffers and the replication backlog live in the master's memory; a slow replica can make them grow (`client-output-buffer-limit replica`).
