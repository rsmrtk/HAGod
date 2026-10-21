# Drill 09: Locks and a forgotten transaction

**Goal.** Find the blocker, not the victims, and stop it safely.

## The story
The application "hangs". Connections climb. CPU is idle. Someone has a transaction open somewhere.

## Predict first (write it down)
- Which of the three sessions is the root cause?
- What would happen if you killed the one that is waiting the longest?

## Run
```sh
make drill-09
# investigate by hand in make psql, then:
make verify-09
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sql
select * from ops.blocked;                      -- who waits for whom, and for how long
select * from ops.activity;                     -- note state = 'idle in transaction'
select pid, state, now()-xact_start as xact_age, query from pg_stat_activity where state='idle in transaction';
select * from pg_locks where not granted;       -- the raw lock table
```

## What you should see
Session A holds a row lock in an `idle in transaction` state; B waits for that row; C waits for a table lock behind them. `ops.blocked` shows `blocking_pid` pointing at A (and C also waiting on B). Terminating A releases everyone.

## Understand
A transaction that is open and idle holds its locks and its snapshot until it ends. Anything that needs a conflicting lock queues behind it, and **everything queues behind the queue** (a pending table lock blocks new readers too). Killing the longest *waiter* changes nothing; you must remove the **blocker at the root of the chain**.

An old open transaction also stops VACUUM from removing dead rows newer than it, so tables bloat while it exists.

## Fix
```sql
select pg_terminate_backend(<blocking_pid>);     -- the root blocker; pg_cancel_backend only cancels a running query, not an idle transaction
```
Prevent it: `idle_in_transaction_session_timeout` (e.g. 60 s), `lock_timeout`, and fix the application (always commit/rollback, short transactions). On Patroni set them with `patronictl edit-config`.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Which session was the real problem and which were victims?
2. Why is `pg_cancel_backend` not enough here?
3. What else does an old open transaction break?

---

### Answers (read after you tried)
1. A (the idle transaction). B and C only waited.
2. A is idle: there is no running query to cancel; the open transaction itself must be ended, so you terminate the backend.
3. VACUUM cannot clean dead tuples newer than its snapshot (bloat), replicas can get query conflicts, and it can hold back `xmin` for the whole cluster.
