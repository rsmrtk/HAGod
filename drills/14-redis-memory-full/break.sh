#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
M=$(redis_master); state_set d14_master "$M"; state_set d14_t0 "$(now)"
USED=$(docker exec "$M" redis-cli --no-auth-warning info memory | tr -d '\r' | sed -n 's/^used_memory://p')
LIMIT=$((USED + 4*1024*1024))
step "master $M uses $((USED/1024/1024)) MB. Setting maxmemory to $((LIMIT/1024/1024)) MB with policy noeviction (the default)"
docker exec "$M" redis-cli --no-auth-warning config set maxmemory "$LIMIT" >/dev/null
docker exec "$M" redis-cli --no-auth-warning config set maxmemory-policy noeviction >/dev/null
step "a batch job writes 40,000 more keys..."
docker exec tools bash -c "for i in \$(seq 1 40000); do echo \"SET batch:\$i value-value-value-value-value-value-\$i\"; done | redis-cli -h $M" 2>&1 | sort | uniq -c | sort -rn | head -3
echo
docker exec "$M" redis-cli --no-auth-warning info memory | tr -d '\r' | grep -E "^(used_memory_human|maxmemory_human|maxmemory_policy)"
docker exec "$M" redis-cli --no-auth-warning info stats | tr -d '\r' | grep -E "^(evicted_keys|rejected_connections)"
cat <<TXT

The master now REFUSES writes (the probe's Redis writes fail too: make watch). Find the cause and fix it:
   Who is the biggest key?   redis-cli --bigkeys     /    MEMORY USAGE bigkey:audit_blob
   What can be evicted?      CONFIG GET maxmemory-policy       (allkeys-lru? volatile-ttl? when is each right?)
   Which keys never expire?  the overview: make overview   (TTL? column)
Then:   make verify-14
TXT
