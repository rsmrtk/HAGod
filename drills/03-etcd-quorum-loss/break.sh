#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
L=$(pg_leader); state_set d03_leader "$L"; state_set d03_t0 "$(now)"
step "Postgres is healthy and $L is primary. Stopping TWO of the three etcd nodes: etcd2 and etcd3"
docker stop etcd2 etcd3 >/dev/null
ok "etcd has lost its quorum (1 of 3 left). Nobody can read or renew the leader lock."
cat <<TXT

Predict first:  will $L keep accepting writes? will a replica get promoted? what will the probe show?
Watch for ~40 s (make watch). Then:   make verify-03
TXT
