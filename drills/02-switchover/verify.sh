#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
OLD=$(state_get d02_old); T0=$(state_get d02_t0)
[ -z "$OLD" ] && { bad "run the break step first: make drill-02"; exit 1; }
new_leader() { local l; l=$(pg_leader) || return 1; [ "$l" != "$OLD" ]; }
wait_for 60 "new primary" new_leader || exit 1
printf '  new primary: %s   total time of the switchover command: %s s\n\n' "$(pg_leader)" "$(elapsed_since "$T0")"
docker exec tools patronictl list 2>&1 | tail -6
echo
settle
probe_running && ./scripts/report.sh --since "$(since_arg "$T0")"
cat <<TXT

Questions:
  1. Why is a switchover so much faster and gentler than drill 01? (what did the old primary do before handing over?)
  2. Can you schedule one?  patronictl switchover --scheduled "2026-10-20T03:00"  (try --help)
  3. When would you use failover (forced) instead of switchover?  patronictl failover --help
TXT
