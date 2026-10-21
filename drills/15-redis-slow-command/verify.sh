#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
M=$(state_get d15_master); T0=$(state_get d15_t0)
[ -z "$M" ] && { bad "run the break step first: make drill-15"; exit 1; }
moved() { [ "$(sentinel_master)" != "$M" ]; }
wait_for 40 "Sentinel switched master (it may not)" moved || true
sleep 3
N=$(sentinel_master)
printf '  master before: %s    master now (Sentinel): %s   => %s\n' "$M" "$N" "$([ "$N" != "$M" ] && echo "A FAILOVER HAPPENED for a process that was never down" || echo "no failover")"
echo
step "what the sentinels logged:"
docker logs sentinel1 2>&1 | grep -E "sdown|odown|switch-master|failover" | tail -6 | cut -c1-140
echo
step "slow log of the old master (what took long?):"
docker exec "$M" redis-cli --no-auth-warning slowlog get 3 2>/dev/null | head -12
step "latency spikes seen by the server:"
docker exec "$M" redis-cli --no-auth-warning latency latest 2>/dev/null | head -6
sleep 7; ./scripts/report.sh --since "$(since_arg "$T0")" | sed -n '/REDIS/,$p'
cat <<TXT

Questions:
  1. How would you PREVENT this? (never run KEYS in prod; SCAN instead; UNLINK instead of DEL on big keys; slowlog alerts;
     down-after-milliseconds tuned to your slowest legitimate command; 'rename-command KEYS ""' or ACLs)
  2. Raise down-after-milliseconds to 20000: what do you gain and lose in a REAL crash? (compare with drill 11)
  3. Write the alert that would have warned you: which metric, which threshold?
TXT
