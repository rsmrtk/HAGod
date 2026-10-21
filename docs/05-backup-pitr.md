# Backups and point-in-time recovery (PITR)

Replication is **not** a backup. A `DROP TABLE` or a bad `UPDATE` is replicated to every replica within milliseconds.
Only a **base backup plus the archived WAL** can take you back to "one second before the mistake".

```
 base backup (Monday 02:00)     WAL segments archived continuously
 ┌────────────────────┐   ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐
 │ copy of the files  │ + │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │ ...  every change since the backup
 └────────────────────┘   └───┴───┴───┴───┴───┴───┴───┴───┴───┘
                                          ▲
                              recovery_target_time = "just before the DROP"
```

Restore = copy the base backup, then **replay WAL** from the archive until the target moment, then stop and open for use.

## The three numbers

| | Meaning | In this lab |
|---|---|---|
| **RPO** (data you can lose) | time since the last archived WAL | `archive_timeout = 60` s at worst |
| **RTO** (time to be back) | time to copy the backup + replay WAL | measure it in drill 10, then extrapolate to your size |
| **Retention** | how far back you can go | as long as you keep backups **and** the WAL since the oldest one |

## What makes it work (all configured in `patroni.yml.tpl`)

```
wal_level = replica          # enough WAL for replication and PITR
archive_mode = on
archive_command = cmp -s %p /archive/%f || { cp %p /archive/%f.tmp && mv /archive/%f.tmp /archive/%f; }
archive_timeout = 60         # close a WAL segment at least every minute
restore_command = cp /archive/%f %p
```
- `%p` = path of the WAL file, `%f` = its name. The command must return **0 only if the file is safely stored.**
- Copy to a temporary name and `mv` so a half-written file is never seen by a restore.
- **Test the command.** A broken `archive_command` makes `pg_wal` fill the disk (`ops.archiver.failed_count`, drill 08).
- In production the target is S3/GCS/a backup server through pgBackRest, WAL-G or Barman, **not** `cp`. They add compression, encryption, retention, parallelism and verification. Learn one of them next.

## Steps

1. **Base backup** (here from a replica, so the primary is not burdened):
   ```sh
   pg_basebackup -h pg2 -p 5432 -U replicator -D /backup/base-1 -Fp -X stream -c fast -P
   ```
   `-X stream` includes the WAL needed to make the copy consistent. `-c fast` forces an immediate checkpoint.
2. Keep archiving. `select * from ops.archiver;` must show `failed_count` not growing.
3. **Note the moment before the mistake.** In real life that is the hard part: logs, application events, `pg_waldump`.
   You can also target a **transaction id** (`recovery_target_xid`), a **named restore point** (`select pg_create_restore_point('before_release')`) or an **LSN**.
4. **Restore into a separate server**, never over the live one (`drills/10-backup-and-pitr/restore.sh`):
   ```
   <data dir> = the base backup
   touch recovery.signal
   postgresql.auto.conf:
       restore_command = 'cp /archive/%f %p'
       recovery_target_time = '2026-10-18 12:30:00+00'
       recovery_target_action = 'promote'
   start postgres
   ```
   Watch its log for `starting point-in-time recovery to ...`, `restored log file ... from archive`, `recovery stopping before commit of transaction ...`, `archive recovery complete`.
5. **Take out only what you need** (`pg_dump -t core.transactions`) and load it into production. Do not switch production to the restored copy unless you must.

## Things that go wrong

| Problem | Why |
|---|---|
| `recovery ended before configured recovery target was reached` | the archive is missing WAL up to the target (a gap, or archiving was failing) |
| It recovers to a time that is too late/early | the target time is a clock moment: check timezones, and whether the DROP was before or after your timestamp |
| `could not open file ... No such file` for a WAL segment | `restore_command` path wrong, or segment was deleted by a retention job |
| Recovery is slow | WAL replay is single-threaded: a day of heavy WAL can take hours. Take more frequent base backups |
| The restored server will not start | wrong permissions (`chmod 700` on the data dir, owner `postgres`), or a stale `postmaster.pid` |
| After PITR you have a new timeline | expected: a recovered server starts a new timeline; it can no longer follow the old primary |

## A backup you have not restored is a hope

Put a **restore test** on a schedule: restore the latest backup to a scratch machine, run a row count and a few queries, record the time.
That time is your real RTO. Drill 10 does exactly this on the lab.

## Logical backups (`pg_dump`) vs physical

| | Physical (`pg_basebackup`, pgBackRest) | Logical (`pg_dump`) |
|---|---|---|
| Restore speed | fast (copy files) | slow (rebuild every index) |
| PITR | **yes** (with WAL) | no |
| Granularity | whole cluster | database/table |
| Cross-version | no | yes |
| Use for | disaster recovery | moving data, extracting one table, upgrades |
