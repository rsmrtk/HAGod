# Drill 15: A slow command causes a failover

**Goal.** Learn that a healthy but busy Redis can be declared dead.

## The story
Someone runs an expensive command on the master. Nothing is wrong with the machine. A few seconds later there is a failover.

## Predict first (write it down)
- Will Sentinel fail over? Is the process down?
- What will the old master do when the command ends?

## Run
```sh
make drill-15
make verify-15
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
docker logs sentinel1 2>&1 | grep -E "sdown|odown|switch-master"
redis-cli -h <old master> slowlog get 3
redis-cli -h <old master> latency latest
```

## What you should see
After ~**5-7 s** the sentinels log `+sdown`, `+odown`, and `+switch-master`: **a failover happened for a process that was never down.** The old master, when it wakes, is demoted to a replica. The slow log records the 8 s command.

## Understand
Redis runs commands on a single thread. While it executes one slow command it answers nobody, including Sentinel's `PING`. After `down-after-milliseconds` (5 s) the sentinels cannot tell "busy" from "dead", so they fail over. Real-life triggers: `KEYS *`, `SMEMBERS` or `HGETALL` of a huge key, `DEL` of a huge key (use `UNLINK`), a slow Lua script, `SAVE`, or the machine freezing.

## Fix
Remove the cause: use `SCAN`, `UNLINK`, `SSCAN`/`HSCAN`; keep scripts short; alert on `slowlog`; tune `down-after-milliseconds` to be longer than your slowest legitimate command; restrict dangerous commands with ACLs.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. How would you prevent this class of incident?
2. What do you gain and lose by setting `down-after-milliseconds` to 20 s?
3. Which alert would warn you before it happens?

---

### Answers (read after you tried)
1. Ban `KEYS`/`FLUSH*` for application users (ACL), use incremental commands, `UNLINK`, and watch the slowlog.
2. Fewer false failovers, but a real crash takes 20 s+ to detect (compare drill 11).
3. A growing `slowlog_length`, `latency` events, and `instantaneous_ops_per_sec` dropping to 0 while the process is alive.
