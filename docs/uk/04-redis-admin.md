# Адміністрування Redis і Sentinel на даних лабораторії

Відкрийте сесію: `make rcli` (підключається до того вузла, якого Sentinel називає master; він скаже, до якого). Пароль уже виставлено (`REDISCLI_AUTH`). Redis 7.4. Щоб подивитись на репліку, додайте вузол: `./scripts/rcli.sh redis2`.

> Команди Redis нечутливі до регістру. Ключі чутливі до регістру. По дроту все є рядком; **тип** ключа визначає, які команди працюють з ним. `WRONGTYPE` означає, що ви використали команду не для того типу.

## 1. Що тут є, безпечно

```
DBSIZE                          скільки ключів (дешево, O(1))
INFO keyspace                   ключі, скільки має TTL, середній TTL
SCAN 0 MATCH account:* COUNT 100    обхід keyspace малими кроками; повторюйте з курсором, який він повертає, доки не поверне 0
TYPE account:1                  hash | string | list | set | zset | stream
TTL session:...                 скільки секунд лишилось; -1 = без закінчення; -2 = ключа не існує
OBJECT ENCODING account:1       як це зберігається всередині (listpack = малий і компактний, hashtable = великий)
MEMORY USAGE bigkey:audit_blob  скільки байтів коштує цей ключ
```
`make overview` друкує ключі, згруповані за шаблоном, з типом, кількістю і тим, чи вони спливають. Вивчіть це першим.

> **Ніколи не запускайте `KEYS *` на справжньому сервері.** Це обхід кожного ключа однією блокуючою командою; на мільйонах ключів Redis на секунди перестає відповідати, і Sentinel може зробити failover (drill 15). Користуйтесь `SCAN` (або `redis-cli --scan --pattern 'x:*'`).

## 2. Типи даних на посіяних ключах

| Шаблон ключа | Тип | Для чого | Спробуйте |
|---|---|---|---|
| `session:*` | string з TTL | сесії логіну | `TTL <один>`; `SET session:x u1 EX 60`; `GET`, `EXPIRE`, `PERSIST` |
| `account:<id>` | hash | закешований акаунт | `HGETALL account:1`; `HGET account:1 balance`; `HINCRBY account:1 balance -100`; `HSET account:1 status frozen` |
| `leaderboard:top_spenders` | sorted set | рейтинг | `ZREVRANGE leaderboard:top_spenders 0 4 WITHSCORES`; `ZRANK`; `ZINCRBY`; `ZCARD` |
| `queue:payments` | list | FIFO-черга | `LLEN`; `LRANGE queue:payments 0 4`; `LPOP`; `RPUSH` (для блокуючого споживача `BLPOP`) |
| `set:online_users` | set | членство | `SCARD`; `SISMEMBER set:online_users customer:7`; `SRANDMEMBER` |
| `stream:events` | stream | журнал подій з consumer groups | `XLEN`; `XRANGE stream:events - + COUNT 3`; `XINFO STREAM stream:events`; `XINFO GROUPS stream:events`; `XREADGROUP GROUP workers c1 COUNT 2 STREAMS stream:events >`; `XACK` |
| `hll:daily_visitors` | hyperloglog (рядок) | підрахунок унікальних у 12 КБ | `PFCOUNT hll:daily_visitors` (≈1000, похибка 1%) |
| `bitmap:logins:2026-10-18` | рядок, що використовується як біти | так/ні для кожного id користувача | `GETBIT`, `BITCOUNT bitmap:logins:2026-10-18` |
| `geo:atms` | sorted set | координати | `GEODIST geo:atms atm-kyiv atm-lviv km`; `GEOSEARCH geo:atms FROMLONLAT 30.5 50.4 BYRADIUS 600 km` |
| `ratelimit:<ip>` | string з TTL 60 с | обмеження частоти | `INCR`, `TTL` |
| `cache:rates:pair-*` | string, **без TTL** | кеш, що ніколи не спливає | `OBJECT IDLETIME`; чому це ризик? (розділ 5) |
| `hotkey:config:fees` | string | читається тисячі разів/с | `redis-cli --hotkeys` (потребує LFU-політики) |
| `bigkey:audit_blob` | hash з 20 000 полів | навмисно величезний ключ | `HLEN`; `MEMORY USAGE`; `HSCAN`; ніколи `HGETALL` |

**Вправа 1.** Які hash'і `account:*` мають найбільший баланс? У Redis не можна запитувати за значенням (це не база даних).
Спробуйте SCAN + HGET у shell-циклі, а потім дайте відповідь: що б ви додали, щоб цей запит став дешевим? (Підказка: sorted set, проіндексований за балансом.)

**Вправа 2.** Споживач платежів: `LPOP queue:payments` проти `BLPOP queue:payments 5`; що буде, якщо споживач впаде після витягування?
(Платіж пропав. Тому stream із consumer groups і `XACK` безпечніший для платежів; подивіться `XPENDING`.)

## 3. Чи здорово: `INFO`

