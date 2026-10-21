#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
R=$(pg_replicas | head -1)
state_set d07_replica "$R"; state_set d07_t0 "$(now)"
step "destroying the data of replica $R: deleting global/pg_control (the file Postgres cannot start without) and killing Postgres"
docker exec "$R" rm -f /var/lib/postgresql/data/pgdata/global/pg_control
docker exec "$R" pkill -9 -f 'postgres -D' || true
ok "$R is broken. Patroni will keep trying to restart Postgres and keep failing."
cat <<TXT

Watch it:  make watch   and   docker logs -f $R     (look for 'start failed')
Your job:  fix it WITHOUT touching the other nodes. The tool for this is  patronictl reinit  (see docs/02-patroni.md)
Then:      make verify-07
TXT
