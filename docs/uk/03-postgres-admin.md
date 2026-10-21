# Адміністрування PostgreSQL на даних лабораторії

Відкрийте сесію: `make psql` (база `bank`, на primary). Усе нижче виконується там, якщо не сказано інше.
Підказка показує `hagod bank=#`; таймінг увімкнено, `\x auto` перемикає на вертикальний вивід, коли рядки широкі.

> Умовність: рядки, що починаються з `\`, — це мета-команди psql (не SQL); SQL закінчується `;`.

## 1. Роззирнутись

| Команда | Що показує |
|---|---|
| `\conninfo` | хто ви і куди підключені (через HAProxy → який вузол?) |
| `\l+` | бази даних та їхні розміри |
| `\c bank` | перемкнути базу |
| `\dn+` | схеми (`core`, `audit`, `practice`, `ops`) |
| `\dt+ core.*` | таблиці з розміром |
| `\d+ core.transactions` | колонки, індекси, обмеження, розмір, партиції |
| `\di+ core.*` | індекси з розміром |
| `\df ops.*` / `\dv ops.*` | функції / view |
| `\du` | ролі |
| `\dx` | розширення (`pg_stat_statements`) |
| `\x` | перемкнути вертикальний вивід |
| `\timing` | перемкнути вимірювання часу кожного запиту |
| `\watch 2` | повторювати попередній запит кожні 2 с (дашборд для бідних) |
| `\e` | редагувати останній запит у вашому редакторі |
| `\?` / `\h UPDATE` | довідка psql / синтаксису SQL |

**Вправа 1.** Які три таблиці найбільші і яка частка кожної припадає на індекси?
```sql
select * from ops.table_sizes limit 5;
```
`core.transactions` має 400 тис. рядків і ~32 МБ індексів: індекси — половина її розміру. Кожен індекс сповільнює запис і коштує диску, тож тримайте лише ті, що використовують запити (розділ 3).

**Вправа 2.** На якому я вузлі і чи це primary?
```sql
select * from ops.node;
select inet_server_addr(), pg_is_in_recovery();
```
Запустіть це і через порт реплік: `docker exec tools psql -h haproxy -p 5001 -d bank -c "select * from ops.node"`. Роль скаже `REPLICA`; спроба запису дасть `ERROR: cannot execute INSERT in a read-only transaction`.

## 2. Чи здорова реплікація?

На **primary**:
```sql
select * from ops.replication;                  -- кожна репліка: стан, sync/async, lag у байтах і часі
select * from ops.slots;                        -- slots і скільки WAL кожен утримує
select pg_current_wal_lsn();                    -- до якого місця primary записав
select * from pg_stat_replication;              -- сирий view (більше колонок: sent_lsn, write_lsn, flush_lsn, replay_lsn)
```
На **репліці** (через `docker exec -e PGPASSWORD=hagod-super pg2 psql -h localhost -U postgres -d bank`):
```sql
select pg_is_in_recovery();                                                    -- true
select pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();                    -- отримано проти застосовано
select now() - pg_last_xact_replay_timestamp() as replay_delay;                 -- наскільки застарілі мої читання (має сенс, лише коли відбуваються записи)
select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());    -- байти, отримані, але не застосовані
select * from pg_stat_wal_receiver;                                            -- з'єднання з primary
```

Як читати колонки lag (`ops.replication`): `write_lag` = репліка отримала це в пам'яті, `flush_lag` = на її диску, `replay_lag` = видно запитам.
Зростаючий розрив між flush і replay = replay призупинено або заблоковано довгим запитом на репліці (drill 06).

Timeline: `select timeline_id from pg_control_checkpoint();`. Він росте на одиницю при кожному promote; після failover усі вузли мають бути на новому.

## 3. Повільний запит (індекси та EXPLAIN)

`practice.slow_orders` має 300 000 рядків і **не має індексу на `status`**.

```sql
explain (analyze, buffers) select count(*) from practice.slow_orders where status = 'paid';
```
Шукайте: `Seq Scan` (читає всю таблицю), `Rows Removed by Filter`, `Execution Time`, `Buffers: shared hit/read`.

Виправте і порівняйте:
```sql
create index concurrently slow_orders_status_idx on practice.slow_orders(status);   -- CONCURRENTLY: без блокування запису (не можна всередині транзакції)
explain (analyze, buffers) select count(*) from practice.slow_orders where status = 'paid';
```
Ймовірно, ви все одно побачите scan: `status` має лише 5 значень, тож збігається 20% таблиці, і планувальник усе одно читає більшу частину.
Індекс перемагає на селективному запиті:
```sql
explain (analyze) select * from practice.slow_orders where id = 123456;             -- первинний ключ: Index Scan, ~0.05 мс
create index slow_orders_cust_idx on practice.slow_orders(customer, created_at desc);
explain (analyze) select * from practice.slow_orders where customer = 42 order by created_at desc limit 10;
```
Уроки: індекси допомагають на **селективних** умовах; `ANALYZE` підтримує статистику свіжою; індекс, яким ви не користуєтесь, лише коштує на записі.

Знайти невикористані індекси:
```sql
select relname as "table", indexrelname as index, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) as size
from pg_stat_user_indexes order by idx_scan, pg_relation_size(indexrelid) desc limit 10;
```

На що база витрачає час?
```sql
select * from ops.top_queries;                              -- потребує pg_stat_statements (встановлено в seed)
select pg_stat_statements_reset();                          -- скинути, щоб міряти від цього моменту
```
`total_ms` знаходить запити, що коштують найбільше загалом; `mean_ms` — найповільніші за один виклик. Часто верхній запит — швидкий, виконаний мільйон разів.

## 4. Vacuum і роздування (bloat)

Postgres ніколи не перезаписує рядок: `UPDATE`/`DELETE` лишають стару версію (*dead tuple*), поки її не прибере `VACUUM`.
`practice.bloat_demo` має autovacuum **вимкнений** і 40% мертвих рядків.
```sql
select * from ops.dead_tuples limit 5;                        -- dead_pct ~ 40 для practice.bloat_demo
select pg_size_pretty(pg_total_relation_size('practice.bloat_demo'));      -- розмір зараз
vacuum (verbose, analyze) practice.bloat_demo;                -- прибирає dead tuples, робить місце придатним для повторного використання, оновлює статистику
select * from ops.dead_tuples limit 3;                         -- dead = 0
select pg_size_pretty(pg_total_relation_size('practice.bloat_demo'));      -- той самий розмір: звичайний VACUUM не зменшує файл
vacuum full practice.bloat_demo;                              -- переписує таблицю: зменшує, але БЛОКУЄ таблицю ексклюзивно
```
Ніколи не запускайте `VACUUM FULL` на гарячій таблиці в проді. Для онлайн-ущільнення використовуйте `pg_repack` (розширення).

Autovacuum на практиці:
```sql
select relname, last_autovacuum, last_autoanalyze, n_dead_tup from pg_stat_user_tables order by n_dead_tup desc limit 5;
show autovacuum_vacuum_scale_factor;                          -- 0.2 = vacuum, коли 20% таблиці мертві; надто ліниво для величезних таблиць
alter table core.transactions set (autovacuum_vacuum_scale_factor = 0.02);    -- тюнінг для окремої таблиці
select pid, query_start, left(query,60) from pg_stat_activity where query like 'autovacuum:%';   -- що працює зараз
```
**Стара відкрита транзакція не дає vacuum прибирати нічого новішого за себе.** Якщо `dead_pct` росте, хоч autovacuum працює, шукайте сесії `idle in transaction` (розділ 5).

## 5. Сесії, блокування, довгі транзакції

```sql
select * from ops.activity;                 -- усі клієнтські сесії: стан, як довго триває транзакція/запит, чого очікують
select * from ops.blocked;                  -- хто на кого чекає (порожньо = добре)
select state, count(*) from pg_stat_activity where backend_type='client backend' group by 1;    -- скільки active / idle / idle in transaction
```
Стани: `active` (виконується), `idle` (чекає клієнта), **`idle in transaction`** (транзакція відкрита й тримає блокування та snapshot'и;
застосунок забув зробити commit: найгірший різновид).

Зупинити сесію:
```sql
select pg_cancel_backend(1234);      -- ввічливо: скасовує поточний запит, сесія лишається
select pg_terminate_backend(1234);   -- грубо: закриває сесію і відкочує її транзакцію
```
Запобігти (на весь кластер, «по-Patroni»):
```sh
patronictl edit-config --force -s postgresql.parameters.idle_in_transaction_session_timeout=60000 \
                              -s postgresql.parameters.lock_timeout=10000 \
                              -s postgresql.parameters.statement_timeout=0
