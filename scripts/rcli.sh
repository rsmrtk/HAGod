#!/usr/bin/env bash
# redis-cli on whichever node Sentinel says is the master. `./scripts/rcli.sh redis2` picks a node.
if [ -n "$1" ]; then exec docker exec -it tools redis-cli -h "$1" "${@:2}"; fi
exec docker exec -it tools bash -c 'M=$(redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster | head -1); echo "master is $M"; exec redis-cli -h $M'
