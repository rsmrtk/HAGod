#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
L=$(pg_leader); state_set d04_victim "$L"; state_set d04_t0 "$(now)"
step "cutting $L off the network (it stays alive, running Postgres, but can reach nobody)"
docker network disconnect hagod "$L"
ok "$L is isolated. It is still running and still thinks it might be the primary."
cat <<TXT

This is the dangerous failure: a node that is alive but unreachable. Predict:
  - Does $L keep accepting writes? For how long? (try:  docker exec -e PGPASSWORD=hagod-super $L psql -h localhost -U postgres -c 'select pg_is_in_recovery()')
  - Does the rest of the cluster wait for it or move on?
Watch 60 s, then:   make verify-04
TXT
