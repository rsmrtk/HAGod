#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
L=$(state_get d03_leader); T0=$(state_get d03_t0)
[ -z "$L" ] && { bad "run the break step first: make drill-03"; exit 1; }
step "state of the Patroni nodes right now (t+$(elapsed_since "$T0") s)"
for n in $PG_NODES; do
  printf '  %s: ' "$n"; curl -s --max-time 1 "localhost:$(pg_port "$n")/patroni" | jq -r '"role=\(.role) state=\(.state)"' 2>/dev/null || echo "no answer"
done
echo
printf '  can anything write? '
psql_primary -c "create table if not exists probe_d03(x int); insert into probe_d03 values(1)" >/dev/null 2>&1 && echo "yes" || echo "NO: no primary is accepting writes"
echo
probe_running && ./scripts/report.sh --since "$(since_arg "$T0")" 2>&1 | head -8
echo
step "bringing etcd back"
docker start etcd2 etcd3 >/dev/null
wait_for 120 "Patroni has a primary again" pg_leader || exit 1
settle
printf '  primary: %s (was %s). Did it change? %s\n' "$(pg_leader)" "$L" "$([ "$(pg_leader)" = "$L" ] && echo 'no, same node' || echo 'YES, a failover happened')"
cat <<TXT

What you should have learned:
  - Postgres itself stayed up, but the PRIMARY DEMOTED ITSELF to read-only. Why? (it cannot prove it still owns the lock)
  - That is the safety rule: no lock, no writes. Cost: an etcd outage is an application outage.
  - Fix in production: etcd on separate, healthy hosts; monitor etcd first. Patroni has "failsafe_mode" to soften this;
    try:  patronictl edit-config -s failsafe_mode=true   then repeat the drill and compare.
TXT
