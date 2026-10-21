#!/usr/bin/env bash
# Put everything back after a drill: start stopped containers, unpause, reconnect networks,
# resume Patroni, and reset the settings that drills change.
source "$(dirname "$0")/lib.sh"
step "starting stopped containers"
for n in $ETCD_NODES $PG_NODES haproxy $REDIS_NODES $SENTINELS tools; do
  if [ "$(docker inspect -f '{{.State.Paused}}' "$n" 2>/dev/null)" = "true" ]; then docker unpause "$n" >/dev/null && ok "unpaused $n"; fi
  if ! running "$n"; then docker start "$n" >/dev/null 2>&1 && ok "started $n"; fi
done
step "reconnecting anything cut off from the network"
for n in $ETCD_NODES $PG_NODES $REDIS_NODES $SENTINELS; do
  if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$n" 2>/dev/null | grep -q '"hagod"'; then
    net_reconnect "$n" >/dev/null 2>&1 && ok "reconnected $n"
  fi
done
step "Patroni: leaving maintenance mode, restoring default settings"
docker exec tools patronictl resume --wait >/dev/null 2>&1 || true
docker exec tools patronictl edit-config --force -s synchronous_mode=false -s synchronous_mode_strict=false -s ttl=30 -s loop_wait=10 >/dev/null 2>&1 || true
step "Redis: restoring default settings"
M=$(redis_master)
if [ -n "$M" ]; then
  docker exec "$M" redis-cli --no-auth-warning config set maxmemory 256mb >/dev/null
  docker exec "$M" redis-cli --no-auth-warning config set maxmemory-policy noeviction >/dev/null
  docker exec "$M" redis-cli --no-auth-warning config set min-replicas-to-write 0 >/dev/null
fi
step "waiting for a healthy cluster"
"$(dirname "$0")/wait-ready.sh" | grep -v '^$' | tail -5
