#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
P=$(pg_leader); state_set d08_primary "$P"
step "creating a replication slot that NOBODY reads (what a dead replica or forgotten tool leaves behind)"
docker exec tools psql -X -q -d postgres -c "select pg_create_physical_replication_slot('orphan_slot', true)" >/dev/null
step "size of pg_wal before:  $(docker exec "$P" du -sh /var/lib/postgresql/data/pgdata/pg_wal | cut -f1)"
step "writing a lot (700k rows, then updating them)"
docker exec tools psql -X -q -d bank -c "create table if not exists practice.wal_demo(id bigserial primary key, v text)" \
  -c "insert into practice.wal_demo(v) select repeat(md5(g::text),3) from generate_series(1,700000) g" \
  -c "update practice.wal_demo set v = v || 'x'" -c "checkpoint"
step "size of pg_wal after:   $(docker exec "$P" du -sh /var/lib/postgresql/data/pgdata/pg_wal | cut -f1)"
echo
docker exec tools psql -X -d postgres -c '\x off' -c "select slot_name, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained from pg_replication_slots order by 1"
cat <<TXT

The disk of the primary now holds WAL that only the orphan slot wants. In production this fills the disk and Postgres stops.
Find it (ops.slots in the bank database), then fix it:   make verify-08
TXT
