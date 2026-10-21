#!/usr/bin/env bash
# RTO / RPO report from the probe. `./scripts/report.sh --since 120` looks at the last 2 minutes.
source "$(dirname "$0")/lib.sh"
probe_running || { warn "the probe is not running: make writer-start"; exit 1; }
docker exec writer python /app/report.py "$@"
