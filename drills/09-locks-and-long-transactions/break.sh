#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
step "session A: BEGIN; UPDATE the hot row; then... forgets to COMMIT (sits 'idle in transaction' for 10 minutes)"
docker exec -d tools bash -c "(echo \"begin; update practice.locks_demo set owner='A' where id=1;\"; sleep 600) | psql -X -q -d bank"
sleep 2
step "session B: wants to update the same row, and waits"
docker exec -d tools psql -X -q -d bank -c "update practice.locks_demo set owner='B' where id=1"
step "session C: a harmless read-only report that also needs the table"
docker exec -d tools psql -X -q -d bank -c "lock table practice.locks_demo in access exclusive mode"
sleep 2
cat <<TXT

The application looks 'hung'. You are on call. Find out:
  1. who is blocked and who blocks them:        make psql   then   select * from ops.blocked;
  2. what the blocker is doing:                 select * from ops.activity;
  3. kill the right session:                    select pg_terminate_backend(<blocking_pid>);
  4. make it impossible to forget:              see drill README, 'idle_in_transaction_session_timeout'
Then:   make verify-09
TXT
