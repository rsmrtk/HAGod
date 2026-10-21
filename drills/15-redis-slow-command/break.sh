#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
M=$(redis_master); state_set d15_master "$M"; state_set d15_t0 "$(now)"
step "someone runs a command that blocks Redis for 8 seconds on $M (here: DEBUG SLEEP 8; in real life: KEYS *, a huge SMEMBERS, a Lua script)"
docker exec -d "$M" redis-cli --no-auth-warning debug sleep 8
ok "the master is busy and answers nobody. Sentinel's down-after-milliseconds is 5000."
cat <<TXT

Redis is single-threaded for commands. The process is ALIVE, but to Sentinel it looks DEAD.
Predict: will there be a failover? Is anything wrong with the machine? Watch 20 s, then:   make verify-15
TXT
