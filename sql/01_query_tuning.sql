-- Lab 01: query tuning and indexing
-- Run on the PRIMARY:  use_primary && psql -f /opt/dblab/sql/01_query_tuning.sql
-- Or open psql and paste one section at a time (recommended: explain each plan as you go).
-- Runtime end to end: ~3-5 minutes on db.t4g.micro.

\pset pager off
\timing on

\echo '== 0. pg_stat_statements (preloaded on RDS; the extension just exposes the view) =='
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT pg_stat_statements_reset();  -- may need rds_superuser; harmless if it errors

\echo '== Setup: 200k customers, 2M orders =='
DROP TABLE IF EXISTS orders, customers CASCADE;

CREATE TABLE customers (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email      text        NOT NULL,
  country    text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO customers (email, country, created_at)
SELECT 'User' || g || '@Example.com',
       (ARRAY['DE','FR','US','LB','CA'])[1 + g % 5],
       now() - (g % 1000) * interval '1 day'
FROM generate_series(1, 200000) g;

-- The foreign key is indexed on the parent (PK) side only. Postgres does NOT
-- create an index on the referencing column automatically.
CREATE TABLE orders (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint        NOT NULL REFERENCES customers (id),
  status      text          NOT NULL,
  amount      numeric(10,2) NOT NULL,
  created_at  timestamptz   NOT NULL
);
INSERT INTO orders (customer_id, status, amount, created_at)
SELECT 1 + (random() * 199999)::int,
       CASE WHEN random() < 0.01 THEN 'refunded'   -- rare status: ~1%
            WHEN random() < 0.30 THEN 'pending'
            ELSE 'shipped' END,
       round((random() * 500)::numeric, 2),
       now() - random() * interval '365 days'
FROM generate_series(1, 2000000);
ANALYZE customers;
ANALYZE orders;

SELECT pg_size_pretty(pg_total_relation_size('orders')) AS orders_size,
       pg_size_pretty(pg_total_relation_size('customers')) AS customers_size;


\echo '== 1. Foreign key without an index =='
-- Lookup by customer: full (parallel) sequential scan over 2M rows.
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 4242;

-- Deleting a parent row makes Postgres check orders for children: another full scan.
-- Look for "Trigger for constraint orders_customer_id_fkey: time=..." in the output.
BEGIN;
INSERT INTO customers (email, country) VALUES ('fk-demo@example.com', 'DE') RETURNING id AS demo_id \gset
EXPLAIN (ANALYZE) DELETE FROM customers WHERE id = :demo_id;
ROLLBACK;

-- Build the index without blocking writes (no ACCESS EXCLUSIVE lock).
-- CONCURRENTLY cannot run inside a transaction block.
CREATE INDEX CONCURRENTLY idx_orders_customer ON orders (customer_id);

-- A failed CONCURRENTLY build leaves an INVALID index behind: always check.
SELECT indexrelid::regclass AS invalid_index FROM pg_index WHERE NOT indisvalid;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 4242;   -- Index/Bitmap scan
BEGIN;
INSERT INTO customers (email, country) VALUES ('fk-demo@example.com', 'DE') RETURNING id AS demo_id \gset
EXPLAIN (ANALYZE) DELETE FROM customers WHERE id = :demo_id;                -- FK trigger now ~0.1 ms
ROLLBACK;


\echo '== 2. Composite index column order: equality first, range/sort last =='
-- Query: one customer's recent orders, newest first.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount, created_at FROM orders
WHERE customer_id = 4242 AND created_at >= now() - interval '90 days'
ORDER BY created_at DESC;

-- Wrong order: range column first. The planner cannot jump to one customer, so it ignores it.
CREATE INDEX idx_orders_created_customer ON orders (created_at, customer_id);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount, created_at FROM orders
WHERE customer_id = 4242 AND created_at >= now() - interval '90 days'
ORDER BY created_at DESC;

-- Right order: equality column first. Index Scan Backward, no Sort node, no Filter.
CREATE INDEX idx_orders_customer_created ON orders (customer_id, created_at);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount, created_at FROM orders
WHERE customer_id = 4242 AND created_at >= now() - interval '90 days'
ORDER BY created_at DESC;

DROP INDEX idx_orders_created_customer;  -- wrong-order index is useless for this query


\echo '== 3. Covering index (INCLUDE) + VACUUM -> Index Only Scan, Heap Fetches: 0 =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, sum(amount) FROM orders
WHERE customer_id BETWEEN 1000 AND 3000 GROUP BY customer_id;   -- visits the heap for amount

CREATE INDEX idx_orders_customer_incl ON orders (customer_id) INCLUDE (amount);
-- Index-only scans need the visibility map: VACUUM sets the all-visible bits.
VACUUM (ANALYZE) orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, sum(amount) FROM orders
WHERE customer_id BETWEEN 1000 AND 3000 GROUP BY customer_id;   -- Index Only Scan, Heap Fetches: 0


\echo '== 4. Partial index for a rare status =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, customer_id, amount, created_at FROM orders
WHERE status = 'refunded' ORDER BY created_at DESC LIMIT 20;    -- seq scan + top-N sort

CREATE INDEX idx_orders_refunded ON orders (created_at) WHERE status = 'refunded';

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, customer_id, amount, created_at FROM orders
WHERE status = 'refunded' ORDER BY created_at DESC LIMIT 20;    -- Index Scan Backward on the partial index

-- The partial index covers ~1% of rows, so it is tiny compared to a full index.
SELECT indexrelid::regclass AS index, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index WHERE indrelid = 'orders'::regclass ORDER BY pg_relation_size(indexrelid) DESC;


\echo '== 5. Expression index: case-insensitive email lookup =='
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM customers WHERE lower(email) = 'user4242@example.com';   -- seq scan: plain index on email would not help

CREATE INDEX idx_customers_lower_email ON customers (lower(email));
ANALYZE customers;   -- collects statistics for the expression

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM customers WHERE lower(email) = 'user4242@example.com';   -- Index Scan


\echo '== 6. work_mem: sort spilling to disk =='
SET max_parallel_workers_per_gather = 0;  -- one process, easier to read
SET work_mem = '1MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT id, amount FROM orders ORDER BY amount;
-- Look for: Sort Method: external merge  Disk: ...kB  (temp files)

SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT id, amount FROM orders ORDER BY amount;
-- Look for: Sort Method: quicksort  Memory: ...kB
-- work_mem is per sort/hash node per connection: raise it per session or per role,
-- not globally. log_temp_files = 0 logs every spill.
RESET work_mem;
RESET max_parallel_workers_per_gather;


\echo '== 7. pg_stat_statements: top queries =='
SELECT calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
       temp_blks_written,
       left(regexp_replace(query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;


\echo '== 8. Unused and redundant indexes =='
-- An index nobody queries still costs write amplification, WAL, vacuum time and storage.
CREATE INDEX idx_customers_country ON customers (country);

SELECT s.relname AS table_name, s.indexrelname AS index_name, s.idx_scan,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;

-- Redundant: an index whose columns are a leading prefix of another index on the same table.
-- idx_orders_customer (customer_id) is covered by idx_orders_customer_created (customer_id, created_at).
SELECT a.indexrelid::regclass AS redundant_index, b.indexrelid::regclass AS covered_by
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
WHERE a.indrelid = 'orders'::regclass
  AND NOT a.indisunique
  AND a.indpred IS NULL AND b.indpred IS NULL
  AND b.indkey::text LIKE a.indkey::text || ' %';

-- Note: idx_scan counters are per instance. Check the read replica too before dropping,
-- and reset time (pg_stat_reset) matters: "0 scans since yesterday" is not "never used".
