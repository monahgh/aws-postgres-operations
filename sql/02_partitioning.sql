-- Lab 02: range partitioning, partition pruning and retention
-- Run on the PRIMARY:  use_primary && psql -f /opt/dblab/sql/02_partitioning.sql
-- Runtime: ~1-2 minutes.

\pset pager off
\timing on

\echo '== Setup: events partitioned by month (12 past months + next month + default) =='
DROP TABLE IF EXISTS events CASCADE;

CREATE TABLE events (
  id         bigserial,
  created_at timestamptz NOT NULL,
  kind       text        NOT NULL,
  payload    jsonb,
  PRIMARY KEY (id, created_at)          -- the partition key must be part of every unique key
) PARTITION BY RANGE (created_at);

DO $$
DECLARE
  m date;
BEGIN
  FOR m IN
    SELECT generate_series(date_trunc('month', now()) - interval '11 months',
                           date_trunc('month', now()) + interval '1 month',
                           interval '1 month')::date
  LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
                   'events_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month')::date);
  END LOOP;
END $$;

-- Catches rows outside all ranges (instead of failing the insert).
CREATE TABLE events_default PARTITION OF events DEFAULT;

INSERT INTO events (created_at, kind, payload)
SELECT now() - random() * interval '330 days',
       (ARRAY['login','view','click','purchase'])[1 + (random() * 3)::int],
       jsonb_build_object('n', g)
FROM generate_series(1, 1000000) g;

-- An index on the parent is created on every partition (and on future ones).
CREATE INDEX idx_events_kind_created ON events (kind, created_at);
ANALYZE events;

SELECT i.inhrelid::regclass AS partition,
       pg_size_pretty(pg_relation_size(i.inhrelid)) AS size,
       c.reltuples::bigint AS approx_rows
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'events'::regclass ORDER BY 1;


\echo '== 1. Partition pruning at planning time (constant range) =='
SELECT to_char(date_trunc('month', now()) - interval '2 months', 'YYYY-MM-DD') AS m_start,
       to_char(date_trunc('month', now()) - interval '1 month',  'YYYY-MM-DD') AS m_end \gset
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM events
WHERE created_at >= :'m_start'::timestamptz AND created_at < :'m_end'::timestamptz;
-- Only ONE partition appears in the plan.


\echo '== 2. Pruning at execution time (now() is not a constant) =='
EXPLAIN (ANALYZE)
SELECT count(*) FROM events WHERE created_at >= now() - interval '7 days';
-- Look for "Subplans Removed: N": pruned when the executor starts.


\echo '== 3. Without pruning: every partition is scanned =='
SET enable_partition_pruning = off;
EXPLAIN
SELECT count(*) FROM events
WHERE created_at >= :'m_start'::timestamptz AND created_at < :'m_end'::timestamptz;
RESET enable_partition_pruning;

-- And a query that does NOT filter on the partition key cannot prune at all:
EXPLAIN SELECT count(*) FROM events WHERE kind = 'purchase';


\echo '== 4. Retention: drop the oldest month instantly (no DELETE, no bloat, no vacuum) =='
SELECT 'events_' || to_char(date_trunc('month', now()) - interval '11 months', 'YYYY_MM') AS oldest \gset
\echo Dropping partition :oldest

-- DETACH ... CONCURRENTLY avoids blocking queries, but it is NOT allowed when the table
-- has a DEFAULT partition (like here). Plain DETACH takes a short ACCESS EXCLUSIVE lock.
ALTER TABLE events DETACH PARTITION :"oldest";
-- Detached = an ordinary table: archive it (pg_dump / export to S3) before dropping, if needed.
DROP TABLE :"oldest";

SELECT inhrelid::regclass AS partition FROM pg_inherits
WHERE inhparent = 'events'::regclass ORDER BY 1;

-- Production: pg_partman (available on RDS) creates future partitions and applies
-- retention automatically, run on a schedule by pg_cron.
