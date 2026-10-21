# Drill 04: Partition the primary

**Goal.** The dangerous failure: a node that is alive but unreachable.

## The story
A switch fails. The primary is running, perfectly healthy, and its clients on the old side still talk to it. The rest of the cluster cannot see it. What stops two primaries?

## Predict first (write it down)
- Does the isolated node keep accepting writes? For how long?
- What does the rest of the cluster do, and how fast?

## Run
```sh
make drill-04
make verify-04
```

Keep `make watch` open in a second terminal.

## Observe: commands to try yourself
```sh
docker logs pgN 2>&1 | tail -20            # on the isolated node: what Patroni decided when it lost etcd
docker exec pgN ps aux | grep postgres      # is Postgres still running there?
patronictl list -W                          # from the tools container: the survivors' view
```

## What you should see
The isolated node's Patroni cannot renew its lock, so it **stops Postgres entirely** (not just read-only). The other two elect a new primary after ~`ttl`, so the application sees about **20-30 s without writes**. After you reconnect, the old primary rejoins; `pg_rewind` or a re-clone makes it a replica. Writes sent to the isolated node in the seconds before it stopped can be lost.

## Understand
The stopping is the whole defence: Patroni **fences itself**. A node that cannot reach the DCS must stop being a primary *before* any other node becomes one. The other side only promotes after the TTL, which is longer than the time the isolated primary needs to stop. This is why `loop_wait + 2*retry_timeout <= ttl` matters: it makes the fencing finish before the election.

## Fix
Reconnect the network, watch the node rejoin (`patronictl list`). Find in its log whether it used `pg_rewind` or a full basebackup, and why.

## Your runbook
Write the three lines before you read the answers: **symptom → how to confirm → what to do.** (Template: `docs/07-runbook-template.md`.)

## Questions
1. What stopped the isolated primary from accepting writes forever?
2. How would you also protect against a primary that Patroni itself cannot stop (hung host)?
3. Which writes might be lost, and how do you find out?

---

### Answers (read after you tried)
1. Patroni's self-fencing: no lock renewal, so it demotes/stops within the timeout, before the election completes.
2. A **watchdog**: Patroni can arm a hardware/software watchdog that reboots the host if Patroni itself stops responding. Configure `watchdog:` in Patroni and a `softdog`/hardware device on the host.
3. Writes acknowledged by the old primary after the last WAL shipped to a replica. Compare with the application's logs and the `LOST WRITES` line.
