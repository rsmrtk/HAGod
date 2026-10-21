# Архітектура: що робить кожен елемент

## Сторона Postgres

```
 клієнт ──► HAProxy ─┬─ :5000  «primary»   питає кожен вузол: GET :8008/primary   (HTTP 200 = я primary)
                     └─ :5001  «репліки»   питає кожен вузол: GET :8008/replica   (HTTP 200 = я репліка)
                          │
        ┌─────────────────┼─────────────────┐
       pg1               pg2               pg3          кожен контейнер = Postgres + Patroni
   Patroni+Postgres  Patroni+Postgres  Patroni+Postgres   Patroni запускає, зупиняє, промотить, демотить Postgres
        └─────────────────┼─────────────────┘
                 etcd1  etcd2  etcd3                    лок лідера і стан кластера
```

**Хто вирішує, хто primary?** Patroni за допомогою etcd. В etcd є один ключ, `/hagod/hagod/leader`, з TTL. Вузол, що тримає його, і є primary. Він мусить **поновлювати** ключ кожні `loop_wait` секунд. Якщо не може (впав, відрізаний від мережі, etcd недоступний), ключ спливає, і репліки змагаються за нього. Хто виграв, той промотить свій Postgres.

Цей один факт пояснює майже будь-яку поведінку, яку ви побачите:

| Ситуація | Що відбувається | Чому |
|---|---|---|
| Primary падає | ~25 с до нового primary | спершу має спливти ключ лідера (`ttl`) |
| Ви робите `switchover` | ~3 с | старий primary **навмисно віддає** ключ, ніхто не чекає на спливання |
| etcd втрачає кворум | primary демотить себе; **ніхто** не може писати | він не може поновити ключ, тож не може довести, що він primary |
| Primary відрізаний від мережі | він сам зупиняє Postgres; інші обирають нового | те саме: не може поновити, мусить зупинитися, поки не з'явився другий primary |

### Таймери (в `images/patroni/patroni.yml.tpl`, зберігаються в etcd, міняються через `patronictl edit-config`)

| Параметр | Значення тут | Що означає |
|---|---|---|
| `ttl` | 30 | скільки живе ключ лідера без поновлення. Failover може тривати приблизно стільки |
| `loop_wait` | 10 | як часто кожен Patroni запускає свій цикл прийняття рішень |
| `retry_timeout` | 10 | як довго Patroni повторює виклики etcd/Postgres, перш ніж здатися. **Має виконуватись `loop_wait + 2 × retry_timeout <= ttl`** |
| `maximum_lag_on_failover` | 1 MB | репліка, що відстає більше, **не** може стати primary |
| `use_pg_rewind` | true | старий primary, що повертається, лагодиться через `pg_rewind` замість повного копіювання |
| `use_slots` | true | кожна репліка має replication slot, тож primary тримає WAL, який їй ще потрібен |
| `synchronous_mode` | false | за замовчуванням async; drill 05 вмикає його (і `synchronous_mode_strict`) |

Менший `ttl` = швидший failover, але більше хибних failover'ів у повільній мережі. Це той компроміс, про який вас питатимуть.

### Що бачить клієнт
- HAProxy опитує Patroni щосекунди (`inter 1s fall 2 rise 2`). Після failover йому потрібні 2 успішні перевірки, тож додайте ~2 с.
- `on-marked-down shutdown-sessions` розриває наявні з'єднання з вузлом, який перестав бути primary. Без цього клієнт міг би продовжувати писати у демотований вузол. Застосунки мусять **перепідключатись і повторювати спробу**: це половина HA, що лежить на застосунку.

### WAL-архів і бекапи
- `archive_command` копіює кожен завершений сегмент WAL на спільний том `/archive` (замінник S3 чи сервера бекапів).
- Базові бекапи йдуть у `/backup`. Разом вони дають point-in-time recovery (drill 10).
- `archive_timeout = 60` примусово перемикає WAL щонайменше раз на хвилину, що обмежує, скільки ви можете втратити, якщо вціліє лише архів.

## Сторона Redis

```
 клієнт ──► питає Sentinel: «хто master для 'mymaster'?» ──► підключається за цією адресою
 redis1 (master) ──реплікація──► redis2 (репліка)
        └────────реплікація──► redis3 (репліка)
 sentinel1  sentinel2  sentinel3     три вартові, які стежать за master і домовляються про failover
```

| Параметр (`config/redis/sentinel.conf`) | Значення | Що означає |
|---|---|---|
| `monitor mymaster <ip> 6379 2` | quorum **2** | скільком sentinel'ам треба погодитись, що master впав (ODOWN) |
| `down-after-milliseconds` | 5000 | 5 с без валідної відповіді = цей sentinel вважає master недоступним (SDOWN) |
| `failover-timeout` | 15000 | скільки може тривати спроба failover; також пауза перед повтором |
| `parallel-syncs` | 1 | скільки реплік одночасно ресинхронізуються з новим master |

**Два числа вирішують failover**: **quorum** (2) каже, що master *справді* впав; але потім один sentinel має бути **уповноважений більшістю всіх sentinel'ів** (2 з 3), щоб його виконати. Втратите два sentinel'и — failover неможливий, навіть із quorum 1. (Drill 12.)

Sentinel **не** проксює трафік. Бібліотека клієнта питає Sentinel про адресу master. Клієнт, який цього не робить (або кешує адресу), продовжить писати у старий master. (Drill 13.)

Реплікація **асинхронна**: master відповідає клієнту раніше, ніж репліки отримають запис. Тож failover може втратити останні записи. `min-replicas-to-write` звужує це вікно: ізольований master відмовляється приймати записи.

## Чому в цій лабораторії статичні IP

Sentinel резолвить hostname'и в єдиному event loop. Коли ім'я перестає резолвитись (саме це робить мережевий partition), кожна спроба його блокує, він входить у режим **TILT** і перестає робити failover. Це видно: `+tilt` у `docker logs sentinel1`. Тому лабораторія моніторить master за IP, а кожен контейнер має фіксовану адресу в `172.30.0.0/24`. (Урок для проду: якщо ви використовуєте hostname'и з Sentinel, перевірте, що буде, коли DNS відмовить.)

## На що дивитись

| Я хочу знати | Дивитись |
|---|---|
| Хто Postgres primary | `make watch`, `docker exec tools patronictl list`, `curl localhost:8101/primary` |
| Чи здорова реплікація | `select * from ops.replication` на primary |
| Що думає HAProxy | `http://localhost:7100` |
| Чи здоровий etcd | `docker exec etcd1 etcdctl endpoint health --cluster` |
| Хто Redis master | `make watch`, `redis-cli -h sentinel1 -p 26379 sentinel get-master-addr-by-name mymaster` |
| Що вирішив Sentinel і чому | `docker logs sentinel1` (шукайте `+sdown`, `+odown`, `+elected-leader`, `+switch-master`, `+tilt`) |
| Що пережив застосунок | `make report` |
