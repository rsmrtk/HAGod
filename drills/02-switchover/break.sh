#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
L=$(pg_leader); state_set d02_old "$L"; state_set d02_t0 "$(now)"
step "planned switchover away from $L (Patroni demotes it cleanly, then promotes a replica)"
docker exec tools patronictl switchover --leader "$L" --force 2>&1 | tail -4
echo
echo "Compare with drill 01. When done:   make verify-02"
