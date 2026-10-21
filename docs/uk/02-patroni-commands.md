# Patroni, etcd і HAProxy: команди, які ви справді вводитимете

Запускайте з `make shell` (контейнер із `patronictl`, `psql`, `redis-cli`) або з префіксом `docker exec tools`.
Patroni 4.1, etcd 3.5, HAProxy 3.0.

## Дванадцять, які вчити першими

| # | Команда | На що відповідає | Коли до неї тягнетесь |
|---|---|---|---|
| 1 | `patronictl list` | хто лідер, хто стрімить, який lag | **завжди першою** |
| 2 | `patronictl list -W` | те саме, оновлюється кожні 2 с | спостереження за failover |
| 3 | `patronictl topology` | дерево реплікації | каскадні репліки |
| 4 | `patronictl switchover --leader pg1 --candidate pg2` | передати лідерство **плавно** | обслуговування, патчинг primary |
| 5 | `patronictl failover --candidate pg2` | примусово призначити лідера, коли лідера нема | primary мертвий, а ніхто не перебрав |
| 6 | `patronictl restart hagod pg2` | перезапустити Postgres **під** Patroni | параметр, що потребує рестарту |
| 7 | `patronictl reload hagod pg2` | перечитати конфіг без рестарту | параметр, якому досить reload |
| 8 | `patronictl reinit hagod pg2` | стерти репліку й заново скопіювати з лідера | зламана/пошкоджена репліка |
| 9 | `patronictl edit-config` | змінити налаштування всього кластера (зберігаються в etcd) | будь-яка зміна `postgresql.parameters` |
| 10 | `patronictl show-config` | які зараз налаштування кластера | перед тим, як щось міняти |
| 11 | `patronictl pause` / `resume` | вимкнути/ввімкнути авто-failover | планові роботи, коли Patroni не повинен реагувати |
| 12 | `patronictl history` | кожен failover з timeline і часом | розбір після інциденту (post-mortem) |

## `patronictl list`: як читати таблицю

```
+ Cluster: hagod (7697...) ---+--------------+-----------+----+-------------+-----+------------+-----+
| Member | Host | Role         | State        | TL | Receive LSN | Lag | Replay LSN | Lag |
| pg1    | pg1  | Sync Standby | streaming    |  9 |  0/1E01..   |   0 |  0/1E01..  |   0 |
| pg2    | pg2  | Leader       | running      |  9 |             |     |            |     |
| pg3    | pg3  | Replica      | streaming    |  9 |  0/1E01..   |   0 |  0/1E01..  |   0 |
```

| Колонка | Здорове значення | Якщо ні |
|---|---|---|
| Role | рівно один `Leader` | жодного = нема primary (записи недоступні); дивіться etcd |
| State | лідер `running`, репліки `streaming` | `start failed` = Postgres не стартує (drill 07); `stopped`; `in archive recovery` = наздоганяє з архіву |
| TL | однаковий у всіх | нижчий TL на одному = це був старий primary, його треба відмотати (rewind) |
| Lag (receive) | 0 | WAL не надходить: мережа або primary перевантажений |
| Lag (replay) | 0 | WAL надходить, але не застосовується: призупинений replay, довгий запит на репліці, I/O |

Корисні прапорці: `-e` (розширений: теги, pending restart), `-f json` (для скриптів: `patronictl list -f json | jq`), `-t` (мітка часу).

## Планові роботи: правильний порядок

```sh
patronictl show-config                          # 1. знати поточні налаштування
patronictl list                                 # 2. переконатися, що все стрімить і lag 0
patronictl switchover --leader pg1 --candidate pg2 --force   # 3. зняти primary з вузла, з яким працюватимете
# ... патчимо, перезавантажуємо, змінюємо розмір pg1 ...
patronictl list                                 # 4. pg1 має повернутися як streaming-репліка
```

`--force` пропускає запит підтвердження. У проді його **не вказуйте** і читайте запит: він друкує, що саме станеться.
`--scheduled "2026-10-20T03:00"` планує на потім. `patronictl flush hagod switchover` скасовує запланований.

**Switchover проти failover:**

| | switchover | failover |
|---|---|---|
| Потрібен здоровий лідер | так | ні |
| Втрата даних | нема | можлива (async) |
| Простій | ~3 с | поки репліку не промотять |
| Використання | планове | аварійне |

## Зміна налаштувань «по-Patroni»

Ніколи не редагуйте `postgresql.conf` вручну й ніколи не робіть `ALTER SYSTEM` на кластері Patroni: Patroni пише власні параметри й перезапише або конфліктуватиме з вами. Користуйтесь **одним джерелом істини, etcd**:

```sh
patronictl edit-config                                          # відкриває YAML у вашому редакторі
patronictl edit-config --force -s postgresql.parameters.work_mem=64MB     # неінтерактивно, одне значення
patronictl edit-config --force -s ttl=20 -s loop_wait=5                   # власні таймери Patroni
patronictl list -e                                                        # колонка "Pending restart": чи щось потребує рестарту?
patronictl restart hagod pg2 --pending                                    # рестартувати лише вузли, яким потрібно
```

