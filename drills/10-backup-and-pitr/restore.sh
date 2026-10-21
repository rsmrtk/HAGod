#!/usr/bin/env bash
# Point-in-time recovery into a SEPARATE throwaway Postgres ("pitr"), then you copy the data back.
source "$(dirname "$0")/../../scripts/lib.sh"
BK=$(state_get d10_backup); TARGET=$(state_get d10_target)
[ -z "$BK" ] && { bad "run the break step first: make drill-10"; exit 1; }
step "recovery target time: $TARGET   from backup: $BK"
docker rm -f pitr >/dev/null 2>&1; docker volume rm -f hagod_pitrdata >/dev/null 2>&1

# 1. a data directory = the base backup
# 2. recovery.signal says "start in recovery mode"
# 3. restore_command tells Postgres where to fetch archived WAL; recovery_target_time says where to stop
docker run -d --name pitr --network hagod --user postgres \
  -v hagod_backup:/backup:ro -v hagod_archive:/archive:ro -v hagod_pitrdata:/data \
  --entrypoint bash postgres:17 -c "
    set -e
    cp -a /backup/$BK/. /data/
    chmod 700 /data
    rm -f /data/postmaster.pid /data/standby.signal
    touch /data/recovery.signal
    cat >> /data/postgresql.auto.conf <<CONF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '$TARGET'
recovery_target_action = 'promote'
hot_standby = on
archive_mode = off
primary_conninfo = ''
primary_slot_name = ''
CONF
    exec postgres -D /data -c port=5432 -c listen_addresses='*' -c unix_socket_directories=/tmp
  " >/dev/null
ok "throwaway server 'pitr' started; replaying WAL up to the target time..."
ready() { docker exec pitr psql -X -h localhost -U postgres -At -d bank -c "select not pg_is_in_recovery()" 2>/dev/null | grep -q t; }
wait_for 180 "recovery finished and 'pitr' accepts connections" ready || { docker logs pitr 2>&1 | tail -15; exit 1; }
echo
docker logs pitr 2>&1 | grep -E "recovery stopping|redo done|last completed|archive recovery complete|consistent recovery" | cut -c1-160
echo
step "what the recovered server has:"
docker exec pitr psql -X -h localhost -U postgres -d bank -c "select count(*) as rows_in_transactions from core.transactions"
cat <<TXT

To bring the table back into production (without taking anything down):
   docker exec pitr pg_dump -h localhost -U postgres -d bank -t core.transactions --no-owner > /tmp/transactions.sql
   docker cp pitr:/tmp/transactions.sql . 2>/dev/null || true
   (or pipe it straight into the live database: see verify)
When you are done:   docker rm -f pitr
TXT
