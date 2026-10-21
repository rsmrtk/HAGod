# Документація українською

Повний переклад англійської документації HAgod. Англійські оригінали лишаються в `docs/` та `drills/`; технічні терміни (failover, switchover, lag, quorum, slot…) навмисно залишено англійською, бо саме так їх називають у логах, командах і на співбесідах.

## З чого починати
1. [README.md](README.md): що це і як запустити
2. [00-START-HERE.md](00-START-HERE.md): план на 4 тижні
3. [01-architecture.md](01-architecture.md): що робить кожен елемент і чому
4. [09-cheatsheet.md](09-cheatsheet.md): шпаргалка, тримайте відкритою

## Документи
| Файл | Про що |
|---|---|
| [02-patroni-commands.md](02-patroni-commands.md) | Patroni, etcd, HAProxy: команди |
| [03-postgres-admin.md](03-postgres-admin.md) | адміністрування PostgreSQL з вправами |
| [04-redis-admin.md](04-redis-admin.md) | адміністрування Redis і Sentinel з вправами |
| [05-backup-pitr.md](05-backup-pitr.md) | бекапи та point-in-time recovery |
| [06-failure-modes.md](06-failure-modes.md) | каталог відмов і дерева рішень |
| [07-runbook-template.md](07-runbook-template.md) | шаблон runbook'а і приклад |
| [08-progress.md](08-progress.md) | ваше табло і чек-лист навичок |
| [10-interview-questions.md](10-interview-questions.md) | 38 питань для співбесіди з відповідями |

## Drill'и
| # | Тема | | # | Тема |
|---|---|---|---|---|
| 01 | [Вбити primary](drills/01-kill-primary.md) | | 09 | [Блокування і забута транзакція](drills/09-locks-and-long-transactions.md) |
| 02 | [Плановий switchover](drills/02-switchover.md) | | 10 | [Бекап і PITR](drills/10-backup-and-pitr.md) |
| 03 | [Втрата кворуму etcd](drills/03-etcd-quorum-loss.md) | | 11 | [Вбити Redis master](drills/11-redis-master-kill.md) |
| 04 | [Ізоляція primary](drills/04-partition-primary.md) | | 12 | [Втрата кворуму Sentinel](drills/12-sentinel-quorum-loss.md) |
| 05 | [Async проти sync](drills/05-async-vs-sync.md) | | 13 | [Split brain у Redis](drills/13-redis-split-brain.md) |
| 06 | [Lag реплікації](drills/06-replication-lag.md) | | 14 | [Redis без пам'яті](drills/14-redis-memory-full.md) |
| 07 | [Перебудова репліки](drills/07-replica-rebuild.md) | | 15 | [Повільна команда → failover](drills/15-redis-slow-command.md) |
| 08 | [pg_wal заповнює диск](drills/08-wal-bloat-slot.md) | | | |

> Шляхи в командах (`make drill-NN`, `drills/…/break.sh`) однакові в обох мовах. Запускайте їх з кореня репозиторію.
