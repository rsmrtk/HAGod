# Drill 02: Planned switchover

**Goal.** Move the primary on purpose, and compare with a crash.

## The story
You must patch the primary's host tonight. How do you move writes away with the least damage?

## Predict first (write it down)
- How long compared with drill 01? Why?
- Will the application notice at all?

## Run
```sh
make drill-02
make verify-02
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
patronictl list -W
docker logs pg1 2>&1 | grep -E "demot|release|promot|switchover" | tail
make report
```

## What you should see
About **3 s** for the command to finish and **~4 s** of failed writes from the application's point of view; `LOST WRITES: 0` is guaranteed here. Compare with ~25 s for a crash.

## Understand
A switchover is **cooperative**. Patroni first makes the old primary stop accepting writes and waits until the chosen replica has caught up completely, then **releases** the leader key on purpose. The candidate takes it immediately, nobody waits for a TTL, and no data can be lost because the replica had everything.

## Fix
Nothing to fix. Try the variants: choose the candidate (`--candidate pg3`), schedule it (`--scheduled "2026-10-20T03:00"`), cancel a scheduled one (`patronictl flush hagod switchover`).

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Why is a switchover so much faster and safer than a crash?
2. When would you use `failover` instead?
3. What must you check before any switchover?

---

### Answers (read after you tried)
1. The old primary hands over the lock itself and the replica is fully caught up, so there is no TTL wait and no loss.
2. Only when there is **no healthy leader** to hand over (the primary is gone and nothing took over automatically).
3. That all replicas are `streaming` with lag 0 (`patronictl list`) and that the candidate is not `nofailover`. Always read the confirmation prompt (do not use `--force` in production).
