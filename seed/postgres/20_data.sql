INSERT INTO core.customers (full_name, email, country, risk_level, created_at)
SELECT 'Customer ' || g,
       'customer' || g || '@bank.example',
       (ARRAY['UA','SK','PL','DE','CZ','AT'])[1 + g % 6],
       (ARRAY['low','low','low','medium','high'])[1 + g % 5],
       now() - (g % 1500) * interval '1 day'
FROM generate_series(1, 10000) g;

INSERT INTO core.accounts (customer_id, iban, currency, balance, status, opened_at)
SELECT 1 + (g % 10000),
       'UA' || lpad(g::text, 27, '0'),
       (ARRAY['UAH','EUR','USD'])[1 + g % 3],
       round((random() * 50000)::numeric, 2),
       (ARRAY['active','active','active','active','frozen','closed'])[1 + g % 6],
       now() - (g % 1200) * interval '1 day'
FROM generate_series(1, 25000) g;

INSERT INTO core.transactions (account_id, amount, kind, status, created_at)
SELECT 1 + (g % 25000),
       round((random() * 2000)::numeric, 2),
       (ARRAY['deposit','withdrawal','transfer_in','transfer_out','fee'])[1 + g % 5],
       (ARRAY['posted','posted','posted','pending','failed'])[1 + g % 5],
       now() - (random() * 365) * interval '1 day'
FROM generate_series(1, 400000) g;

INSERT INTO audit.events (at, actor, action, object)
SELECT timestamp '2026-08-01' + (random() * 80) * interval '1 day',
       'user' || (g % 200),
       (ARRAY['login','logout','view_account','create_transfer','change_limit'])[1 + g % 5],
       'account:' || (g % 25000)
FROM generate_series(1, 120000) g;

INSERT INTO practice.slow_orders (customer, status, amount)
SELECT g % 5000, (ARRAY['new','paid','shipped','cancelled','refunded'])[1 + g % 5], round((random()*500)::numeric, 2)
FROM generate_series(1, 300000) g;

INSERT INTO practice.bloat_demo (payload) SELECT repeat('x', 200) FROM generate_series(1, 50000);
-- make 40% of the table dead tuples; autovacuum is off, so they stay
UPDATE practice.bloat_demo SET counter = counter + 1 WHERE id % 5 < 2;

ANALYZE;
