#!/usr/bin/env bash
# Shared helpers for the scripts and drills. Works with macOS bash 3.2.
export LC_ALL=C   # decimal point, not comma, whatever the system locale
HAGOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_NODES="pg1 pg2 pg3"
REDIS_NODES="redis1 redis2 redis3"
SENTINELS="sentinel1 sentinel2 sentinel3"
ETCD_NODES="etcd1 etcd2 etcd3"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_off=$'\033[0m'

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s ok %s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s !! %s %s\n' "$c_ylw" "$c_off" "$*"; }
bad()  { printf '%s FAIL %s %s\n' "$c_red" "$c_off" "$*"; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Patroni REST port on the host for pgN
pg_port() { echo "810${1#pg}"; }

# name of the node that currently holds the leader lock and answers 200 on /primary
pg_leader() {
  local n
  for n in $PG_NODES; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "localhost:$(pg_port "$n")/primary")" = "200" ] && { echo "$n"; return 0; }
  done
  return 1
}

# names of the nodes that answer 200 on /replica
pg_replicas() {
  local n
  for n in $PG_NODES; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "localhost:$(pg_port "$n")/replica")" = "200" ] && echo "$n"
  done
}

# a Postgres node that is up (for patronictl, which only needs etcd)
tools() { docker exec -i tools "$@"; }
psql_primary() { docker exec -i tools psql -X -q -At -d "${PGDATABASE_OVERRIDE:-bank}" "$@"; }
pgsql_on() { local node="$1"; shift; docker exec -i -e PGPASSWORD=hagod-super "$node" psql -X -q -At -h localhost -U postgres "$@"; }

# Redis nodes that think they are masters (two of them = split brain)
redis_masters() {
  local n
  for n in $REDIS_NODES; do
    running "$n" && [ "$(docker exec "$n" redis-cli --no-auth-warning role 2>/dev/null | head -1)" = "master" ] && echo "$n"
  done
}
redis_master() { redis_masters | head -1; }

# the container name behind an IP or hostname that Sentinel reports
redis_name_of() {
  local addr="$1" n ip
  for n in $REDIS_NODES; do
    [ "$addr" = "$n" ] && { echo "$n"; return; }
    ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "hagod").IPAddress}}' "$n" 2>/dev/null)
    [ "$addr" = "$ip" ] && { echo "$n"; return; }
  done
  echo "$addr"
}
sentinel_master() {
  local s a
  for s in $SENTINELS; do
    running "$s" || continue
    a=$(docker exec "$s" redis-cli -p 26379 --no-auth-warning sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1)
    [ -n "$a" ] && { redis_name_of "$a"; return; }
  done
}

# wait until "$@" succeeds; prints how long it took. usage: wait_for 90 "label" cmd args...
wait_for() {
  local limit="$1" label="$2"; shift 2
  local t0 t1; t0=$(now)
  while true; do
    if "$@" >/dev/null 2>&1; then
      t1=$(now); printf '%s%s%s after %.1f s\n' "$c_grn" "$label" "$c_off" "$(echo "$t1 - $t0" | bc -l)"; return 0
    fi
    t1=$(now)
    if [ "$(echo "$t1 - $t0 > $limit" | bc -l)" = "1" ]; then
      printf '%sgave up waiting for: %s (%s s)%s\n' "$c_red" "$label" "$limit" "$c_off"; return 1
    fi
    sleep 0.25
  done
}

probe_running() { running writer; }

# ---- drill state (what a break script did, for its verify script)
STATE_DIR="$HAGOD_DIR/.state"; mkdir -p "$STATE_DIR"
state_set() { printf '%s' "$2" > "$STATE_DIR/$1"; }
state_get() { cat "$STATE_DIR/$1" 2>/dev/null; }
elapsed_since() { printf '%.1f' "$(echo "$(now) - $1" | bc -l)"; }

# Make sure a drill starts from a healthy lab and the probe is writing.
drill_preflight() {
  running tools || { bad "the lab is not running: make up"; exit 1; }
  local n; n=$(docker exec tools patronictl list -f json 2>/dev/null | jq '[.[]|select(.State=="streaming" or .State=="running")]|length')
  [ "${n:-0}" -ge 3 ] || { bad "Postgres cluster is not healthy: run  make heal  first"; exit 1; }
  [ "$(redis_masters | wc -l | tr -d ' ')" = "1" ] || { bad "Redis is not healthy: run  make heal  first"; exit 1; }
  if ! probe_running; then warn "the probe is not running, so there will be no RTO/RPO numbers.  make writer-start"; sleep 2; fi
}

# Postgres accepts writes through HAProxy (primary routed and not in recovery)
can_write() { [ "$(docker exec -i tools psql -X -qAt -d postgres -c 'select not pg_is_in_recovery()' 2>/dev/null)" = "t" ]; }
# wait until writes work again AND the probe has logged a few successes, so reports are not cut off mid-recovery
settle() {
  wait_for 90 "writes work again through HAProxy" can_write || return 1
  sleep 5
}

# seconds since a recorded start time, plus a margin: the right --since for report.sh
since_arg() { printf '%.0f' "$(echo "$(now) - $1 + 20" | bc -l)"; }

# raw address Sentinel reports for the master (an IP or a name); unlike sentinel_master it never guesses
sentinel_master_addr() {
  local s
  for s in $SENTINELS; do
    running "$s" || continue
    docker exec "$s" redis-cli -p 26379 --no-auth-warning sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1 | grep . && return
  done
}
container_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "hagod").IPAddress}}' "$1" 2>/dev/null; }

# fixed addresses (compose.yml) so a reconnected container gets its old IP back
node_ip() {
  case "$1" in
    redis1) echo 172.30.0.11;; redis2) echo 172.30.0.12;; redis3) echo 172.30.0.13;;
    etcd1) echo 172.30.0.21;; etcd2) echo 172.30.0.22;; etcd3) echo 172.30.0.23;;
    pg1) echo 172.30.0.31;; pg2) echo 172.30.0.32;; pg3) echo 172.30.0.33;;
    sentinel1) echo 172.30.0.51;; sentinel2) echo 172.30.0.52;; sentinel3) echo 172.30.0.53;;
  esac
}
# put a container back on the lab network with its old name and address
net_reconnect() { docker network connect --alias "$1" --ip "$(node_ip "$1")" hagod "$1"; }
