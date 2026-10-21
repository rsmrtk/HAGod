#!/usr/bin/env bash
# psql on the primary (through HAProxy :5000). Extra arguments are passed to psql.
exec docker exec -it tools psql "$@"
