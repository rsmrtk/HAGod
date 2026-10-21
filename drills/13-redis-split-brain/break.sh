#!/usr/bin/env bash
# usage: break.sh [plain|protected]
source "$(dirname "$0")/../../scripts/lib.sh"
MODE="${1:-plain}"
drill_preflight
M=$(redis_master); state_set d13_old "$M"; state_set d13_oldip "$(container_ip "$M")"; state_set d13_t0 "$(now)"; state_set d13_mode "$MODE"
if [ "$MODE" = "protected" ]; then
  step "protection ON: min-replicas-to-write 1, min-replicas-max-lag 5 (the master refuses writes if no replica acked in 5 s)"
  docker exec "$M" redis-cli --no-auth-warning config set min-replicas-to-write 1 >/dev/null
  docker exec "$M" redis-cli --no-auth-warning config set min-replicas-max-lag 5 >/dev/null
else
  step "protection OFF (the default)"
fi
step "partition: $M is cut away from the replicas and sentinels, but a 'stale' client keeps talking to it"
docker network create part-a >/dev/null 2>&1 || true
docker network disconnect hagod "$M"
docker network connect --alias "$M" part-a "$M"
docker network connect part-a tools
docker exec -d tools bash -c "i=0; while true; do i=\$((i+1)); redis-cli -h $M -t 1 set stale:\$i \$i >> /tmp/stale-writes.log 2>&1; sleep 0.2; done"
ok "the stale client writes stale:1, stale:2, ... directly to the isolated $M every 0.2 s"
cat <<TXT

Meanwhile the real application (the probe, through Sentinel) is moving to a new master.
Wait ~30 s, then:   make verify-13
TXT
