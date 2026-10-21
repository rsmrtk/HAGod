#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
P=$(pg_leader); R=$(pg_replicas | head -1)
state_set d06_replica "$R"; state_set d06_primary "$P"; state_set d06_t0 "$(now)"
step "primary $P, victim replica $R. Pausing WAL replay on $R (it still RECEIVES WAL, it just stops applying it)"
pgsql_on "$R" -c "select pg_wal_replay_pause()" >/dev/null
step "generating hundreds of MB of WAL on the primary (700 thousand rows)"
docker exec tools psql -X -q -d bank -c "create table if not exists practice.lag_demo(id bigserial primary key, payload text)" \
  -c "insert into practice.lag_demo(payload) select repeat(md5(g::text), 3) from generate_series(1, 700000) g"
step "lag as the primary sees it (ops.replication):"
docker exec tools psql -X -d bank -c '\x off' -c "select replica, state, sync_state, replay_lag_bytes, replay_lag from ops.replication"
echo
echo "Patroni's view:   docker exec tools patronictl list"
echo "A paused replica serves STALE reads (try a SELECT count(*) on it through port 5001). Then:   make verify-06"
