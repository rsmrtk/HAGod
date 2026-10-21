#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
OLD=$(state_get d13_old); T0=$(state_get d13_t0); MODE=$(state_get d13_mode)
[ -z "$OLD" ] && { bad "run the break step first: make drill-13"; exit 1; }
OLDIP=$(state_get d13_oldip)
# Sentinel reports the master as a hostname at first and as an IP after a failover
moved() { local a; a=$(sentinel_master_addr); [ -n "$a" ] && [ "$a" != "$OLDIP" ] && [ "$a" != "$OLD" ]; }
step "waiting for the sentinels to promote a new master on the other side of the partition"
wait_for 150 "Sentinel switched to a new master" moved
echo
step "t+$(elapsed_since "$T0") s. Two masters? (this is the split brain)"
echo "  Sentinels say the master is: $(redis_name_of "$(sentinel_master_addr)")"
echo "  The isolated $OLD says:      $(docker exec "$OLD" redis-cli --no-auth-warning role 2>/dev/null | head -1)"
docker exec tools bash -c "tail -n 400 /tmp/stale-writes.log | sort | uniq -c | sort -rn | head -3" | sed 's/^/  stale client got: /'
STALE_OK=$(docker exec tools grep -c '^OK' /tmp/stale-writes.log 2>/dev/null)
STALE_ERR=$(docker exec tools grep -vc '^OK' /tmp/stale-writes.log 2>/dev/null)
echo "  stale client: $STALE_OK writes accepted, $STALE_ERR refused"
docker exec tools pkill -f "stale:" 2>/dev/null; docker exec tools pkill -f "redis-cli -h $OLD" 2>/dev/null
echo
step "healing the partition"
docker network disconnect part-a tools >/dev/null 2>&1
docker network disconnect part-a "$OLD" >/dev/null 2>&1
net_reconnect "$OLD"
docker network rm part-a >/dev/null 2>&1
wait_for 90 "$OLD became a replica of the new master" bash -c "docker exec $OLD redis-cli --no-auth-warning role | head -1 | grep -q slave"
sleep 3
N=$(redis_master)
FOUND=$(docker exec "$N" redis-cli --no-auth-warning --scan --pattern 'stale:*' | wc -l | tr -d ' ')
printf '\n  of the %s writes the stale client had ACCEPTED, %s%s exist on the surviving master%s.\n' "$STALE_OK" "$c_bold" "$FOUND" "$c_off"
[ "$STALE_OK" -gt 0 ] && [ "$FOUND" -eq 0 ] && printf '  %s=> %s acknowledged writes are gone for good (RPO > 0).%s\n' "$c_red" "$STALE_OK" "$c_off"
docker exec tools rm -f /tmp/stale-writes.log
docker exec "$N" redis-cli --no-auth-warning config set min-replicas-to-write 0 >/dev/null
cat <<TXT

$([ "$MODE" = "plain" ] && echo "Repeat with protection and compare the numbers:   make heal && ./drills/13-redis-split-brain/break.sh protected" || echo "With min-replicas-to-write the isolated master stopped accepting writes after ~5 s: far fewer lost writes. The price: if replicas are down, the master is write-unavailable.")

Questions:
  1. Which clients keep writing to an old master in real life? (connection pools, DNS caches, a client library without Sentinel support)
  2. What is the trade-off of min-replicas-to-write for availability? Which would your business choose?
  3. When the old master rejoined, what happened to ITS data, and why can it not be merged?
TXT
