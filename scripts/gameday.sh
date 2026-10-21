#!/usr/bin/env bash
# Game day: the lab breaks in a way you are NOT told. Diagnose it from `make watch`, psql and redis-cli only.
#   ./scripts/gameday.sh start       pick a random failure and cause it
#   ./scripts/gameday.sh reveal      what it was, and how you should have found and fixed it
source "$(dirname "$0")/lib.sh"

SCENARIOS="pg-kill-primary pg-pause-replica pg-isolate-replica etcd-kill-one redis-kill-master redis-pause-master redis-kill-replica sentinel-kill-one haproxy-kill pg-lock-pileup redis-oom"

case "$1" in
start)
  drill_preflight
  set -- $SCENARIOS; n=$#; pick=$(( RANDOM % n + 1 )); S=$(eval echo \${$pick})
  state_set gameday "$S"; state_set gameday_t0 "$(now)"
  case "$S" in
    pg-kill-primary)   docker kill "$(pg_leader)" >/dev/null;;
    pg-pause-replica)  docker pause "$(pg_replicas | head -1)" >/dev/null;;
    pg-isolate-replica) docker network disconnect hagod "$(pg_replicas | tail -1)";;
    etcd-kill-one)     docker kill etcd$(( RANDOM % 3 + 1 )) >/dev/null;;
    redis-kill-master) docker kill "$(redis_master)" >/dev/null;;
    redis-pause-master) docker pause "$(redis_master)" >/dev/null;;
    redis-kill-replica) M=$(redis_master); for n in $REDIS_NODES; do [ "$n" != "$M" ] && { docker kill "$n" >/dev/null; break; }; done;;
    sentinel-kill-one) docker kill sentinel$(( RANDOM % 3 + 1 )) >/dev/null;;
    haproxy-kill)      docker kill haproxy >/dev/null;;
    pg-lock-pileup)
      docker exec -d tools bash -c "(echo \"begin; update practice.locks_demo set owner='A' where id=2;\"; sleep 900) | psql -X -q -d bank"
      sleep 1
      for i in 1 2 3 4 5 6; do docker exec -d tools psql -X -q -d bank -c "update practice.locks_demo set owner='W$i' where id=2"; done;;
    redis-oom)
      M=$(redis_master); U=$(docker exec "$M" redis-cli --no-auth-warning info memory | tr -d '\r' | sed -n 's/^used_memory://p')
      docker exec "$M" redis-cli --no-auth-warning config set maxmemory $((U + 2*1024*1024)) >/dev/null
      docker exec tools bash -c "for i in \$(seq 1 30000); do echo \"SET gd:\$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"; done | redis-cli -h $M >/dev/null";;
  esac
  cat <<TXT
${c_bold}GAME DAY${c_off}: something is wrong with the lab. You are not told what.

  - Start from the symptoms:   make watch   (second terminal)   make report
  - Then dig in with psql / patronictl / redis-cli (docs/02..04 are your cheat sheets)
  - Write down: WHAT broke, HOW you know, WHAT you did, HOW LONG it took
  - Fix it yourself. (make heal is the cheat code: it resets everything)

When you are done or stuck:   make gameday-reveal
TXT
  ;;
reveal)
  S=$(state_get gameday); T0=$(state_get gameday_t0)
  [ -z "$S" ] && { bad "no game day running: make gameday"; exit 1; }
  printf '\n%sIt was: %s%s   (%s s ago)\n\n' "$c_bold" "$S" "$c_off" "$(elapsed_since "$T0")"
  case "$S" in
    pg-kill-primary)    echo "The Postgres primary was killed. Symptom: HAProxy sends writes nowhere for ~25 s, then a replica leads. Drill 01.";;
    pg-pause-replica)   echo "A replica was PAUSED (docker pause): the process is frozen, not dead. Patroni sees it vanish from etcd; its REST port hangs. Fix: docker unpause. Compare with a crash.";;
    pg-isolate-replica) echo "A replica lost the network. The cluster looks 'degraded' but writes work. Fix: reconnect; then check it re-syncs from the WAL archive or a rebuild. Drill 04/06.";;
    etcd-kill-one)      echo "One etcd node died. Nothing visibly breaks (2 of 3 is still a quorum). The danger is that the NEXT failure takes the cluster read-only. Drill 03.";;
    redis-kill-master)  echo "The Redis master died; Sentinel promoted a replica. Drill 11. Which writes did the probe lose?";;
    redis-pause-master) echo "The Redis master froze (docker pause). Sentinel treats it as dead after 5 s and fails over; when you unpause, the old master must come back as a replica. Drill 15.";;
    redis-kill-replica) echo "A Redis replica died. No client impact, but you now run without a safety net: one more failure and there is no replica to promote.";;
    sentinel-kill-one)  echo "One sentinel died. Quorum (2 of 3) still holds, but you have lost your margin. Drill 12.";;
    haproxy-kill)       echo "HAProxy died. Postgres itself is healthy and Patroni sees nothing wrong, but no client can connect through port 5000/5001. The single point of failure nobody monitors.";;
    pg-lock-pileup)     echo "A forgotten transaction holds a row lock and six writers queue behind it. Drill 09. Query: select * from ops.blocked;";;
    redis-oom)          echo "Redis hit maxmemory with noeviction: writes fail with OOM. Drill 14.";;
  esac
  echo; echo "Clean up with:  make heal   (and for lock pileups:  docker exec tools psql -d bank -c \"select pg_terminate_backend(pid) from pg_stat_activity where application_name='psql' and state='idle in transaction'\")"
  state_set gameday ""
  ;;
*) echo "usage: $0 start|reveal"; exit 1;;
esac