`INFO` має секції; просіть одну: `INFO replication`, `INFO memory`, `INFO stats`, `INFO persistence`, `INFO clients`, `INFO commandstats`.

| Що хочете | Команда | Здорове значення |
|---|---|---|
| роль і репліки | `INFO replication` | master: `connected_slaves:2`; репліка: `master_link_status:up` |
| пам'ять | `INFO memory` | `used_memory_human` значно нижче `maxmemory_human`; `mem_fragmentation_ratio` близько 1-1,5 (у лабораторії >1, бо даних мало) |
| чи ми витісняємо / спливаємо | `INFO stats` → `evicted_keys`, `expired_keys` | `evicted_keys` має бути 0, якщо ви не обрали політику eviction навмисно |
| ефективність кешу | `INFO stats` → `keyspace_hits`, `keyspace_misses` | hit ratio = hits / (hits+misses) |
| пропускна здатність | `INFO stats` → `instantaneous_ops_per_sec` | |
| чи працює персистентність | `INFO persistence` | `aof_last_write_status:ok`, `rdb_last_bgsave_status:ok` |
| з'єднання | `INFO clients` | `blocked_clients` має бути малим |
| які команди коштують найбільше | `INFO commandstats` | одна команда домінує за сумарним часом |

`INFO replication` на master показує кожну репліку як `slave0:ip=…,state=online,offset=…,lag=…`; **`lag` — це секунди від її останнього ack.**
Порівняйте `master_repl_offset` з `offset` кожної репліки: різниця — байти, яких репліка не застосувала.

## 4. Шукаємо, що повільне чи велике

```
SLOWLOG GET 10             останні повільні команди (поріг: slowlog-log-slower-than = 10 мс тут)
SLOWLOG LEN / SLOWLOG RESET
LATENCY LATEST             сплески, які помітив сервер (latency-monitor-threshold 100 мс тут)
LATENCY DOCTOR             аналіз, зрозумілий людині
CLIENT LIST                кожне з'єднання: вік, простій, остання команда, на чому заблоковане
CLIENT KILL ID <id>        закрити одне
MONITOR                    стрімить УСІ команди наживо. Потужно й важко: на секунди, ніколи не лишайте
redis-cli --bigkeys        вибірка keyspace для найбільшого ключа кожного типу (використовує SCAN: безпечно)
redis-cli --memkeys        те саме, за пам'яттю
redis-cli --latency        безперервно міряє round-trip затримку (Ctrl-C щоб зупинити)
redis-cli --latency-history -i 5
redis-cli --stat           дашборд «рядок на секунду»: ключі, пам'ять, клієнти
MEMORY DOCTOR              дає поради
```
У лабораторії ввімкнено `DEBUG SLEEP` (drill 15), щоб ви могли навмисно сповільнити Redis і дивитись, як реагують slow log і latency.

## 5. Пам'ять і eviction

```
CONFIG GET maxmemory                 0 = необмежено; лабораторія ставить 256mb
CONFIG GET maxmemory-policy          що робить Redis, коли пам'ять заповнена
CONFIG SET maxmemory 100mb           змінює наживо (НЕ назавжди, див. CONFIG REWRITE)
CONFIG REWRITE                       записує поточний конфіг назад у redis.conf
```

| Політика | Коли заповнено | Для чого |
|---|---|---|
| `noeviction` (за замовчуванням) | **відмовляє в записах** з `OOM command not allowed` | черги, усе, що не можна втратити |
| `allkeys-lru` | видаляє найдавніше використаний ключ | чистий кеш |
| `allkeys-lfu` | видаляє найрідше використовуваний | кеш із гарячими ключами |
| `volatile-lru` / `volatile-ttl` | видаляє лише ключі, що **мають TTL** | суміш кеш-ключів (з TTL) і постійних даних |
| `allkeys-random` / `volatile-random` | випадково | рідко |

Правило: **один Redis для кешів, інший — для даних, які не можна втратити.** Якщо вони ділять інстанс, єдина безпечна політика — `volatile-*`, і кожен кеш-ключ **мусить** мати TTL: подивіться на `cache:rates:*`, який його не має, тож під `volatile-lru` його ніколи не витіснять, і він заповнить пам'ять (drill 14).

Рахуйте й пам'ять, що не є ключами: вихідні буфери реплікації й буфер переписування AOF. Правило: тримайте `used_memory` нижче ~60% машини, бо фоновий save (`BGSAVE`/переписування AOF) робить fork і в гіршому випадку може ненадовго подвоїти пам'ять.

## 6. Персистентність

