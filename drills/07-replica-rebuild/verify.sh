#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
R=$(state_get d07_replica); T0=$(state_get d07_t0)
[ -z "$R" ] && { bad "run the break step first: make drill-07"; exit 1; }
S=$(docker exec tools patronictl list -f json | jq -r ".[]|select(.Member==\"$R\")|.State")
echo "state of $R now: $S"
if [ "$S" != "streaming" ]; then
  warn "$R is not healthy yet. The fix is:   docker exec tools patronictl reinit hagod $R --force"
  read -p "Run it for you? [y/N] " a
  [ "$a" = "y" ] && docker exec tools patronictl reinit hagod "$R" --force 2>&1 | tail -3
fi
wait_for 300 "$R is a streaming replica again" bash -c "docker exec tools patronictl list -f json | jq -e '.[]|select(.Member==\"$R\" and .State==\"streaming\")'"
printf '  total time since the break: %s s\n' "$(elapsed_since "$T0")"
docker exec tools patronictl list | tail -6
cat <<TXT

Questions:
  1. What did reinit actually do? (docker logs $R | grep -iE 'basebackup|replica|clone')  How long would it take on 2 TB?
  2. Is there anything faster than a full copy? (pg_rewind, delta restore from a backup: see drill 10)
  3. Did the application notice? (probe report: make report)
TXT
