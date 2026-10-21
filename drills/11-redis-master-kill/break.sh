#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
M=$(redis_master); state_set d11_victim "$M"; state_set d11_t0 "$(now)"
step "Redis master is $M. Hard-killing it."
docker kill "$M" >/dev/null
ok "$M is dead. The clock started."
cat <<TXT

Sentinel decides what happens next. Predict: how long until a new master? Which settings control that?
(sentinel.conf: down-after-milliseconds, failover-timeout)   Watch: make watch    Then:   make verify-11
TXT
