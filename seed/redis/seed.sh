#!/bin/bash
# Fills Redis with one key of (almost) every type, shaped like a bank's cache layer.
# Runs inside the toolbox container; `make seed` calls it.
set -e
MASTER=$(redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster | head -1)
echo "seeding Redis master $MASTER"

# RESP generator: turns "SET a b" lines on stdin into the protocol redis-cli --pipe expects.
resp() { awk '{ n=NF; printf "*%d\r\n", n; for(i=1;i<=n;i++) printf "$%d\r\n%s\r\n", length($i), $i }'; }

{
  # sessions: strings with a TTL (they expire on their own)
  for i in $(seq 1 3000); do echo "SET session:$(printf '%08x' $((i*2654435761 % 4294967295))) user-$((i % 800)) EX $((300 + i % 3300))"; done
  # account cache: one hash per account
  for i in $(seq 1 5000); do echo "HSET account:$i balance $((RANDOM*7 % 90000)) currency UAH status active updated_at 2026-10-18T10:00:00Z"; done
  # rate limits: short-lived counters per client IP
  for i in $(seq 1 300); do echo "SET ratelimit:10.0.$((i/250)).$((i%250)) $((RANDOM % 100)) EX 60"; done
  # leaderboard: sorted set
  for i in $(seq 1 2000); do echo "ZADD leaderboard:top_spenders $((RANDOM*3 % 100000)) customer:$i"; done
  # payment queue: list used as a FIFO queue
  for i in $(seq 1 500); do echo "RPUSH queue:payments payment-$i"; done
  # online users: set
  for i in $(seq 1 800); do echo "SADD set:online_users customer:$((i*7 % 10000))"; done
  # event stream + a consumer group
  for i in $(seq 1 1500); do echo "XADD stream:events * type transfer account $((i % 5000)) amount $((RANDOM % 900))"; done
  echo "XGROUP CREATE stream:events workers 0"
  # hyperloglog, bitmap, geo
  for i in $(seq 1 1000); do echo "PFADD hll:daily_visitors visitor-$i"; done
  for i in $(seq 1 200); do echo "SETBIT bitmap:logins:2026-10-18 $((i*13 % 5000)) 1"; done
  echo "GEOADD geo:atms 30.5234 50.4501 atm-kyiv 24.0297 49.8397 atm-lviv 17.1077 48.1486 atm-bratislava"
  # config / hot key: read thousands of times per second in real life
  echo "SET hotkey:config:fees '{\"transfer\":0.5,\"withdraw\":1.0}'"
  # NO TTL on purpose: a cache that never expires is a classic memory problem
  for i in $(seq 1 1500); do echo "SET cache:rates:pair-$i $((RANDOM % 5000))"; done
  # a BIG key: one hash with 20000 fields (try redis-cli --bigkeys, MEMORY USAGE, HSCAN)
  for i in $(seq 1 20000); do echo "HSET bigkey:audit_blob field-$i value-value-value-value-$i"; done
} | resp | redis-cli -h "$MASTER" -p 6379 --pipe 2>&1 | tail -3

echo "done. Look around with:  redis-cli -h $MASTER   (INFO keyspace, DBSIZE, SCAN 0 COUNT 20, TYPE <key>)"
