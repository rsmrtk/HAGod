-- A small bank. Big enough that indexes, vacuum and replication lag are real things.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS practice;
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE core.customers (
    id          serial PRIMARY KEY,
    full_name   text        NOT NULL,
    email       text        NOT NULL UNIQUE,
    country     char(2)     NOT NULL,
    risk_level  text        NOT NULL CHECK (risk_level IN ('low','medium','high')),
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.accounts (
    id           serial PRIMARY KEY,
    customer_id  int           NOT NULL REFERENCES core.customers(id),
    iban         text          NOT NULL UNIQUE,
    currency     char(3)       NOT NULL,
    balance      numeric(14,2) NOT NULL DEFAULT 0,
    status       text          NOT NULL DEFAULT 'active' CHECK (status IN ('active','frozen','closed')),
    opened_at    timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX accounts_customer_idx ON core.accounts(customer_id);

CREATE TABLE core.transactions (
    id          bigserial PRIMARY KEY,
    account_id  int           NOT NULL REFERENCES core.accounts(id),
    amount      numeric(14,2) NOT NULL,
    kind        text          NOT NULL CHECK (kind IN ('deposit','withdrawal','transfer_in','transfer_out','fee')),
    status      text          NOT NULL DEFAULT 'posted',
    created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX transactions_account_idx ON core.transactions(account_id, created_at DESC);
CREATE INDEX transactions_created_idx ON core.transactions(created_at);

-- A partitioned table: one child per month. `\d+ audit.events` shows them.
CREATE TABLE audit.events (
    id        bigserial,
    at        timestamptz NOT NULL,
    actor     text        NOT NULL,
    action    text        NOT NULL,
    object    text,
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);
CREATE TABLE audit.events_2026_08 PARTITION OF audit.events FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE audit.events_2026_09 PARTITION OF audit.events FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE audit.events_2026_10 PARTITION OF audit.events FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');

-- Practice tables (see docs/03-postgres-admin.md)
-- 1) no index on `status`: EXPLAIN shows a Seq Scan, add the index and compare
CREATE TABLE practice.slow_orders (
    id         bigserial PRIMARY KEY,
    customer   int  NOT NULL,
    status     text NOT NULL,
    amount     numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
-- 2) autovacuum switched OFF so dead tuples pile up: VACUUM it yourself
CREATE TABLE practice.bloat_demo (id serial PRIMARY KEY, payload text, counter int DEFAULT 0)
    WITH (autovacuum_enabled = false);
-- 3) one hot row that sessions will fight over (lock drills)
CREATE TABLE practice.locks_demo (id int PRIMARY KEY, owner text, note text);
INSERT INTO practice.locks_demo VALUES (1, 'nobody', 'the hot row'), (2, 'nobody', 'another row');
