#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cluster_ok() {
  local n; n=$(docker exec tools patronictl list -f json 2>/dev/null) || return 1
  [ "$(echo "$n" | jq '[.[]|select(.Role=="Leader" and .State=="running")]|length')" = "1" ] &&
  [ "$(echo "$n" | jq '[.[]|select(.Role!="Leader" and .State=="streaming")]|length')" = "2" ]
}
redis_ok() {
  [ "$(docker exec sentinel1 redis-cli -p 26379 --no-auth-warning sentinel ckquorum mymaster 2>/dev/null | head -c 2)" = "OK" ] || return 1
  [ "$(redis_masters | wc -l | tr -d ' ')" = "1" ] || return 1
  # every other node must be a replica with a working link (a replica of a replica is fine)
  local n info
  for n in $REDIS_NODES; do
    running "$n" || return 1
    info=$(docker exec "$n" redis-cli --no-auth-warning info replication | tr -d '\r')
    case "$info" in *role:master*) continue;; esac
    echo "$info" | grep -q "master_link_status:up" || return 1
  done
}
haproxy_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 localhost:7100/)" = "200" ] && pg_leader >/dev/null; }

wait_for 180 "tools container up"        running tools || exit 1
wait_for 180 "Patroni: 1 leader + 2 streaming replicas" cluster_ok || exit 1
wait_for 120 "Redis Sentinel quorum"      redis_ok || exit 1
wait_for 60  "HAProxy routes to a primary" haproxy_ok || exit 1
echo
echo "Ready. Next:  make seed   (load training data)   then   make watch"
