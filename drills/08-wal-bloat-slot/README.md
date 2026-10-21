# Drill 08: pg_wal fills the disk

**Goal.** Recognise the two classic causes of a full WAL directory: an orphan replication slot and a failing archive_command.

## The story
2 a.m.: disk at 95% on the primary and growing. Application writes still work. How do you find the cause before Postgres stops?

## Predict first (write it down)
- Where do you look first?
- Which object is responsible, and is it safe to remove?

## Run
```sh
make drill-08
make verify-08
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
select * from ops.slots;            -- an inactive slot with a big wal_retained
select * from ops.archiver;         -- failed_count growing? last_failed_wal?
docker exec pg1 du -sh /var/lib/postgresql/data/pgdata/pg_wal
docker exec pg1 ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status | grep -c ready
df -h                                -- on a real host
```

## What you should see
`orphan_slot` shows `active = f` with **gigabytes** in `wal_retained`, and `pg_wal` grows several times its normal size. Patroni does **not** remove it (it only manages the slots for its own members). Dropping it frees the WAL at the next checkpoint.

## Understand
A replication slot makes the primary keep every WAL segment the slot's consumer has not yet confirmed, **forever**. If the consumer is dead (a removed replica, a stopped logical-decoding tool, a forgotten test), the WAL never goes away. The other classic cause is `archive_command` failing: segments wait for archiving, the `.ready` files accumulate and `pg_wal` swells (it happened to this lab while it was built: `cmp ... && mv` bug; `ops.archiver.failed_count` showed it).

`max_slot_wal_keep_size` caps what a slot may retain: past that, the slot is invalidated instead of filling the disk (then its consumer must be rebuilt).

## Fix
```sql
select pg_drop_replication_slot('orphan_slot');
checkpoint;
```
Then make sure monitoring alerts on inactive slots and on `failed_count` (`obs/alerts.yml` has both). Set `max_slot_wal_keep_size` to what your disk can bear.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. Why did Patroni not drop the orphan slot?
2. What limits how much WAL a slot can hold, and what does it cost when it triggers?
3. Write the alert.

---

### Answers (read after you tried)
1. Patroni manages only the slots it creates for cluster members (and ones you declare in its `slots:` config). A slot created by hand is outside its scope.
2. `max_slot_wal_keep_size`. When exceeded, the slot is marked lost and its consumer (a replica or a CDC tool) can no longer resume; it must be rebuilt: protecting the primary's disk beats keeping a stale consumer.
3. `pg_replication_slots_active == 0` for 1 minute, and a slot retaining more than N GB (N = a safe fraction of free disk), plus `increase(pg_stat_archiver_failed_count[2m]) > 0`.
