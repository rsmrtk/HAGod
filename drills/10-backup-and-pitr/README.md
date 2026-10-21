# Drill 10: Backup and point-in-time recovery

**Goal.** Restore a dropped table to one moment before the mistake, without taking production down.

## The story
Someone drops `core.transactions` in production. The DROP replicates to every replica instantly. How do you get the data back, and how fast?

## Predict first (write it down)
- Will the replicas help? (No: write down why.)
- How many rows should the restored table have?
- How long will the restore take?

## Run
```sh
make drill-10                                  # backup, more writes, then the DROP
./drills/10-backup-and-pitr/restore.sh         # PITR into a throwaway server named 'pitr'
make verify-10                                 # compare row counts; optionally copy the table back
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
select to_regclass('core.transactions');                 -- NULL: gone
docker exec tools ls /backup /archive | tail             # the base backup and the archived WAL
docker logs pitr 2>&1 | grep -E "recovery|restored log file|stopping"   # PITR in progress
docker exec pitr psql -h localhost -U postgres -d bank -c "select count(*) from core.transactions"
```

## What you should see
The restored server stops **just before the DROP** and has exactly the row count recorded at the last good moment. You copy the table back with `pg_dump | psql` and production never stopped. The restore took seconds here because the data is small: **measure it and extrapolate to your size**; that is your real RTO.

## Understand
PITR = a physical base backup + the continuous WAL archive. Postgres restores the files, then **replays archived WAL** (`restore_command`) until `recovery_target_time`, then promotes. Your achievable RPO is how recent the last archived WAL is (here `archive_timeout = 60` s); RTO is copy time + replay time.

A delayed replica (`recovery_min_apply_delay`) is another protection against human error, but it is not a substitute for backups.

## Fix
Restore into a **separate** server, extract only the damaged object, put it back. Switching production to the restored copy is the last resort.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. What is your real RPO for this kind of mistake?
2. How long did the restore take? Extrapolate to your production size.
3. What does the archive need to contain? What if one segment is missing?
4. How would you test restores automatically?

---

### Answers (read after you tried)
1. The time between the last archived WAL and the mistake, plus how quickly you **notice** and find the right target time. Often the noticing dominates.
2. Copy time of the base backup (size / throughput) + WAL replay time (single-threaded, can be long for a busy day). Measure with a real-size restore.
3. Every segment from the base backup's start to the target. A gap stops recovery at the gap (`recovery ended before configured recovery target`).
4. A scheduled job restores the newest backup to a scratch host, runs sanity queries, records the duration, alerts on failure.