| | RDB (snapshot) | AOF (append-only file) |
|---|---|---|
| Що | дамп на момент часу кожні N секунд/змін (`save 60 1000`) | кожен запис дописується; `appendfsync everysec` = втрата щонайбільше ~1 с |
| Рестарт | швидкий | повільніший, програє журнал |
| Втрата при аварії | до кількох хвилин | ~1 с (`always` = нуль, але повільно) |
```
INFO persistence      час останнього збереження, статус, чи йде переписування
BGSAVE                snapshot у фоні
BGREWRITEAOF          ущільнити AOF у фоні
LASTSAVE              unix-час останнього успішного збереження
```
Файли лежать у `/data` на кожному вузлі: `docker exec redis1 ls -la /data /data/appendonlydir`. Перевірка AOF: `redis-check-aof /data/appendonlydir/<file>`.
**Репліка — не бекап**: `FLUSHALL` на master реплікується на всі репліки за мілісекунди. Бекапте файли RDB/AOF поза машиною.

## 7. Реплікація вручну

```
ROLE                                   master/slave, з offset і репліками
REPLICAOF NO ONE                       зробити цей вузол master (ручний promote: зазвичай це робить Sentinel)
REPLICAOF <host> 6379                  зробити цей вузол репліку того master
WAIT 1 100                             блокувати, доки 1 репліка не підтвердить усі мої записи або не мине 100 мс; повертає, скільки підтвердили
```
`WAIT` — спосіб для клієнта отримати **напівсинхронні** записи: `SET x 1`, потім `WAIT 1 100`. Це звужує втрату, але не усуває (Redis усе одно може зробити failover на репліку, що пропустила запис).

Небезпека: `REPLICAOF` вручну на наборі під керуванням Sentinel б'ється із Sentinel. Робіть зміни **через Sentinel** (`SENTINEL FAILOVER`).

## 8. Sentinel

Підключення: `redis-cli -h sentinel1 -p 26379` (пароль той самий `hagod-redis`).

```
SENTINEL GET-MASTER-ADDR-BY-NAME mymaster      хто master ЗАРАЗ (саме це питають клієнти)
SENTINEL MASTER mymaster                       повний стан: flags, quorum, num-slaves, num-other-sentinels, down-after-milliseconds, failover-timeout
SENTINEL REPLICAS mymaster                     репліки так, як їх бачить Sentinel (шукайте flags: s_down і slave-repl-offset)
SENTINEL SENTINELS mymaster                    інші sentinel'и
SENTINEL CKQUORUM mymaster                     "OK 3 usable Sentinels..." = sentinel'ів досить для failover; інакше скаже, чого бракує
SENTINEL FAILOVER mymaster                     запустити failover зараз (як switchover; падіння master не потрібне)
SENTINEL RESET mymaster                        забути репліки/sentinel'и й виявити заново (лагодить застарілі записи після перебудови)
SENTINEL CONFIG GET down-after-milliseconds    / SET щоб змінити наживо
INFO sentinel                                  зведення в один рядок
```
Читання `flags` master: `master` — все гаразд; `s_down` = ЦЕЙ sentinel вважає його недоступним (суб'єктивно); `o_down` = кворум погоджується (об'єктивно): failover починається.
`+tilt` у логу = годинник Sentinel стрибнув або його цикл був заблокований; він **перестає діяти на 30 с**. Частий TILT = sentinel перевантажений або має нестабільний годинник.

Лог (`docker logs sentinel1`) розповідає всю історію: `+sdown` → `+odown` → `+try-failover` → `+elected-leader` → `+selected-slave` → `+promoted-slave` → `+switch-master`.

Як клієнт має підключатись: питати Sentinel про адресу master **при кожному перепідключенні**, а не один раз на старті. Перевірте поведінку власного застосунку drill 11.

## 9. Користувачі та безпека

```
ACL LIST                       користувачі та їхні дозволи
ACL SETUSER app on >pw ~session:* +get +set +del +expire    користувач застосунку, що може чіпати лише session:* чотирма командами
ACL WHOAMI
CONFIG GET requirepass         (ніколи не друкуйте його в тікеті)
```
Закрийте те, що може нашкодити: `rename-command`/ACL для `FLUSHALL`, `FLUSHDB`, `KEYS`, `DEBUG`, `CONFIG`, `SHUTDOWN`. У проді ніколи нема `enable-debug-command yes`.

## 10. Вправи

1. Скористайтесь `redis-cli --scan --pattern 'session:*' | head`, щоб взяти один ключ сесії. Скільки секунд до його закінчення? Змініть через `EXPIRE`. Дивіться, як він зникає.
2. Запустіть `redis-cli --bigkeys` і `MEMORY USAGE` для `bigkey:audit_blob`. Скільки коштував би `HGETALL` на ньому? Спробуйте натомість `HSCAN bigkey:audit_blob 0 COUNT 100`.
3. Запустіть `redis-cli --stat` в одному вікні, а в іншому `redis-cli -h <master> DEBUG SLEEP 2`. Що видно в `--stat`, у `SLOWLOG`, у `LATENCY LATEST`?
4. `FLUSHALL` на репліці (вона відмовить: чому?), потім на master (що станеться з репліками? Для відновлення зробіть `make seed-redis`).
5. `SENTINEL FAILOVER mymaster`, поки відкритий `make watch` і працює probe. Порівняйте простій з drill 11 (аварія).
