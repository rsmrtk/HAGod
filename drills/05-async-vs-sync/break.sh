#!/usr/bin/env bash
# usage: break.sh [async|strict]
source "$(dirname "$0")/../../scripts/lib.sh"
MODE="${1:-async}"
drill_preflight
probe_running || { bad "this drill needs the probe: make writer-start"; exit 1; }
P=$(pg_leader); REPL=$(pg_replicas | tr '\n' ' ')
state_set d05_primary "$P"; state_set d05_replicas "$REPL"; state_set d05_t0 "$(now)"; state_set d05_mode "$MODE"

if [ "$MODE" = "strict" ]; then
  step "switching Patroni to STRICT synchronous replication (a commit is acknowledged only when a standby has it)"
  docker exec tools patronictl edit-config --force -s synchronous_mode=true -s synchronous_mode_strict=true >/dev/null
  wait_for 60 "a synchronous standby exists" bash -c "docker exec tools patronictl list -f json | jq -e '.[]|select(.Role==\"Sync Standby\")'" || exit 1
else
  step "replication mode: ASYNCHRONOUS (the default): the primary acknowledges a commit without waiting for any replica"
fi

step "primary is $P, replicas are: $REPL"
step "STEP 1: cutting the replicas off the network. They cannot receive WAL any more."
for r in $REPL; do docker network disconnect hagod "$r"; done
step "STEP 2: 20 seconds pass while the application keeps writing to the primary..."
for i in 1 2 3 4; do
  sleep 5
  printf '   t+%2ds  ' "$((i*5))"
  docker exec writer tail -n 200 /data/probe.log | awk -v now="$(now)" '$2=="pg" && now-$1<=5 {n++; if($4=="ok")o++} END{ if(n==0) print "Postgres: NO write finished in the last 5 s (they are blocked, waiting for a standby)"; else printf "Postgres: %d of %d writes acknowledged in the last 5 s\n", o, n }'
done
step "STEP 3: the primary $P dies (docker kill) and the replicas come back"
docker kill "$P" >/dev/null
sleep 1
for r in $REPL; do net_reconnect "$r"; done
ok "done. The replicas will now elect one of themselves."
echo
echo "Predict: how many ACKNOWLEDGED writes will be missing on the new primary?   make verify-05"
