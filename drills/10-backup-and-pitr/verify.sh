#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
EXPECT=$(state_get d10_count)
running pitr || { warn "the recovered server is not running: ./drills/10-backup-and-pitr/restore.sh"; exit 1; }
HAVE=$(docker exec pitr psql -X -h localhost -U postgres -At -d bank -c "select count(*) from core.transactions")
printf '  rows in the recovered table: %s   rows at the last good moment: %s\n' "$HAVE" "$EXPECT"
[ "$HAVE" = "$EXPECT" ] && ok "exact match: recovery stopped exactly before the DROP" || warn "different: the target time was not precise (recovery_target_time is a moment, not a transaction)"
echo
if [ "$(psql_primary -c "select to_regclass('core.transactions') is null")" = "t" ]; then
  read -p "Copy the table back into the live database now? [y/N] " a
  if [ "$a" = "y" ]; then
    docker exec pitr pg_dump -h localhost -U postgres -d bank -t core.transactions --no-owner | docker exec -i tools psql -X -q -d bank >/dev/null
    ok "restored: $(psql_primary -c 'select count(*) from core.transactions') rows in the live database"
  fi
fi
cat <<TXT

Questions:
  1. What is your real RPO for this kind of mistake? (the backup age? the archive_timeout of 60 s? the time you notice?)
  2. How long did the restore take? Extrapolate to your production database size. Is that acceptable to the business?
  3. What did the WAL archive have to contain for this to work? What if one WAL file were missing in the middle?
  4. How would you automate and TEST restores monthly? (a backup you never restored is a hope, not a backup)
Clean up:   docker rm -f pitr; docker volume rm hagod_pitrdata
TXT