Які параметри потребують рестарту? `shared_buffers`, `max_connections`, `wal_level`, `max_wal_senders`, `shared_preload_libraries`…
Patroni показує `*` у колонці *Pending restart*. Спершу рестартуйте репліки, лідера останнім (або спершу switchover).

## Режим обслуговування (maintenance)

```sh
patronictl pause            # Patroni перестає реагувати: ні failover, ні перезапуску впалого Postgres
# ... робимо ризиковану роботу ...
patronictl resume --wait
```
Поки на паузі, **впалий primary не буде замінено.** Користуйтесь коротко і завжди робіть resume. Перевірка: `patronictl list` (з'являється рядок `Maintenance mode: on`).

## Перебудова

```sh
patronictl reinit hagod pg2 --force     # знищує дані pg2 і клонує заново з лідера (pg_basebackup)
```
Це триває стільки, скільки копіювати базу по мережі; для великої бази краще відновлюватись з бекапу. Patroni зазвичай сам лагодить старий primary, що повернувся, через `pg_rewind`; `reinit` потрібен лише тоді, коли це неможливо.

## Питаємо REST API Patroni напряму (без `patronictl`)

Порти на вашій машині: pg1 `8101`, pg2 `8102`, pg3 `8103`.

| URL | Що означає | Повертає HTTP 200, коли… |
|---|---|---|
| `/primary` | це лідер | це primary |
| `/replica` | це здорова репліка | це працююча репліка |
| `/sync` | синхронна репліка | це sync standby |
| `/health` | Postgres працює | він працює |
| `/patroni` | JSON з роллю, станом, timeline, позицією WAL | завжди (читайте) |
| `/cluster` | JSON усіх учасників | завжди |
| `/history` | історія failover'ів | завжди |
| `/metrics` | метрики Prometheus | завжди |

```sh
curl -s localhost:8101/patroni | jq '{role, state, timeline, replication_state: .replication_state}'
curl -s -o /dev/null -w '%{http_code}\n' localhost:8102/primary      # 200 або 503
```
HAProxy використовує саме ці endpoint'и. Коли вузол помилково зник із HAProxy, викличте URL самі.

## etcd: лок лідера

```sh
docker exec etcd1 etcdctl endpoint health --cluster                      # чи здоровий кожен учасник?
docker exec etcd1 etcdctl endpoint status --cluster -w table             # хто лідер etcd, розмір БД, raft index
docker exec etcd1 etcdctl member list -w table                           # хто в кластері
docker exec etcd1 etcdctl get /hagod/hagod/leader --print-value-only     # який вузол Postgres тримає лок
docker exec etcd1 etcdctl get /hagod/hagod/ --prefix --keys-only         # усі ключі Patroni
docker exec etcd1 etcdctl get /hagod/hagod/config --print-value-only | jq    # налаштування кластера, сирі
```
Правила: тримайте **непарну** кількість учасників (3 або 5) на окремих хостах; втратите більшість — і Patroni не зможе вирішувати. Бекапте дані etcd, якщо покладаєтесь на нього не лише для Patroni. Ніколи не робіть `etcdctl del --prefix /` на справжньому кластері.

## HAProxy

```sh
curl -s 'localhost:7100/;csv' | awk -F, 'NR>1 && $2!="FRONTEND" && $2!="BACKEND" {print $1,$2,$18}'   # хто UP/DOWN у кожному backend
docker exec haproxy sh -c 'echo "show servers state" | nc -U /var/run/haproxy.sock'                # (потрібен stats socket; див. haproxy.cfg)
docker logs haproxy | tail                                                                          # зміни health check: "is UP", "is DOWN"
```
Відкрийте `http://localhost:7100`: зелений = UP, червоний = DOWN, колонка «Last check» каже чому (`L7STS/503` = вузол відповів 503 на `/primary`, що правильно для репліки).

## Читаємо лог Patroni

```sh
docker logs pg1 2>&1 | grep -E "promoted|demoted|acquired|lost|failed|rewind|bootstrap|Lock owner" | tail
```
| Рядок | Значення |
|---|---|
| `no action. I am (pg1), the leader with the lock` | звичайний heartbeat |
| `following a different leader because I am not the healthiest node` | звичайний цикл репліки |
| `promoted self to leader by acquiring session lock` | цей вузол щойно став primary |
| `Lock owner: pg1; I am pg2` | хто тримає лок |
| `demoting self because DCS is not accessible and I was a leader` | etcd втрачено; це drill 03/04 |
| `Could not rewind` / `starting a basebackup` | старий primary не вдалося полагодити; його клонують заново |
| `failed to start postgres` | drill 07 |

## Безпечне проти небезпечного

| Безпечне (лише читання) | Змінює стан | Небезпечне |
|---|---|---|
| `list`, `topology`, `history`, `show-config`, REST `GET`, `etcdctl get`, `endpoint health` | `switchover`, `restart`, `reload`, `edit-config`, `pause` | `failover`, `reinit`, `remove`, `etcdctl del`, `docker kill` не того вузла, `pg_ctl` на вузлі, яким керує Patroni |
