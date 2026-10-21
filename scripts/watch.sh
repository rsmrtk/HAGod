#!/usr/bin/env bash
# Live dashboard. Run it in a second terminal while a drill breaks things.
#   ./scripts/watch.sh          refresh every 1.5 s
#   ./scripts/watch.sh --once   print one frame
source "$(dirname "$0")/lib.sh"
ONCE=0; [ "$1" = "--once" ] && ONCE=1

paint() { # colour a word by meaning
  case "$1" in
    Leader|master|running|healthy|streaming|ok|UP|OK|connected) printf '%s%s%s' "$c_grn" "$1" "$c_off";;
    replica|Replica|slave|sync|up) printf '%s%s%s' "$c_cyn" "$1" "$c_off";;
    DOWN|down|unhealthy|fail|stopped|"not running"|disconnected|s_down|o_down) printf '%s%s%s' "$c_red" "$1" "$c_off";;
    *) printf '%s%s%s' "$c_ylw" "$1" "$c_off";;
  esac
}

frame() {
  printf '%sHAgod%s  %s   %s(Ctrl-C to quit; break something in another terminal)%s\n\n' "$c_bold" "$c_off" "$(date +%H:%M:%S)" "$c_dim" "$c_off"

  # ---- etcd: the lock Patroni lives on
  printf '%sETCD%s (leader lock for Postgres; needs 2 of 3)\n  ' "$c_bold" "$c_off"
  for n in $ETCD_NODES; do
    if running "$n" && docker exec "$n" etcdctl --endpoints=127.0.0.1:2379 --command-timeout=1s endpoint health >/dev/null 2>&1; then
      printf '%s: %s   ' "$n" "$(paint healthy)"
    else printf '%s: %s   ' "$n" "$(paint DOWN)"; fi
  done; printf '\n\n'

  # ---- Patroni: what each node says about itself
  printf '%sPOSTGRES / PATRONI%s   (each node reports for itself, so a cut-off node can disagree)\n' "$c_bold" "$c_off"
  printf '  %-5s %-9s %-10s %-3s %-12s %s\n' NODE ROLE STATE TL REPLICATION "WAL position"
  for n in $PG_NODES; do
    j=$(curl -s --max-time 1 "localhost:$(pg_port "$n")/patroni" 2>/dev/null)
    if [ -z "$j" ]; then
      printf '  %-5s %s\n' "$n" "$(paint DOWN) (no answer on :$(pg_port "$n"))"
    else
      role=$(echo "$j" | jq -r '.role'); state=$(echo "$j" | jq -r '.state'); tl=$(echo "$j" | jq -r '.timeline // "-"')
      repl=$(echo "$j" | jq -r '.replication_state // "-"'); lsn=$(echo "$j" | jq -r '.xlog.replayed_location // .xlog.location // "-"')
      lag=$(echo "$j" | jq -r 'if .xlog.replayed_location and .xlog.received_location then (.xlog.received_location - .xlog.replayed_location) else "" end')
      printf '  %-5s %-18s %-19s %-3s %-21s %s %s\n' "$n" "$(paint "$role")" "$(paint "$state")" "$tl" "$(paint "$repl")" "$lsn" "${lag:+(unreplayed ${lag}B)}"
    fi
  done
  lead=$(pg_leader); [ -z "$lead" ] && lead="${c_red}NONE${c_off}"
  printf '  HAProxy sends writes to: %s%s%s\n' "$c_bold" "$lead" "$c_off"
  st=$(docker exec tools patronictl list -f json 2>/dev/null | jq -r '[.[]|select(.Role=="Sync Standby")|.Member]|join(",")')
  [ -n "$st" ] && printf '  Synchronous standby: %s\n' "$st"
  printf '\n'

  # ---- Redis data nodes
  printf '%sREDIS%s\n' "$c_bold" "$c_off"
  printf '  %-7s %-8s %-10s %-9s %-11s %-9s %s\n' NODE ROLE LINK REPLICAS OFFSET MEMORY KEYS
  for n in $REDIS_NODES; do
    if ! running "$n"; then printf '  %-7s %s\n' "$n" "$(paint DOWN)"; continue; fi
    i=$(docker exec "$n" sh -c 'redis-cli --no-auth-warning info replication; redis-cli --no-auth-warning info memory | grep ^used_memory_human; redis-cli --no-auth-warning dbsize' 2>/dev/null | tr -d '\r')
    role=$(echo "$i" | sed -n 's/^role://p'); link=$(echo "$i" | sed -n 's/^master_link_status://p')
    sl=$(echo "$i" | sed -n 's/^connected_slaves://p'); off=$(echo "$i" | sed -n 's/^master_repl_offset://p')
    mem=$(echo "$i" | sed -n 's/^used_memory_human://p'); keys=$(echo "$i" | tail -1)
    [ -z "$role" ] && { printf '  %-7s %s\n' "$n" "$(paint DOWN) (no answer)"; continue; }
    printf '  %-7s %-17s %-19s %-9s %-11s %-9s %s\n' "$n" "$(paint "$role")" "$(paint "${link:--}")" "${sl:--}" "$off" "$mem" "$keys"
  done
  masters=$(redis_masters | tr '\n' ' ')
  [ "$(echo $masters | wc -w | tr -d ' ')" -gt 1 ] && printf '  %sSPLIT BRAIN: more than one node believes it is master: %s%s\n' "$c_red" "$masters" "$c_off"
  printf '\n'

  # ---- Sentinel: who the guards agree on
  printf '%sSENTINEL%s\n  ' "$c_bold" "$c_off"
  for s in $SENTINELS; do
    if running "$s"; then
      a=$(docker exec "$s" redis-cli -p 26379 --no-auth-warning sentinel get-master-addr-by-name mymaster 2>/dev/null | head -1)
      printf '%s -> master %s   ' "$s" "$(paint "$(redis_name_of "$a")")"
    else printf '%s: %s   ' "$s" "$(paint DOWN)"; fi
  done
  q=$(docker exec sentinel1 redis-cli -p 26379 --no-auth-warning sentinel ckquorum mymaster 2>/dev/null | head -1)
  printf '\n  quorum check: %s\n\n' "${q:-no answer from sentinel1}"

  # ---- the probe
  printf '%sPROBE%s (the app writing to both databases, last 10 s)\n' "$c_bold" "$c_off"
  if probe_running; then
    docker exec writer sh -c 'tail -n 120 /data/probe.log' 2>/dev/null | awk -v now="$(now)" '
      now-$1<=10 { n[$2]++; if ($4=="ok") ok[$2]++; else { f[$2]++; e[$2]=$5 } if ($4=="ok") last[$2]=$1 }
      END { for (k in n) { printf "  %-6s %3d/%-3d writes ok", k, ok[k], n[k]; if (f[k]) printf "   %d failing: %s", f[k], e[k]; printf "\n" } }' | sort
  else
    printf '  %snot running: start it with  make writer-start%s\n' "$c_dim" "$c_off"
  fi
}

if [ $ONCE = 1 ]; then frame; exit 0; fi
trap 'printf "\033[?25h"; exit 0' INT TERM
printf '\033[?25l'
while true; do
  out=$(frame)
  printf '\033[H\033[J%s\n' "$out"
  sleep 1
done
