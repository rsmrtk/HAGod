"""Reads /data/probe.log and answers the two questions that matter after any failure:

  RTO  how long could the application NOT write?   (outage windows, as the client saw them)
  RPO  how many writes did we promise and then lose?  (acknowledged writes missing afterwards)

Usage inside the container:  python /app/report.py [--since SECONDS]
"""
import os
import sys
import time

import psycopg2
from redis.sentinel import Sentinel

LOG = "/data/probe.log"


def parse(since):
    rows = []
    cutoff = time.time() - since if since else 0
    with open(LOG) as f:
        for line in f:
            p = line.split()
            if len(p) < 4:
                continue
            t = float(p[0])
            if t >= cutoff:
                rows.append((t, p[1], int(p[2]), p[3] == "ok", p[4] if len(p) > 4 else ""))
    return rows


def outages(rows, kind):
    """A window starts at the first failure after a success and ends at the next success."""
    res, start, last_err, n = [], None, "", 0
    for t, k, _, ok, detail in rows:
        if k != kind:
            continue
        if not ok:
            if start is None:
                start, n = t, 0
            n += 1
            last_err = detail
        elif start is not None:
            res.append((start, t, t - start, n, last_err))
            start = None
    if start is not None:
        res.append((start, None, None, n, last_err))
    return res


def missing_pg(acked):
    conn = psycopg2.connect(host=os.environ["PG_HOST"], port=int(os.environ["PG_PORT"]), user="postgres",
                            password=os.environ["PG_PASSWORD"], dbname="postgres", connect_timeout=3)
    with conn.cursor() as cur:
        cur.execute("SELECT seq FROM probe.pg_writes WHERE seq = ANY(%s)", (list(acked),))
        have = {r[0] for r in cur.fetchall()}
    conn.close()
    return sorted(set(acked) - have)


def missing_redis(acked):
    s = Sentinel([("sentinel1", 26379), ("sentinel2", 26379), ("sentinel3", 26379)], socket_timeout=2,
                 sentinel_kwargs={"password": os.environ["REDIS_PASSWORD"]})
    m = s.master_for("mymaster", password=os.environ["REDIS_PASSWORD"], socket_timeout=3)
    pipe = m.pipeline(transaction=False)
    for q in acked:
        pipe.exists(f"probe:{q}")
    have = pipe.execute()
    return [q for q, h in zip(acked, have) if not h]


def main():
    since = None
    if "--since" in sys.argv:
        since = float(sys.argv[sys.argv.index("--since") + 1])
    rows = parse(since)
    if not rows:
        print("no probe data yet: run `make writer-start` and wait a few seconds")
        return
    span = rows[-1][0] - rows[0][0]
    print(f"probe window: {span:.0f}s, {len(rows) // 2} attempts per database\n")

    for kind, label in (("pg", "POSTGRES"), ("redis", "REDIS")):
        mine = [r for r in rows if r[1] == kind]
        ok = sum(1 for r in mine if r[3])
        print(f"== {label}: {ok}/{len(mine)} writes acknowledged")
        oo = outages(rows, kind)
        if not oo:
            print("   no outage seen by the client")
        for a, b, dur, n, err in oo:
            when = time.strftime("%H:%M:%S", time.localtime(a))
            if dur is None:
                print(f"   OUTAGE from {when} and STILL DOWN ({n} failed writes) last error: {err}")
            else:
                print(f"   OUTAGE at {when}: {dur:5.1f} s without writes ({n} failed attempts)  <- RTO as the client saw it   [{err}]")
        acked = [r[2] for r in mine if r[3]]
        try:
            lost = missing_pg(acked) if kind == "pg" else missing_redis(acked)
            if lost:
                print(f"   LOST WRITES: {len(lost)} acknowledged writes are gone (first seq {lost[0]}, last {lost[-1]})  <- RPO > 0")
            else:
                print(f"   lost writes: 0 of {len(acked)} acknowledged  <- RPO = 0")
        except Exception as e:  # noqa: BLE001
            print(f"   cannot verify writes right now ({str(e).splitlines()[0][:70]}): try again when the cluster is back")
        print()


if __name__ == "__main__":
    main()
