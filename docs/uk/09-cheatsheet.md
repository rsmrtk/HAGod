# Шпаргалка: команди, які ви вводитимете о 3-й ночі

Тримайте відкритою. Запускайте всередині `make shell` (psql, patronictl, redis-cli готові). Деталі й пояснення — у docs 02, 03, 04.

## Перші 60 секунд БУДЬ-ЯКОГО інциденту

```sh
make watch                                    # (лабораторія) або ваш власний дашборд
patronictl list                               # хто лідер, хто стрімить, lag
redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster
redis-cli -h sentinel1 -p 26379 sentinel ckquorum mymaster
docker exec etcd1 etcdctl endpoint health --cluster
```
Питання в такому порядку: **Чи є рівно ОДИН primary / master? Чи можуть клієнти до нього дістатись? Чи йдуть репліки за ним? Що змінилось?**

## Postgres / Patroni

| Я хочу | Команда |
|---|---|
| побачити кластер | `patronictl list` · `patronictl list -W` (наживо) · `patronictl topology` |
| хто primary | `curl -s localhost:8101/primary -o /dev/null -w '%{http_code}'` (200 = так) для кожного вузла |
| перенести primary (планово) | `patronictl switchover --leader pg1 --candidate pg2` |
| промотити, коли primary нема | `patronictl failover --candidate pg2` |
| перезапустити / перечитати вузол | `patronictl restart hagod pg2` · `patronictl reload hagod pg2` |
| переглянути / змінити налаштування | `patronictl show-config` · `patronictl edit-config -s postgresql.parameters.work_mem=64MB` |
| чи щось потребує рестарту | `patronictl list -e` (колонка Pending restart) |
| режим обслуговування вкл/викл | `patronictl pause` · `patronictl resume` |
| перебудувати зламану репліку | `patronictl reinit hagod pg2` |
| історія failover'ів | `patronictl history` |
| виконати SQL на ролі | `patronictl query hagod -r replica -c "select pg_is_in_recovery()"` |
| власний погляд Patroni | `curl -s localhost:8101/patroni \| jq` |
| лок лідера | `docker exec etcd1 etcdctl get /hagod/hagod/leader --print-value-only` |

## Postgres SQL (на primary, якщо не зазначено інше)

| Я хочу | SQL |
|---|---|
| вузол, роль, timeline | `select * from ops.node;` |
| стан реплікації і lag | `select * from ops.replication;` |
| replication slots, утримуваний WAL | `select * from ops.slots;` |
| архівація ок? | `select * from ops.archiver;` |
| хто підключений / зайнятий | `select * from ops.activity;` |
| хто кого блокує | `select * from ops.blocked;` |
| вбити сесію | `select pg_terminate_backend(<pid>);` (`pg_cancel_backend` м'якший) |
| idle in transaction | `select * from ops.activity where state='idle in transaction';` |
| найбільші таблиці | `select * from ops.table_sizes limit 10;` |
| dead tuples, кандидати на vacuum | `select * from ops.dead_tuples limit 10;` |
| топ запитів | `select * from ops.top_queries;` |
| cache hit ratio | `select * from ops.cache_hit;` |
| чи я репліка | `select pg_is_in_recovery();` |
| репліка: байти, ще не застосовані | `select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());` |
| розмір WAL на диску | `docker exec pg1 du -sh /var/lib/postgresql/data/pgdata/pg_wal` |
| чому повільно | `explain (analyze, buffers) <запит>;` |
| видалити невикористаний slot | `select pg_drop_replication_slot('name');` |
| примусово заархівувати WAL зараз | `select pg_switch_wal();` |

## Redis

| Я хочу | Команда |
|---|---|
| ключі, TTL | `DBSIZE` · `INFO keyspace` · `SCAN 0 MATCH pat:* COUNT 100` · `TTL key` |
| що це | `TYPE key` · `OBJECT ENCODING key` · `MEMORY USAGE key` |
| роль, репліки, lag | `ROLE` · `INFO replication` |
| пам'ять | `INFO memory` · `CONFIG GET maxmemory*` · `redis-cli --bigkeys` |
| що повільне | `SLOWLOG GET 10` · `LATENCY LATEST` · `LATENCY DOCTOR` |
| хто підключений | `CLIENT LIST` · `INFO clients` |
| персистентність | `INFO persistence` · `LASTSAVE` · `BGSAVE` |
| напівсинхронний запис | `SET k v` потім `WAIT 1 100` |
| вигляд наживо | `redis-cli --stat` · `redis-cli --latency` |
| **Sentinel**: master зараз | `SENTINEL GET-MASTER-ADDR-BY-NAME mymaster` |
| Sentinel: повний стан | `SENTINEL MASTER mymaster` (flags: s_down/o_down) |
| Sentinel: репліки, інші sentinel'и | `SENTINEL REPLICAS mymaster` · `SENTINEL SENTINELS mymaster` |
| Sentinel: чи можемо зробити failover | `SENTINEL CKQUORUM mymaster` |
| Sentinel: плановий failover | `SENTINEL FAILOVER mymaster` |
| Sentinel: забути застарілі вузли | `SENTINEL RESET mymaster` |
| історія failover | `docker logs sentinel1 \| grep -E 'sdown\|odown\|elected\|switch-master\|tilt'` |

## Логи

```sh
docker logs pg1 2>&1 | grep -E "promoted|demoted|lock|rewind|failed" | tail     # рішення Patroni
docker logs pg1 2>&1 | grep -iE "ERROR|FATAL|still waiting|archive command failed" | tail
docker logs sentinel1 2>&1 | tail -30
docker logs haproxy | tail
```

## Небезпечні команди: зупинись і подумай

| Команда | Чим шкодить |
|---|---|
| `patronictl failover` | може втратити закомічені записи (async) |
| `patronictl reinit` | видаляє каталог даних цього вузла |
| `patronictl remove` | видаляє стан усього кластера з etcd |
| `patronictl pause` і забутий `resume` | впалий primary ніколи не замінять |
| `DROP/TRUNCATE/DELETE` без `where` | немає скасування, окрім відновлення (drill 10) |
| `vacuum full` | ексклюзивне блокування таблиці |
| `select pg_terminate_backend(pid) from pg_stat_activity` (без фільтра) | вбиває **всіх**, зокрема реплікацію |
| `REPLICAOF` на вузлі під керуванням Sentinel | б'ється із Sentinel |
| `FLUSHALL` / `FLUSHDB` | миттєво реплікується на кожну репліку |
| `KEYS *` | блокує Redis; Sentinel може зробити failover |
| `DEBUG SLEEP`, `SHUTDOWN` | аварія власними руками |
| `etcdctl del --prefix ...` | стирає стан Patroni |

## Числа, які варто пам'ятати (ця лабораторія)

| | |
|---|---|
| Failover при аварії Postgres | ~25 с (ttl 30) |
| Плановий switchover | ~3 с, ~4 с помилок у клієнта |
| Втрата кворуму etcd | записи зупиняються **одразу**; нічого не втрачається |
| Failover при аварії Redis master | ~6 с (`down-after` 5 с) |
| Redis `min-replicas-to-write` | ізольований master відмовляє в записах після `min-replicas-max-lag` |
| Втрата при async-реплікації в лабораторії | ~100 записів при 20-секундному розриві (drill 05); ~130 при split brain у Redis (drill 13) |
