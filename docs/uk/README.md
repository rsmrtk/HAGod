# HAgod

Полігон для експлуатації **PostgreSQL з Patroni** та **Redis із Sentinel** у проді.
Ви навмисно ламаєте справжній кластер, дивитесь, що відбувається, лагодите і пишете runbook. Усе працює
на вашому ноутбуці в Docker, нічого не симулюється.

> Це український переклад. Оригінал: [`README.md`](../../README.md). Повний зміст: [INDEX.md](INDEX.md).

```
 ваш застосунок («probe»)
      |                     |
 HAProxy :5000 (записи)   Sentinel (хто master?)
 HAProxy :5001 (читання)        |
      |                   redis1 (master) -> redis2, redis3
 pg1  pg2  pg3  <-- Patroni на кожному вирішує, хто лідер
      \   |   /
   etcd1 etcd2 etcd3   <-- лок лідера
```

**Що ви отримуєте**

| | |
|---|---|
| Банкоподібна база `bank` | 10 тис. клієнтів, 25 тис. рахунків, 400 тис. транзакцій, партиціонована audit-таблиця, практичні таблиці для індексів, vacuum і блокувань, та набір view `ops.*`, що відповідають на «що відбувається?» |
| Redis, повний реалістичних ключів | сесії, hash'і, sorted set'и, stream, черга, величезний ключ, ключі з TTL і без |
| 15 drill'ів | кожен ламає щось справжнє, з виміряним результатом (час failover, втрачені записи) |
| Game day | випадкова відмова, про яку вам не кажуть |
| Probe | застосунок, що пише в обидві бази й звітує **RTO** та **RPO** |
| Живий дашборд | `make watch` показує Postgres, Patroni, etcd, Redis, Sentinel і probe одночасно |
| Опційно Prometheus + Grafana | з alert'ами, які мала б справжня команда |
| Шпаргалки | команди, які ви справді вводитимете, з поясненнями, у `docs/` |

## Старт за п'ять хвилин

Потрібен Docker (Colima, OrbStack або Docker Desktop) із приблизно 4 ГБ пам'яті.

```sh
make up              # першого разу збирає образ Patroni; чекає, доки все стане здоровим
make seed            # завантажує дані bank у Postgres і ключі в Redis
make writer-start    # запускає probe (застосунок, що постійно пише в обидві бази)
make watch           # живий дашборд: тримайте відкритим у другому терміналі
```

Потім прочитайте **[00-START-HERE.md](00-START-HERE.md)**: план, як практикуватись і порядок drill'ів.

## Щоденні команди

| Команда | Що робить |
|---|---|
| `make watch` | живий дашборд усієї лабораторії |
| `make status` | те саме, один раз |
| `make shell` | shell із `psql`, `patronictl` і `redis-cli`, уже спрямованими на лабораторію |
| `make psql` | `psql` на primary (через HAProxy) |
| `make rcli` | `redis-cli` на поточному Redis master |
| `make overview` | що є в базах: таблиці, розміри, ключі Redis за типами |
| `make drill-01` … `make drill-15` | зламати щось (спершу прочитайте README drill'а) |
| `make verify-01` … | перевірити результат і побачити цифри |
| `make report` | RTO / RPO з probe |
| `make gameday` / `make gameday-reveal` | випадкова відмова, яку треба діагностувати |
| `make heal` | повернути все на місце після будь-якого drill |
| `make reset` | стерти всі дані й почати з нуля |
| `make obs-up` | опційно: Prometheus + Grafana (`http://localhost:3300`) |

## Порти на вашій машині

| | |
|---|---|
| `localhost:5440` | primary Postgres через HAProxy (`postgres` / `hagod-super`, база `bank`) |
| `localhost:5441` | репліки Postgres через HAProxy (лише читання) |
| `localhost:7100` | сторінка статистики HAProxy |
| `localhost:8101-8103` | REST API Patroni для pg1, pg2, pg3 (`/patroni`, `/cluster`, `/primary`, `/replica`) |
| `localhost:6401-6403` | redis1, redis2, redis3 (пароль `hagod-redis`) |
| `localhost:26401-26403` | sentinel1, sentinel2, sentinel3 |
| `localhost:3300`, `localhost:9191` | Grafana, Prometheus (після `make obs-up`) |

(5000 і 7000 зайняті macOS AirPlay, а 9090 часто використовують інші інструменти, тому лабораторія їх уникає.)

## Структура

```
compose.yml            лабораторія
images/                образ Patroni, конфіг HAProxy, probe
config/redis/          redis.conf і sentinel.conf
seed/                  база bank і ключі Redis
scripts/               watch, status, heal, report, overview, game day
drills/NN-name/        README.md (урок), break.sh, verify.sh
docs/                  план, архітектура, шпаргалки команд, runbook'и, каталог відмов
docs/uk/               український переклад документації
obs/                   опційно Prometheus, alert'и, Grafana
```

## Безпека

Це лабораторія. Паролі лежать у файлах, `enable-debug-command` увімкнено, а мережа широко відкрита. Ніколи не копіюйте
конфігурацію в прод як є; кожне важливе налаштування пояснено в `docs/01-architecture.md`.
