#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
M=$(state_get d14_master); T0=$(state_get d14_t0)
[ -z "$M" ] && { bad "run the break step first: make drill-14"; exit 1; }
printf '  can the master write now? '
docker exec "$M" redis-cli --no-auth-warning set test-write 1 2>&1 | head -1
echo
step "switching the policy to allkeys-lru: Redis may now delete the least recently used keys to make room"
docker exec "$M" redis-cli --no-auth-warning config set maxmemory-policy allkeys-lru >/dev/null
docker exec tools bash -c "for i in \$(seq 40001 50000); do echo \"SET batch:\$i value-value-value-value-value-value-\$i\"; done | redis-cli -h $M" 2>&1 | sort | uniq -c | head -2
docker exec "$M" redis-cli --no-auth-warning info stats | tr -d '\r' | grep -E "^evicted_keys"
docker exec "$M" redis-cli --no-auth-warning dbsize
echo
step "cleaning up"
docker exec "$M" redis-cli --no-auth-warning config set maxmemory 256mb >/dev/null
docker exec "$M" redis-cli --no-auth-warning config set maxmemory-policy noeviction >/dev/null
docker exec tools bash -c "redis-cli -h $M --scan --pattern 'batch:*' | xargs -r -n 500 redis-cli -h $M unlink" >/dev/null 2>&1
ok "removed the batch:* keys, limits restored"
warn "eviction deleted many of the training keys (that is what allkeys-lru does). Restoring them: make seed-redis"
./scripts/seed.sh redis >/dev/null 2>&1 && ok "training keys reloaded"
cat <<TXT

Questions:
  1. 'noeviction' protects data but stops writes; 'allkeys-lru' keeps writing but silently deletes. Which is right for (a) a session
     cache (b) a queue of payments (c) a rate limiter? Can one Redis serve all three?
  2. The limit was set with CONFIG SET on the master only. What happens to it after a failover? (CONFIG REWRITE, redis.conf on each node)
  3. Why is replication output memory also counted? (client-output-buffer-limit replica)
TXT
