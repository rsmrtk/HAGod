#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
R=$(state_get d06_replica)
[ -z "$R" ] && { bad "run the break step first: make drill-06"; exit 1; }
step "the paused replica $R has replayed this many rows; the primary has more:"
printf '  on %s: ' "$R"; pgsql_on "$R" -d bank -c "select count(*) from practice.lag_demo"
printf '  on primary: '; psql_primary -c "select count(*) from practice.lag_demo"
echo
step "resuming replay and timing the catch-up"
T=$(now); pgsql_on "$R" -c "select pg_wal_replay_resume()" >/dev/null
caught() { [ "$(pgsql_on "$R" -d bank -c "select count(*) from practice.lag_demo")" = "$(psql_primary -c 'select count(*) from practice.lag_demo')" ]; }
wait_for 120 "$R caught up" caught
docker exec tools psql -X -q -d bank -c "drop table if exists practice.lag_demo" >/dev/null 2>&1
cat <<TXT

Questions:
  1. Patroni refuses to promote a replica that is more than maximum_lag_on_failover (1 MB) behind. If BOTH replicas were this
     far behind and the primary died, what would happen? (try: patronictl edit-config, change it, repeat with the break script
     and kill the primary yourself)
  2. Which of your monitoring signals would have caught this: byte lag, replay_lag (seconds) or Patroni state?
  3. Why can an application that reads from replicas see money that was just transferred "missing"?
TXT
