-- Views that answer "what is going on?". Start every investigation here.
-- Use them like tables:  SELECT * FROM ops.replication;

CREATE OR REPLACE VIEW ops.node AS          -- who am I, am I the primary, which timeline
SELECT inet_server_addr() AS server,
       CASE WHEN pg_is_in_recovery() THEN 'REPLICA' ELSE 'PRIMARY' END AS role,
       (SELECT timeline_id FROM pg_control_checkpoint()) AS timeline,
       CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END AS lsn,
       pg_postmaster_start_time() AS started_at,
       now() - pg_postmaster_start_time() AS uptime;

CREATE OR REPLACE VIEW ops.replication AS   -- on the PRIMARY: every replica and how far behind it is
SELECT application_name AS replica, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication ORDER BY application_name;

CREATE OR REPLACE VIEW ops.slots AS         -- replication slots and the WAL each one makes the primary keep
SELECT slot_name, slot_type, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
       wal_status
FROM pg_replication_slots ORDER BY slot_name;

CREATE OR REPLACE VIEW ops.activity AS      -- who is connected and what are they doing
SELECT pid, usename AS user, application_name AS app, client_addr, state,
       wait_event_type || ':' || wait_event AS waiting_on,
       now() - xact_start AS xact_age, now() - query_start AS query_age,
       left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
ORDER BY query_start;

CREATE OR REPLACE VIEW ops.blocked AS       -- who waits for whom (empty = no lock trouble)
SELECT blocked.pid AS blocked_pid, now() - blocked.query_start AS waiting_for,
       left(blocked.query, 60) AS blocked_query,
       blocking.pid AS blocking_pid, blocking.state AS blocking_state,
       left(blocking.query, 60) AS blocking_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
JOIN pg_stat_activity blocking ON blocking.pid = b.pid;

CREATE OR REPLACE VIEW ops.table_sizes AS
SELECT n.nspname AS schema, c.relname AS "table", c.reltuples::bigint AS approx_rows,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY pg_total_relation_size(c.oid) DESC;

CREATE OR REPLACE VIEW ops.dead_tuples AS   -- vacuum candidates
SELECT schemaname AS schema, relname AS "table", n_live_tup AS live, n_dead_tup AS dead,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_vacuum
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;

CREATE OR REPLACE VIEW ops.cache_hit AS     -- should be > 99% on a healthy OLTP database
SELECT datname, blks_hit, blks_read, round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS hit_pct
FROM pg_stat_database WHERE datname IS NOT NULL ORDER BY blks_read DESC;

CREATE OR REPLACE VIEW ops.top_queries AS   -- needs pg_stat_statements
SELECT calls, round(total_exec_time::numeric, 0) AS total_ms, round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, left(regexp_replace(query, '\s+', ' ', 'g'), 90) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

CREATE OR REPLACE VIEW ops.databases AS
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size, numbackends AS connections,
       xact_commit, xact_rollback, deadlocks, temp_files
FROM pg_stat_database WHERE datname IN (SELECT datname FROM pg_database WHERE NOT datistemplate) ORDER BY datname;

CREATE OR REPLACE VIEW ops.archiver AS      -- is WAL archiving working? failed_count growing = pg_wal will fill the disk
SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;
