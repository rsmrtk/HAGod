# PostgreSQL administration on the lab data

Open a session: `make psql` (database `bank`, on the primary). Everything below runs there unless it says otherwise.
Prompt shows `hagod bank=#`; timing is on, `\x auto` switches to vertical output when rows are wide.

> Convention: lines starting with `\` are psql meta-commands (not SQL); SQL ends with `;`.

## 1. Look around

| Command | Shows |
|---|---|
| `\conninfo` | who and where you are connected (via HAProxy → which node?) |
| `\l+` | databases and their sizes |
| `\c bank` | switch database |
| `\dn+` | schemas (`core`, `audit`, `practice`, `ops`) |
| `\dt+ core.*` | tables with size |
| `\d+ core.transactions` | columns, indexes, constraints, size, partitions |
| `\di+ core.*` | indexes with size |
| `\df ops.*` / `\dv ops.*` | functions / views |
| `\du` | roles |
| `\dx` | extensions (`pg_stat_statements`) |
| `\x` | toggle vertical output |
| `\timing` | toggle timing of every query |
| `\watch 2` | repeat the previous query every 2 s (a poor man's dashboard) |
| `\e` | edit the last query in your editor |
| `\?` / `\h UPDATE` | help for psql / for SQL syntax |

**Exercise 1.** Which three tables are the biggest, and how much of each is index?
```sql
select * from ops.table_sizes limit 5;
```
`core.transactions` has 400k rows and ~32 MB of indexes: indexes are half its size. Every index slows writes and costs disk, so you only keep the ones queries use (section 3).

**Exercise 2.** Which node am I on, and am I the primary?
```sql
select * from ops.node;
select inet_server_addr(), pg_is_in_recovery();
```
Run it through the replicas port too: `docker exec tools psql -h haproxy -p 5001 -d bank -c "select * from ops.node"`. The role says `REPLICA`; a write attempt gives `ERROR: cannot execute INSERT in a read-only transaction`.

## 2. Is replication healthy?

On the **primary**:
```sql
select * from ops.replication;                  -- each replica: state, sync/async, lag in bytes and time
select * from ops.slots;                        -- slots and how much WAL each retains
select pg_current_wal_lsn();                    -- where the primary has written to
select * from pg_stat_replication;              -- the raw view (more columns: sent_lsn, write_lsn, flush_lsn, replay_lsn)
```
On a **replica** (through `docker exec -e PGPASSWORD=hagod-super pg2 psql -h localhost -U postgres -d bank`):
```sql
select pg_is_in_recovery();                                                    -- true
select pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();                    -- received vs applied
select now() - pg_last_xact_replay_timestamp() as replay_delay;                 -- how stale are my reads (only meaningful if writes happen)
select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());    -- bytes received but not applied
select * from pg_stat_wal_receiver;                                            -- the connection to the primary
```

Reading the lag columns (`ops.replication`): `write_lag` = replica got it in memory, `flush_lag` = on its disk, `replay_lag` = visible to queries.
A growing gap between flush and replay = replay is paused or blocked by a long query on the replica (drill 06).

Timeline: `select timeline_id from pg_control_checkpoint();`. It goes up by one on every promotion; after a failover all nodes must be on the new one.

## 3. A slow query (indexes and EXPLAIN)

`practice.slow_orders` has 300,000 rows and **no index on `status`**.

```sql
explain (analyze, buffers) select count(*) from practice.slow_orders where status = 'paid';
```
Look for: `Seq Scan` (reads the whole table), `Rows Removed by Filter`, `Execution Time`, `Buffers: shared hit/read`.

Fix it and compare:
```sql
create index concurrently slow_orders_status_idx on practice.slow_orders(status);   -- CONCURRENTLY: no write lock (cannot run inside a transaction)
explain (analyze, buffers) select count(*) from practice.slow_orders where status = 'paid';
```
You will probably still see a scan: `status` has only 5 values, so 20% of the table matches and the planner reads most of it anyway.
A selective query is where the index wins:
```sql
explain (analyze) select * from practice.slow_orders where id = 123456;             -- primary key: Index Scan, ~0.05 ms
create index slow_orders_cust_idx on practice.slow_orders(customer, created_at desc);
explain (analyze) select * from practice.slow_orders where customer = 42 order by created_at desc limit 10;
```
Lessons: indexes help **selective** predicates; `ANALYZE` keeps the statistics fresh; an index you never use only costs writes.

Find unused indexes:
```sql
select relname as "table", indexrelname as index, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) as size
from pg_stat_user_indexes order by idx_scan, pg_relation_size(indexrelid) desc limit 10;
```

What is the database spending its time on?
```sql
select * from ops.top_queries;                              -- needs pg_stat_statements (installed in seed)
select pg_stat_statements_reset();                          -- reset to measure from now
```
`total_ms` finds the queries costing the most overall; `mean_ms` the slowest each time. Often the top query is a fast one run a million times.

## 4. Vacuum and bloat

Postgres never overwrites a row: `UPDATE`/`DELETE` leave the old version (a *dead tuple*) until `VACUUM` removes it.
`practice.bloat_demo` has autovacuum **off** and 40% dead rows.
```sql
select * from ops.dead_tuples limit 5;                        -- dead_pct ~ 40 for practice.bloat_demo
select pg_size_pretty(pg_total_relation_size('practice.bloat_demo'));      -- size now
vacuum (verbose, analyze) practice.bloat_demo;                -- removes dead tuples, makes space reusable, updates stats
select * from ops.dead_tuples limit 3;                         -- dead = 0
select pg_size_pretty(pg_total_relation_size('practice.bloat_demo'));      -- same size: plain VACUUM does not shrink the file
vacuum full practice.bloat_demo;                              -- rewrites the table: shrinks it, but LOCKS the table exclusively
```
Never run `VACUUM FULL` on a hot production table. Use `pg_repack` (an extension) for online compaction.

Autovacuum in practice:
```sql
select relname, last_autovacuum, last_autoanalyze, n_dead_tup from pg_stat_user_tables order by n_dead_tup desc limit 5;
show autovacuum_vacuum_scale_factor;                          -- 0.2 = vacuum when 20% of the table is dead; too lazy for huge tables
alter table core.transactions set (autovacuum_vacuum_scale_factor = 0.02);    -- per-table tuning
select pid, query_start, left(query,60) from pg_stat_activity where query like 'autovacuum:%';   -- running now
```
**An old open transaction blocks vacuum from cleaning anything newer than itself.** If `dead_pct` keeps rising although autovacuum runs, look for `idle in transaction` sessions (section 5).

## 5. Sessions, locks, long transactions

```sql
select * from ops.activity;                 -- all client sessions: state, how long the transaction/query has run, what they wait for
select * from ops.blocked;                  -- who waits for whom (empty = good)
select state, count(*) from pg_stat_activity where backend_type='client backend' group by 1;    -- how many active / idle / idle in transaction
```
States: `active` (running), `idle` (waiting for the client), **`idle in transaction`** (a transaction is open and holding locks and snapshots;
the application forgot to commit: the worst kind).

Stop a session:
```sql
select pg_cancel_backend(1234);      -- polite: cancels the current query, session stays
select pg_terminate_backend(1234);   -- rude: closes the session and rolls back its transaction
```
Prevent it (cluster-wide, the Patroni way):
```sh
patronictl edit-config --force -s postgresql.parameters.idle_in_transaction_session_timeout=60000 \
                              -s postgresql.parameters.lock_timeout=10000 \
                              -s postgresql.parameters.statement_timeout=0
