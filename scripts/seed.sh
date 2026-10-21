#!/usr/bin/env bash
# usage: seed.sh [all|pg|redis]
#   pg     drops and recreates the "bank" database (so it is safe to run again)
#   redis  (re)writes the training keys; existing keys with the same names are overwritten
source "$(dirname "$0")/lib.sh"
WHAT="${1:-all}"
running tools || { bad "the lab is not running: make up"; exit 1; }

seed_pg() {
  step "Postgres: (re)creating database bank"
  echo "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='bank' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS bank;
CREATE DATABASE bank;" | docker exec -i -e PGDATABASE=postgres tools psql -X -q >/dev/null
  for f in "$HAGOD_DIR"/seed/postgres/*.sql; do
    step "loading $(basename "$f")"
    docker exec -i tools psql -X -q -v ON_ERROR_STOP=1 -d bank < "$f" 2>&1 | grep -v '^$' | grep -vE '^(SET|INSERT|CREATE|ANALYZE|UPDATE)' || true
  done
}
seed_redis() {
  step "Redis: loading keys"
  docker cp "$HAGOD_DIR/seed/redis/seed.sh" tools:/tmp/redis-seed.sh >/dev/null
  docker exec -u root tools chmod +x /tmp/redis-seed.sh
  docker exec tools /tmp/redis-seed.sh
}

case "$WHAT" in
  pg) seed_pg;;
  redis) seed_redis;;
  all) seed_pg; seed_redis;;
  *) echo "usage: $0 [all|pg|redis]"; exit 1;;
esac
echo
ok "seeded. Look at it:  make overview"
