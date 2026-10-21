"""The probe: a tiny application that keeps writing to both databases the way a real service would.

Every INTERVAL seconds it writes sequence number N to Postgres (through HAProxy, port 5000) and to
Redis (through Sentinel), and logs one line per attempt to /data/probe.log:

    <unix time> <pg|redis> <seq> <ok|fail> <detail>

Only writes that were ACKNOWLEDGED are "promised" to the user. report.py later checks that every
promised write still exists: a promised write that is gone is data loss (RPO > 0).
"""
import os
import sys
import time

import psycopg2
from redis.sentinel import Sentinel

INTERVAL = float(os.environ.get("INTERVAL", "0.2"))
LOG = "/data/probe.log"

PG = dict(
    host=os.environ.get("PG_HOST", "haproxy"), port=int(os.environ.get("PG_PORT", "5000")),
    user="postgres", password=os.environ["PG_PASSWORD"], dbname="postgres",
    connect_timeout=2, options="-c statement_timeout=3000",
    keepalives=1, keepalives_idle=1, keepalives_interval=1, keepalives_count=2,
)
SENTINELS = [("sentinel1", 26379), ("sentinel2", 26379), ("sentinel3", 26379)]


def log(f, kind, seq, ok, detail=""):
    f.write(f"{time.time():.3f} {kind} {seq} {'ok' if ok else 'fail'} {detail}\n")
    f.flush()


def pg_connect():
    conn = psycopg2.connect(**PG)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("CREATE SCHEMA IF NOT EXISTS probe")
        cur.execute("CREATE TABLE IF NOT EXISTS probe.pg_writes (seq bigint PRIMARY KEY, written_at timestamptz DEFAULT now(), node inet)")
    return conn


def main():
    sentinel = Sentinel(SENTINELS, socket_timeout=1.0, sentinel_kwargs={"password": os.environ["REDIS_PASSWORD"], "socket_timeout": 1.0})
    seq = int(time.time())  # unique across restarts of the probe
    conn = None
    with open(LOG, "a") as f:
        while True:
            seq += 1
            started = time.time()

            # ---- Postgres: autocommit insert; ok only after the server has acknowledged the commit
            try:
                if conn is None or conn.closed:
                    conn = pg_connect()
                with conn.cursor() as cur:
                    cur.execute("INSERT INTO probe.pg_writes(seq, node) VALUES (%s, inet_server_addr()) RETURNING node", (seq,))
                    node = cur.fetchone()[0]
                log(f, "pg", seq, True, node)
            except Exception as e:  # noqa: BLE001 - every failure is data for the report
                log(f, "pg", seq, False, str(e).strip().splitlines()[0][:80].replace(" ", "_"))
                try:
                    if conn is not None:
                        conn.close()
                except Exception:  # noqa: BLE001
                    pass
                conn = None

            # ---- Redis: SET through whoever Sentinel says is the master right now
            try:
                master = sentinel.master_for("mymaster", password=os.environ["REDIS_PASSWORD"], socket_timeout=1.0, socket_connect_timeout=1.0)
                master.set(f"probe:{seq}", seq)
                log(f, "redis", seq, True)
            except Exception as e:  # noqa: BLE001
                log(f, "redis", seq, False, str(e).strip().splitlines()[0][:80].replace(" ", "_"))

            time.sleep(max(0, INTERVAL - (time.time() - started)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
