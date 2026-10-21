#!/usr/bin/env bash
# What is in my databases? Tables with sizes, Redis keys grouped by type.
source "$(dirname "$0")/lib.sh"
printf '\n%s== POSTGRES: database "bank" (through HAProxy -> primary %s) ==%s\n' "$c_bold" "$(pg_leader)" "$c_off"
docker exec tools psql -X -d bank -P pager=off -c '\x off' -c "
SELECT schema, \"table\", approx_rows AS rows, total, heap, indexes FROM ops.table_sizes ORDER BY schema, \"table\";"
printf '%s== POSTGRES: who is connected, is replication healthy ==%s\n' "$c_bold" "$c_off"
docker exec tools psql -X -d bank -P pager=off -c '\x off' -c "SELECT * FROM ops.node;" -c "SELECT replica, state, sync_state, replay_lag_bytes, replay_lag FROM ops.replication;"
printf '\n%s== REDIS: master %s ==%s\n' "$c_bold" "$(sentinel_master)" "$c_off"
docker exec tools bash -c '
M=$(redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster | head -1)
echo "keys in db0: $(redis-cli -h $M dbsize)"
printf "\n%-26s %-8s %8s  %-10s %s\n" "KEY PATTERN" "TYPE" "COUNT" "TTL?" "EXAMPLE"
redis-cli -h $M --scan --count 1000 | sed "s/^/TYPE /" > /tmp/k.txt
redis-cli -h $M --scan --count 1000 > /tmp/keys.txt
sed "s/^/TYPE /" /tmp/keys.txt | redis-cli -h $M > /tmp/types.txt
sed "s/^/TTL /" /tmp/keys.txt | redis-cli -h $M > /tmp/ttls.txt
paste -d"|" /tmp/keys.txt /tmp/types.txt /tmp/ttls.txt | awk -F"|" "{ k=\$1; sub(/[:-][^:-]*\$/, \":*\", k); if (k==\$1) k=\$1; n[k]++; t[k]=\$2; if (\$3==-1) np[k]++; ex[k]=\$1 } END { for (k in n) printf \"%-26s %-8s %8d  %-10s %s\\n\", k, t[k], n[k], (np[k]==n[k]?\"no TTL\":(np[k]>0?\"mixed\":\"has TTL\")), ex[k] }" | sort
'
echo
