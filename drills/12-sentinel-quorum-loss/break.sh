#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
M=$(redis_master); state_set d12_victim "$M"; state_set d12_t0 "$(now)"
step "stopping sentinel2 and sentinel3. Only sentinel1 is left (quorum is 2 of 3)"
docker stop sentinel2 sentinel3 >/dev/null
step "...and now killing the master $M"
docker kill "$M" >/dev/null
cat <<TXT

Predict: will sentinel1, alone, promote a replica? Why or why not? What will the application see?
Watch ~40 s with  make watch  and  docker exec sentinel1 redis-cli -p 26379 sentinel master mymaster
Then:   make verify-12
TXT
