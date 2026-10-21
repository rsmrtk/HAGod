# Каталог режимів відмови

Для кожної відмови: що ви **бачите**, як **підтвердити**, що **робити** і який drill це репетирує. Роздрукуйте.

## Postgres / Patroni

| Відмова | Симптом | Підтвердити | Що робити | Drill |
|---|---|---|---|---|
| Primary падає | записи падають ~25 с, потім відновлюються | `patronictl list` (новий лідер, TL+1), `patronictl history` | чекати; потім повернути старий вузол, він приєднається як репліка | 01 |
| Планове обслуговування | нічого, якщо зроблено правильно | `patronictl list` | спершу `switchover`, потім працювати зі старим primary | 02 |
| etcd втрачає кворум | **усі вузли — репліки, записи одразу падають**, Postgres працює | `etcdctl endpoint health --cluster`; лог Patroni `DCS is not accessible` | полагодити etcd; Patroni відновиться сам | 03 |
| Primary ізольований | вузол зупиняє Postgres; інші обирають новий primary | вузол недоступний; `patronictl list` | відновити мережу; старий вузол робить rewind або клонується заново | 04 |
| Async-репліка втратила дані при failover | підтверджені записи зникли | порівняти з логами застосунку; `LOST WRITES` у `make report` | прийняти або ввімкнути `synchronous_mode_strict` | 05 |
| Lag реплік росте | застарілі читання, lag у `ops.replication` зростає | `ops.replication`, `pg_stat_wal_receiver`, довгий запит на репліці | знайти призупинений replay / важкий запит / повільний диск; не робити failover на відстаючий вузол | 06 |
| Репліка не стартує | `State: start failed` | `docker logs pgN` | `patronictl reinit hagod pgN` | 07 |
| `pg_wal` заповнює диск | тривога по диску, потім Postgres зупиняється | `du pg_wal`; `ops.slots` (неактивний slot?); `ops.archiver` (падає?) | видалити осиротілий slot / полагодити `archive_command` | 08 |
| Сесії накопичуються за блокуванням | застосунок «висне», з'єднання ростуть | `ops.blocked`, `ops.activity` (`idle in transaction`) | завершити **блокувальника**; виставити `idle_in_transaction_session_timeout` | 09 |
| Хтось видалив таблицю | помилки «відношення не існує» | `select to_regclass(...)` | PITR на тимчасовий сервер, скопіювати таблицю назад | 10 |
| HAProxy помирає | усі клієнти падають; Postgres і Patroni виглядають нормально | `docker ps`, `curl :7100` | перезапустити; у проді тримати два з VIP | game day |
| Два primary (split brain) | записи потрапляють на два вузли | `curl /primary` на кожному вузлі; `patronictl list` | **негайно** зупинити хибний, потім перебудувати. Не має траплятись зі здоровим DCS | н/д |
| Диск primary заповнений | записи падають, Postgres аварійно завершується | `df`, `pg_wal` | звільнити місце (ніколи не видаляйте WAL вручну), знайти причину (slots/архів) | 08 |
| Досягнуто max connections | `FATAL: sorry, too many clients` | `select count(*) from pg_stat_activity` | знайти витік; додати pooler (PgBouncer) | |
| Наближається wraparound | `autovacuum to prevent wraparound` у логу | `select age(datfrozenxid) from pg_database` | дати autovacuum завершити; ніколи не скасовувати; додати ресурси | |

## Redis / Sentinel

| Відмова | Симптом | Підтвердити | Що робити | Drill |
|---|---|---|---|---|
| Master падає | записи падають ~6 с | `SENTINEL GET-MASTER-ADDR-BY-NAME`, лог sentinel `+switch-master` | чекати; перезапустити старий вузол: він приєднається як репліка | 11 |
| Втрачено кворум Sentinel | master позначено `s_down`, **failover нема** | `SENTINEL CKQUORUM` каже `NOQUORUM` | повернути sentinel'и; ніколи не працювати з менше ніж 3 | 12 |
| Розділення мережі | два master; клієнти не згодні | `ROLE` на обох; застарілі записи | відновити зв'язок; прийняти втрату на боці меншості; виставити `min-replicas-to-write` | 13 |
| Закінчилась пам'ять | `OOM command not allowed` | `INFO memory`, `INFO stats` evicted_keys | правильна політика для кожного навантаження; TTL; знайти великі ключі | 14 |
| Повільна команда | сплеск затримки, **failover при здоровому вузлі** | `SLOWLOG GET`, `LATENCY LATEST`, лог sentinel | знайти й заборонити команду; `SCAN`, `UNLINK`; підлаштувати `down-after` | 15 |
| Репліка втратила зв'язок | `master_link_status:down` | `INFO replication` на репліці | перевірити мережу, `repl-backlog-size`, ліміти вихідного буфера | |
| Цикл повного ресинку | сплески CPU/IO, репліка постійно ресинхронізується | лог master `Client ... scheduled to be closed ASAP for overcoming of output buffer limits` | збільшити `client-output-buffer-limit replica` і backlog | |
| Втрата даних після рестарту | ключі зникли | `INFO persistence` | увімкнути AOF, `appendfsync everysec`; відновити з бекапу | |
| Sentinel TILT | нема failover'ів 30 с, повторюється | `+tilt` у логу sentinel | знайти заблокований цикл (DNS, нестача CPU, годинник VM) | (див. architecture) |

## Дерева рішень

**«Застосунок не може писати в Postgres»**
```
patronictl list
 ├─ нема Leader ─────────► etcd здоровий? ─ ні ─► полагодити etcd (drill 03)
 │                                        └ так ─► почекати ttl (30 с); failover лише якщо репліка стрімить з lag 0
 ├─ Leader ок ──────────► curl :5000 через HAProxy падає? ─ так ─► HAProxy впав/не знає (:7100)
 │                                                          └ ні ─► застосунок: пул з'єднань, DNS, облікові дані
 └─ Leader ок, записи повільні ─► ops.blocked (блокування) · ops.activity · затримка диска · ops.replication (sync standby відстає?)
```

**«Застосунок не може дістатись Redis / він повільний»**
```
SENTINEL GET-MASTER-ADDR-BY-NAME mymaster ─► той вузол живий?
 ├─ ні ──► SENTINEL MASTER (s_down? o_down?) ─► CKQUORUM ─► лог sentinel
 ├─ так, повільно ─► SLOWLOG GET · LATENCY LATEST · INFO commandstats · CLIENT LIST (заблоковані?)
 └─ так, помилки ─► INFO memory (OOM?) · min-replicas-to-write відмовляє? (NOREPLICAS)
```
