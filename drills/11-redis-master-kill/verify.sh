#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
V=$(state_get d11_victim); T0=$(state_get d11_t0)
[ -z "$V" ] && { bad "run the break step first: make drill-11"; exit 1; }
changed() { local m; m=$(sentinel_master); [ -n "$m" ] && [ "$m" != "$V" ] && running "$m"; }
wait_for 90 "Sentinel promoted a new master" changed || exit 1
N=$(sentinel_master)
printf '\n  new master: %s%s%s   time since the kill: %s s\n\n' "$c_bold" "$N" "$c_off" "$(elapsed_since "$T0")"
step "what the sentinels logged (the failover, step by step):"
docker logs sentinel1 2>&1 | grep -E "sdown|odown|vote|elected|failover|switch-master|promoted" | tail -9 | cut -c1-150
echo
if ! running "$V"; then
  read -p "Start the old master $V and see how it rejoins? [y/N] " a
  if [ "$a" = "y" ]; then
    docker start "$V" >/dev/null
    wait_for 60 "$V is a replica of $N" bash -c "docker exec $V redis-cli --no-auth-warning role | head -1 | grep -q slave"
    docker logs "$V" 2>&1 | grep -E "entrypoint|MASTER <-> REPLICA|Partial|Full|sync" | head -5 | cut -c1-150
  fi
fi
settle_redis() { sleep 7; }; settle_redis
echo; ./scripts/report.sh --since "$(since_arg "$T0")" | sed -n '/REDIS/,$p'
cat <<TXT

Questions:
  1. Redis replication is asynchronous. Which writes can be lost in this failover, and can you make the number smaller? (drill 13)
  2. Why did the restarted old master NOT come back as master? (read scripts/redis-entrypoint.sh, then think: what if it did?)
  3. How do your application clients find the new master? Compare with HAProxy for Postgres.
TXT
