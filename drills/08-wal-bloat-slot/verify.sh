#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
P=$(state_get d08_primary)
[ -z "$P" ] && { bad "run the break step first: make drill-08"; exit 1; }
step "slots right now:"
docker exec tools psql -X -d postgres -c '\x off' -c "select slot_name, active, wal_status, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as wal_retained from pg_replication_slots order by 1"
if docker exec tools psql -X -qAt -d postgres -c "select 1 from pg_replication_slots where slot_name='orphan_slot'" | grep -q 1; then
  warn "orphan_slot still exists. Drop it:  select pg_drop_replication_slot('orphan_slot');   (then CHECKPOINT)"
  read -p "Do it for you? [y/N] " a
  [ "$a" = "y" ] && docker exec tools psql -X -q -d postgres -c "select pg_drop_replication_slot('orphan_slot')" -c "checkpoint" >/dev/null
fi
docker exec tools psql -X -q -d postgres -c checkpoint >/dev/null
step "pg_wal on $P now: $(docker exec "$P" du -sh /var/lib/postgresql/data/pgdata/pg_wal | cut -f1)"
docker exec tools psql -X -q -d bank -c "drop table if exists practice.wal_demo" >/dev/null 2>&1
cat <<TXT

BONUS: the other classic way pg_wal fills a disk is a FAILING archive_command. Check it any time:
  select * from ops.archiver;     (failed_count growing, last_failed_wal set)

Questions:
  1. Patroni creates one slot per replica itself. Why did it not remove 'orphan_slot'? (read the 'slots' section of the Patroni docs)
  2. What setting limits how much WAL a slot may hold back?  (max_slot_wal_keep_size; what does it cost you when it triggers?)
  3. Write the alert: "a slot is inactive AND retains more than X GB". What is X on your production disks?
TXT
