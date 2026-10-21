#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
V=$(state_get d04_victim); T0=$(state_get d04_t0)
[ -z "$V" ] && { bad "run the break step first: make drill-04"; exit 1; }
step "t+$(elapsed_since "$T0") s. Who is primary, as seen from outside?"
echo "  HAProxy sends writes to: $(pg_leader)"
printf '  what does the isolated node %s say about itself? ' "$V"
R=$(docker exec -e PGPASSWORD=hagod-super "$V" psql -X -At -h localhost -U postgres -c "select case when pg_is_in_recovery() then 'it demoted itself: read-only replica' else 'it still thinks it is PRIMARY (split brain risk!)' end" 2>&1 | head -1)
case "$R" in
  *refused*|*"not accept"*|*"No such file"*) echo "PostgreSQL is STOPPED on it: Patroni shut it down because it lost the leader lock (the safest outcome)";;
  *) echo "$R";;
esac
echo
step "reconnecting $V"
net_reconnect "$V"
wait_for 180 "$V is a streaming replica again" bash -c "docker exec tools patronictl list -f json | jq -e '.[]|select(.Member==\"$V\" and .State==\"streaming\")'"
docker exec tools patronictl list 2>&1 | tail -6
echo
settle
probe_running && ./scripts/report.sh --since "$(since_arg "$T0")"
cat <<TXT

Questions:
  1. What stopped the isolated primary from accepting writes forever? (find the ttl in patroni.yml, and watchdog in the docs)
  2. Which writes sent to the isolated node during those seconds are gone? How do you know? (report above, RPO line)
  3. How did the old primary rejoin? (docker logs $V | grep -i rewind)
TXT
