#!/bin/sh
# Starts redis-server or redis-sentinel. A restarted data node must NOT assume its old
# role: it asks the sentinels who the master is now and joins as a replica if it is not.
set -e
ROLE="$1"           # server | sentinel
NAME="$(hostname)"

if [ "$ROLE" = "sentinel" ]; then
  [ -f /data/sentinel.conf ] || cp /config/sentinel.conf /data/sentinel.conf
  exec redis-sentinel /data/sentinel.conf
fi

cp /config/redis.conf /data/redis.conf
MASTER=""
for s in sentinel1 sentinel2 sentinel3; do
  ADDR=$(redis-cli -h "$s" -p 26379 --no-auth-warning sentinel get-master-addr-by-name mymaster 2>/dev/null | tr '\n' ' ' || true)
  [ -n "$ADDR" ] && { MASTER="$ADDR"; break; }
done

if [ -n "$MASTER" ]; then
  HOST=$(echo "$MASTER" | awk '{print $1}'); PORT=$(echo "$MASTER" | awk '{print $2}')
  MYIP=$(getent hosts "$NAME" | awk '{print $1}')
  if [ "$HOST" != "$MYIP" ] && [ "$HOST" != "$NAME" ]; then
    echo "entrypoint: sentinels say master is $HOST:$PORT, starting $NAME as its replica"
    exec redis-server /data/redis.conf --replicaof "$HOST" "$PORT"
  fi
  echo "entrypoint: sentinels say $NAME is the master, starting as master"
  exec redis-server /data/redis.conf
fi

# no sentinel knows anything yet (first start): redis1 is the initial master
if [ "$NAME" = "redis1" ]; then
  echo "entrypoint: first start, redis1 is the master"
  exec redis-server /data/redis.conf
fi
echo "entrypoint: first start, $NAME replicates redis1"
exec redis-server /data/redis.conf --replicaof redis1 6379
