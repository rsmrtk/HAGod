#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
V=$(state_get d01_victim); T0=$(state_get d01_t0)
[ -z "$V" ] && { bad "run the break step first: make drill-01"; exit 1; }
new_leader() { local l; l=$(pg_leader) || return 1; [ "$l" != "$V" ]; }
step "waiting for a new primary (the old one was $V)"
wait_for 120 "new primary elected" new_leader || exit 1
L=$(pg_leader)
printf '\n  new primary: %s%s%s   time since the kill: %s%s s%s  (this is the failover time)\n' "$c_bold" "$L" "$c_off" "$c_bold" "$(elapsed_since "$T0")" "$c_off"
echo
step "timeline history (every failover bumps the timeline)"
docker exec tools patronictl history 2>&1 | tail -5
echo
if ! running "$V"; then
  warn "$V is still dead. Start it and watch what Patroni does with a node that was a primary:"
  echo "    docker start $V       then  make watch"
  echo "    (it comes back as a replica; if its WAL diverged, Patroni runs pg_rewind to fix it)"
  echo
  read -p "Start $V now? [y/N] " a
  [ "$a" = "y" ] && { docker start "$V" >/dev/null; wait_for 120 "$V is a streaming replica" bash -c "docker exec tools patronictl list -f json | jq -e '.[]|select(.Member==\"$V\" and .State==\"streaming\")'" ; }
fi
echo
step "what the application saw"
settle
probe_running && ./scripts/report.sh --since "$(since_arg "$T0")" || warn "probe not running"
cat <<TXT

Questions to answer in your runbook (docs/RUNBOOK-TEMPLATE.md):
  1. What decided the failover time? (hint: ttl 30, loop_wait 10, retry_timeout 10 in patroni.yml)
  2. Why did the old primary not just come back as primary?
  3. Could a write be lost? Under which setting is that impossible? (drill 05)
  4. What would your monitoring have shown during these seconds?
TXT