```
`log_lock_waits = on` is already set: `docker logs pg1 | grep "still waiting"` shows lock waits longer than `deadlock_timeout` (1 s).

Try the lock drill yourself without the script:
```sql
-- session 1 (make psql)
begin; update practice.locks_demo set owner='me' where id=1;     -- and now do not commit
-- session 2 (a second terminal, make psql)
update practice.locks_demo set owner='you' where id=1;            -- hangs
-- session 3
select * from ops.blocked;
```
Then `rollback;` in session 1.

## 6. WAL, checkpoints, archiving

```sql
select pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());       -- where am I in the WAL, which file
select * from ops.archiver;                                                -- is archiving working? failed_count should not grow
select pg_switch_wal();                                                    -- close the current segment now (forces archiving)
checkpoint;                                                                -- flush dirty pages to disk, allow old WAL to be recycled
select * from pg_stat_bgwriter;  select * from pg_stat_checkpointer;     -- checkpoint frequency (too many "requested" = max_wal_size too small)
show max_wal_size; show wal_keep_size; show archive_command;
```
Disk side:
```sh
docker exec pg1 du -sh /var/lib/postgresql/data/pgdata/pg_wal      # how big is the WAL directory
docker exec pg1 ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status | grep -c ready    # waiting to be archived: should be ~0
```
`pg_wal` grows when: (a) an inactive replication slot retains it (drill 08), (b) `archive_command` fails (`ready` files pile up, `ops.archiver.failed_count` grows),
(c) a replica is far behind and `wal_keep_size` is large. Know all three.

## 7. Configuration

```sql
show shared_buffers;                                        -- one parameter
select name, setting, unit, source, pending_restart from pg_settings where name like 'wal%' order by name;   -- many, with where they came from
select name, setting, sourcefile from pg_settings where source = 'configuration file';
select * from pg_file_settings where error is not null;     -- syntax errors in config files
```
`pending_restart = true` means a restart is needed for it to apply. On a Patroni cluster change settings with `patronictl edit-config` (docs/02).

## 8. Backup and recovery tools (command line)

| Tool | Does | Example |
|---|---|---|
| `pg_basebackup` | a physical copy of the whole cluster | `pg_basebackup -h pg2 -p 5432 -U replicator -D /backup/b1 -Fp -X stream -c fast -P` |
| `pg_dump` | a logical copy of one database/table (SQL or custom format) | `pg_dump -h haproxy -U postgres -d bank -t core.accounts -Fc -f /tmp/accounts.dump` |
| `pg_restore` | loads a custom-format dump | `pg_restore -h haproxy -U postgres -d bank --clean --if-exists -t accounts /tmp/accounts.dump` |
| `pg_rewind` | repairs a diverged old primary so it can follow the new one | Patroni runs it for you (`docker logs pg1 \| grep rewind`) |
| `pg_controldata` | the cluster's control file: timeline, last checkpoint, state | `docker exec pg1 pg_controldata /var/lib/postgresql/data/pgdata` |
| `pg_waldump` | read WAL records | `docker exec pg1 pg_waldump -n 5 /var/lib/postgresql/data/pgdata/pg_wal/<segment>` |
| `pg_isready` | is the server accepting connections | `pg_isready -h haproxy -p 5000` |

Physical backup + WAL archive = point-in-time recovery (docs/05, drill 10). A logical dump is for moving data, not for fast disaster recovery.

## 9. Users and privileges

```sql
\du+
create role reporting login password 'x' connection limit 5;
grant usage on schema core to reporting;
grant select on all tables in schema core to reporting;
alter default privileges in schema core grant select on tables to reporting;     -- future tables too
revoke all on schema core from reporting;
select grantee, table_schema, table_name, privilege_type from information_schema.role_table_grants where grantee='reporting' limit 5;
```
`pg_hba.conf` decides **who may connect from where** (here it is generated by Patroni, in etcd: `patronictl show-config`, key `postgresql.pg_hba`).
`select * from pg_hba_file_rules;` shows what is in effect.

## 10. Habits that prevent outages

1. `begin;` before any manual `UPDATE`/`DELETE`; check the row count; only then `commit;`.
2. Write `where` first, then the verb. `delete from x where …` typed backwards is how tables get emptied.
3. `create index concurrently`, `alter table … add column` without a default (or with one on PG11+), never `vacuum full` in business hours.
4. Run big changes on a replica clone or with `lock_timeout` set so a blocked `ALTER` does not queue everything behind it.
5. Know your restore time before you need it.
6. Do not run `pg_ctl`, `systemctl restart postgresql` or edit config files on a Patroni node. Use `patronictl`.

## Exercises (answers are in your own output)

1. How much WAL does the primary generate when you update 100k rows? (Measure `pg_current_wal_lsn()` before/after; use `pg_wal_lsn_diff`.)
2. Make `ops.dead_tuples` show the biggest offender; vacuum it; prove with `pg_total_relation_size` what a plain vacuum does and does not do.
3. Reproduce a deadlock with two sessions updating rows 1 and 2 in opposite order. Find it in `docker logs pg1`. What did Postgres do?
4. Make a replica serve stale reads: `select pg_wal_replay_pause();` on it, write on the primary, read from `:5441`. Resume it.
5. Find the three most expensive queries after running `docker exec tools psql -d bank -c "select count(*) from core.transactions t join core.accounts a on a.id=t.account_id"` ten times.
