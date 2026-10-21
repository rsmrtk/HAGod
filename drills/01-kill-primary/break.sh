#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
L=$(pg_leader); [ -z "$L" ] && { bad "no leader found"; exit 1; }
state_set d01_victim "$L"; state_set d01_t0 "$(now)"
step "the primary is $L. Hard-killing it (docker kill = SIGKILL, like a power cut)"
docker kill "$L" >/dev/null
ok "$L is dead. The clock started."
cat <<TXT

Now watch (second terminal: make watch). Before you look at the answer, say out loud:
  - Which node will be promoted? How long will it take, and why that long?
  - What will the probe show?
When you think it is over:   make verify-01
TXT
