#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
V=$(state_get d12_victim); T0=$(state_get d12_t0)
[ -z "$V" ] && { bad "run the break step first: make drill-12"; exit 1; }
step "t+$(elapsed_since "$T0") s. What does the surviving sentinel think of the master?"
docker exec sentinel1 redis-cli -p 26379 --no-auth-warning sentinel master mymaster | paste - - | grep -E "^(name|ip|flags|quorum|num-other-sentinels)\s" | sed 's/\t/ = /'
echo "  masters that exist: [$(redis_masters | tr '\n' ' ')]"
echo
printf '  ckquorum says: '; docker exec sentinel1 redis-cli -p 26379 --no-auth-warning sentinel ckquorum mymaster 2>&1 | head -1
echo
step "bringing the sentinels back"
docker start sentinel2 sentinel3 >/dev/null
changed() { local m; m=$(sentinel_master); [ -n "$m" ] && [ "$m" != "$V" ] && running "$m"; }
wait_for 90 "failover finally happened" changed
printf '  new master: %s   total time since the kill: %s s\n' "$(sentinel_master)" "$(elapsed_since "$T0")"
sleep 7; ./scripts/report.sh --since "$(since_arg "$T0")" | sed -n '/REDIS/,$p'
cat <<TXT

Two different numbers decide a failover. Find them in the Sentinel docs and write them down:
  - QUORUM (2): how many sentinels must agree the master is down (that is the 'ODOWN' state)
  - MAJORITY (2 of 3): how many sentinels must authorise ONE of them to run the failover
Questions:
  1. With 3 sentinels and quorum 2, how many can you lose? What if you had 2 sentinels? What if the quorum were 1?
  2. Why must sentinels live on DIFFERENT machines from each other, and ideally not only on the Redis machines?
TXT
