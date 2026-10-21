# Drill 05: Async vs synchronous replication

**Goal.** Measure, in lost writes, what asynchronous replication really costs, and what strict synchronous mode costs instead.

## The story
The business asks: "can we ever lose a payment that was confirmed to the customer?" You need to answer with numbers, not opinions.

## Predict first (write it down)
- Async: how many acknowledged writes will be missing afterwards?
- Strict: how many, and what does the application experience instead?

## Run
```sh
./drills/05-async-vs-sync/break.sh async     # then make verify-05
make heal
./drills/05-async-vs-sync/break.sh strict    # then make verify-05
```
The script cuts the replicas off, lets the app write for 20 s, kills the primary, and reconnects the replicas.

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
patronictl list                       # Role: Sync Standby in strict mode
patronictl show-config | grep -i sync
select application_name, state, sync_state from pg_stat_replication;     # sync / async / potential
show synchronous_standby_names;
make report
```

## What you should see
**Async: about 100 acknowledged writes lost** (everything written during the 20 s the replicas could not receive WAL). **Strict: 0 lost**, but during the cut the writes **block** (no commit finishes) and then fail: availability is traded for safety. After the failover the cluster returns to normal.

## Understand
Asynchronous replication means the primary confirms a commit as soon as it is on **its own** disk. If it dies before the replica receives the WAL, that commit is gone. Synchronous replication waits for a standby. Patroni has three levels: **async** (default); **`synchronous_mode`** (prefers a sync standby, but if none is available it quietly goes back to async to stay available: so it can still lose data); and **`synchronous_mode_strict`** (never acknowledge without a standby: no loss, but writes stop when the standby is gone).

Only a **synchronous standby** can be promoted in sync mode, which is what makes the no-loss promise hold.

## Fix
`make heal` resets sync settings. In real life, settle on a policy with the business, write it in the runbook, and monitor `sync_state`.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Which is worse for a bank: a few seconds of failed writes, or a few lost confirmed payments? Who decides?
2. What does non-strict `synchronous_mode` do when the standby disappears, and so does it guarantee no loss?
3. What would you alert on?

---

### Answers (read after you tried)
1. Usually lost confirmed payments is worse; that is a business and risk decision, recorded in writing. Many banks choose strict or `remote_apply` for core ledgers and accept the availability cost.
2. It falls back to async to keep the service available, so it does **not** guarantee zero loss during that window. Only strict guarantees it.
3. Number of sync standbys < 1, `sync_state` not `sync`, replication lag, and `pg_stat_replication` rows missing.
