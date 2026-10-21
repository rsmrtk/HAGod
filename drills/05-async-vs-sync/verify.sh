#!/usr/bin/env bash
source "$(dirname "$0")/../../scripts/lib.sh"
P=$(state_get d05_primary); T0=$(state_get d05_t0); MODE=$(state_get d05_mode)
[ -z "$P" ] && { bad "run the break step first: make drill-05"; exit 1; }
new_leader() { local l; l=$(pg_leader) || return 1; [ "$l" != "$P" ]; }
wait_for 150 "a new primary is elected" new_leader || exit 1
settle
printf '\n  mode: %s%s%s   new primary: %s\n\n' "$c_bold" "$MODE" "$c_off" "$(pg_leader)"
./scripts/report.sh --since "$(since_arg "$T0")"
cat <<TXT
$([ "$MODE" = "async" ] && echo "Look at the POSTGRES 'LOST WRITES' line. Those writes were acknowledged to the application and are GONE.
Run again in strict mode and compare:   make heal && ./drills/05-async-vs-sync/break.sh strict" || echo "In strict mode writes FAILED during the cut (availability traded for safety) and the lost-writes line should say 0.
That is the whole trade-off: strict = no data loss, but the primary stops accepting writes when it has no synchronous standby.")

Clean up:   docker start $P   (or make heal)
Questions:
  1. Which is worse for a bank: a few seconds of failed writes or a few lost payments? Who decides, you or the business?
  2. What does non-strict synchronous_mode do when the sync standby disappears? (read the Patroni docs on synchronous_mode)
  3. What would you alert on to notice that a replica has been disconnected for a long time?
TXT
