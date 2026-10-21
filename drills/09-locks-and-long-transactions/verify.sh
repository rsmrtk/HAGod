#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
N=$(psql_primary -c "select count(*) from ops.blocked")
echo "sessions still blocked: $N"
if [ "$N" != "0" ]; then
  docker exec tools psql -X -d bank -c '\x off' -c "select blocked_pid, waiting_for, blocking_pid, blocking_state, blocking_query from ops.blocked"
  read -p "Terminate the blockers for you? [y/N] " a
  [ "$a" = "y" ] && docker exec tools psql -X -q -d bank -c "select pg_terminate_backend(blocking_pid) from ops.blocked"
  sleep 2
fi
docker exec tools psql -X -d bank -c '\x off' -c "select pid, state, query_age, left(query,50) q from ops.activity"
docker exec tools psql -X -d bank -c "select owner from practice.locks_demo where id=1" -c "update practice.locks_demo set owner='nobody' where id=1" >/dev/null
ok "lab restored"
cat <<TXT

Questions:
  1. Which of the three sessions was the real problem and which were victims?
  2. Set a guard-rail and prove it works:  alter system set idle_in_transaction_session_timeout='30s'; select pg_reload_conf();
     (on a Patroni cluster use  patronictl edit-config  instead of alter system: why?)
  3. Besides blocking, what else does an old open transaction break? (hint: ops.dead_tuples and VACUUM)
TXT