```
`log_lock_waits = on` уже встановлено: `docker logs pg1 | grep "still waiting"` показує очікування блокувань довші за `deadlock_timeout` (1 с).

Спробуйте drill із блокуваннями самі, без скрипта:
```sql
-- сесія 1 (make psql)
begin; update practice.locks_demo set owner='me' where id=1;     -- і тепер не робіть commit
-- сесія 2 (другий термінал, make psql)
update practice.locks_demo set owner='you' where id=1;            -- зависає
-- сесія 3
select * from ops.blocked;
```
Потім `rollback;` у сесії 1.

## 6. WAL, checkpoint'и, архівація

```sql
select pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());       -- де я в WAL, який файл
select * from ops.archiver;                                                -- чи працює архівація? failed_count не має рости
select pg_switch_wal();                                                    -- закрити поточний сегмент зараз (змушує архівацію)
checkpoint;                                                                -- скинути брудні сторінки на диск, дозволити переробку старого WAL
select * from pg_stat_bgwriter;  select * from pg_stat_checkpointer;     -- частота checkpoint'ів (забагато "requested" = max_wal_size замалий)
show max_wal_size; show wal_keep_size; show archive_command;
```
З боку диска:
```sh
docker exec pg1 du -sh /var/lib/postgresql/data/pgdata/pg_wal      # який розмір каталогу WAL
docker exec pg1 ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status | grep -c ready    # чекають архівації: має бути ~0
```
`pg_wal` росте, коли: (а) неактивний replication slot утримує його (drill 08), (б) `archive_command` падає (файли `ready` накопичуються, `ops.archiver.failed_count` росте),
(в) репліка далеко позаду, а `wal_keep_size` великий. Знайте всі три.

## 7. Конфігурація

```sql
show shared_buffers;                                        -- один параметр
select name, setting, unit, source, pending_restart from pg_settings where name like 'wal%' order by name;   -- багато, з джерелом значення
select name, setting, sourcefile from pg_settings where source = 'configuration file';
select * from pg_file_settings where error is not null;     -- синтаксичні помилки в конфіг-файлах
```
`pending_restart = true` означає, що для застосування потрібен рестарт. На кластері Patroni змінюйте налаштування через `patronictl edit-config` (docs/02).

## 8. Інструменти бекапу і відновлення (командний рядок)

| Інструмент | Що робить | Приклад |
|---|---|---|
| `pg_basebackup` | фізична копія всього кластера | `pg_basebackup -h pg2 -p 5432 -U replicator -D /backup/b1 -Fp -X stream -c fast -P` |
| `pg_dump` | логічна копія однієї бази/таблиці (SQL або custom-формат) | `pg_dump -h haproxy -U postgres -d bank -t core.accounts -Fc -f /tmp/accounts.dump` |
| `pg_restore` | завантажує дамп у custom-форматі | `pg_restore -h haproxy -U postgres -d bank --clean --if-exists -t accounts /tmp/accounts.dump` |
| `pg_rewind` | лагодить розійшовшийся старий primary, щоб він міг іти за новим | Patroni запускає його за вас (`docker logs pg1 \| grep rewind`) |
| `pg_controldata` | контрольний файл кластера: timeline, останній checkpoint, стан | `docker exec pg1 pg_controldata /var/lib/postgresql/data/pgdata` |
| `pg_waldump` | читати записи WAL | `docker exec pg1 pg_waldump -n 5 /var/lib/postgresql/data/pgdata/pg_wal/<segment>` |
| `pg_isready` | чи сервер приймає з'єднання | `pg_isready -h haproxy -p 5000` |

Фізичний бекап + WAL-архів = point-in-time recovery (docs/05, drill 10). Логічний дамп — для перенесення даних, а не для швидкого аварійного відновлення.

## 9. Користувачі та привілеї

```sql
\du+
create role reporting login password 'x' connection limit 5;
grant usage on schema core to reporting;
grant select on all tables in schema core to reporting;
alter default privileges in schema core grant select on tables to reporting;     -- майбутні таблиці теж
revoke all on schema core from reporting;
select grantee, table_schema, table_name, privilege_type from information_schema.role_table_grants where grantee='reporting' limit 5;
```
`pg_hba.conf` вирішує, **хто звідки може підключатись** (тут його генерує Patroni, він в etcd: `patronictl show-config`, ключ `postgresql.pg_hba`).
`select * from pg_hba_file_rules;` показує, що діє.

## 10. Звички, що запобігають аваріям

1. `begin;` перед будь-яким ручним `UPDATE`/`DELETE`; перевірте кількість рядків; лише тоді `commit;`.
2. Спершу пишіть `where`, потім дієслово. `delete from x where …`, набране навпаки, — так спорожняють таблиці.
3. `create index concurrently`, `alter table … add column` без default (або з ним на PG11+), ніколи `vacuum full` у робочий час.
4. Великі зміни запускайте на клоні репліки або з виставленим `lock_timeout`, щоб заблокований `ALTER` не поставив усе за собою в чергу.
5. Знайте свій час відновлення, перш ніж він вам знадобиться.
6. Не запускайте `pg_ctl`, `systemctl restart postgresql` і не редагуйте конфіг-файли на вузлі Patroni. Користуйтесь `patronictl`.

## Вправи (відповіді — у вашому власному виводі)

1. Скільки WAL генерує primary, коли ви оновлюєте 100 тис. рядків? (Виміряйте `pg_current_wal_lsn()` до/після; використайте `pg_wal_lsn_diff`.)
2. Зробіть так, щоб `ops.dead_tuples` показав найбільшого порушника; зробіть vacuum; доведіть через `pg_total_relation_size`, що звичайний vacuum робить і чого не робить.
3. Відтворіть deadlock двома сесіями, що оновлюють рядки 1 і 2 у протилежному порядку. Знайдіть його в `docker logs pg1`. Що зробив Postgres?
4. Змусьте репліку віддавати застарілі читання: `select pg_wal_replay_pause();` на ній, запишіть на primary, прочитайте з `:5441`. Відновіть replay.
5. Знайдіть три найдорожчі запити після десятикратного запуску `docker exec tools psql -d bank -c "select count(*) from core.transactions t join core.accounts a on a.id=t.account_id"`.
