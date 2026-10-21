#!/usr/bin/env bash
# 1) take a base backup  2) keep working  3) somebody makes a terrible mistake  -> you restore to just before it
source "$(dirname "$0")/../../scripts/lib.sh"
drill_preflight
R=$(pg_replicas | head -1)
BK="base-$(date +%Y%m%d-%H%M%S)"

step "STEP 1: base backup from the replica $R (so the primary is not burdened): pg_basebackup -> /backup/$BK"
docker exec -e PGPASSWORD=hagod-repl tools pg_basebackup -h "$R" -p 5432 -U replicator -D "/backup/$BK" -Fp -X stream -c fast -P 2>&1 | tail -2
docker exec tools test -f "/backup/$BK/PG_VERSION" || { bad "the base backup failed (see the error above); nothing was broken"; exit 1; }
state_set d10_backup "$BK"
ok "backup done ($(docker exec tools du -sh /backup/$BK | cut -f1))"

step "STEP 2: life goes on: new transactions arrive after the backup"
docker exec tools psql -X -q -d bank -c "insert into core.transactions(account_id, amount, kind) select 1 + (g % 25000), 10, 'deposit' from generate_series(1, 20000) g"
sleep 3
GOOD=$(psql_primary -c "select now()")
CNT=$(psql_primary -c "select count(*) from core.transactions")
state_set d10_target "$GOOD"; state_set d10_count "$CNT"
ok "the last good moment is $GOOD, with $CNT rows in core.transactions"
sleep 5

step "STEP 3: THE MISTAKE: someone drops the table in production"
psql_primary -c "drop table core.transactions cascade" >/dev/null
docker exec tools psql -X -q -d bank -c "select pg_switch_wal()" >/dev/null   # make sure the WAL holding the drop is archived
sleep 8
psql_primary -c "select to_regclass('core.transactions') is null" | sed 's/t/the table is GONE from the live database/'
echo
cat <<TXT
Replication will not save you: the DROP was replicated to every replica within milliseconds.
Only a backup + the WAL archive can bring it back, to a moment BEFORE the mistake.

Your job: restore the table WITHOUT touching the live cluster.
   ./drills/10-backup-and-pitr/restore.sh        (read it first: it is the recipe)
   make verify-10
TXT
