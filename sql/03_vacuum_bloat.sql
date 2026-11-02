-- Lab 03: MVCC, vacuum, bloat, HOT updates, xmin horizon, XID wraparound
-- Run on the PRIMARY:  use_primary && psql -f /opt/dblab/sql/03_vacuum_bloat.sql
-- Section 5 needs TWO Session Manager sessions (instructions below).

\pset pager off
\timing on

\echo '== 1. Dead tuples: every UPDATE writes a new row version =='
DROP TABLE IF EXISTS bloat_demo;
CREATE TABLE bloat_demo (
  id      int  PRIMARY KEY,
  counter int  NOT NULL DEFAULT 0,
  filler  text NOT NULL
) WITH (autovacuum_enabled = false);   -- off only so we can watch the dead rows

INSERT INTO bloat_demo SELECT g, 0, repeat('x', 200) FROM generate_series(1, 200000) g;
ANALYZE bloat_demo;
SELECT pg_size_pretty(pg_table_size('bloat_demo')) AS size_before_update;

UPDATE bloat_demo SET counter = counter + 1;
SELECT pg_stat_force_next_flush();
SELECT n_live_tup, n_dead_tup, pg_size_pretty(pg_table_size('bloat_demo')) AS size_after_update
FROM pg_stat_user_tables WHERE relname = 'bloat_demo';   -- ~200k dead, size ~doubled


\echo '== 2. VACUUM vs VACUUM FULL =='
-- VACUUM: marks dead space reusable, no exclusive lock, file size stays the same.
VACUUM (VERBOSE) bloat_demo;
SELECT pg_stat_force_next_flush();
SELECT n_dead_tup, pg_size_pretty(pg_table_size('bloat_demo')) AS size_after_vacuum
FROM pg_stat_user_tables WHERE relname = 'bloat_demo';

-- Another full update reuses the freed space: size barely grows.
UPDATE bloat_demo SET counter = counter + 1;
VACUUM bloat_demo;
SELECT pg_size_pretty(pg_table_size('bloat_demo')) AS size_after_second_update;

-- VACUUM FULL rewrites the table and returns space to the OS, but holds an
-- ACCESS EXCLUSIVE lock (no reads or writes) for the whole rewrite.
VACUUM FULL bloat_demo;
SELECT pg_size_pretty(pg_table_size('bloat_demo')) AS size_after_vacuum_full;
-- Production: pg_repack (available on RDS) does the same rewrite online with only brief locks.


\echo '== 3. HOT updates and fillfactor =='
-- HOT (heap-only tuple): if no indexed column changes AND the new version fits on the
-- same page, no index entries are written. fillfactor leaves free space on each page.
DROP TABLE IF EXISTS hot_ff100, hot_ff70;
CREATE TABLE hot_ff100 (id int PRIMARY KEY, status text, note text) WITH (fillfactor = 100, autovacuum_enabled = false);
CREATE TABLE hot_ff70  (id int PRIMARY KEY, status text, note text) WITH (fillfactor = 70,  autovacuum_enabled = false);
INSERT INTO hot_ff100 SELECT g, 'new', repeat('y', 100) FROM generate_series(1, 100000) g;
INSERT INTO hot_ff70  SELECT g, 'new', repeat('y', 100) FROM generate_series(1, 100000) g;

UPDATE hot_ff100 SET status = 'done' WHERE id % 4 = 0;
UPDATE hot_ff70  SET status = 'done' WHERE id % 4 = 0;
SELECT pg_stat_force_next_flush();

SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd, 0), 1) AS hot_pct,
       pg_size_pretty(pg_table_size(relid)) AS size
FROM pg_stat_user_tables WHERE relname LIKE 'hot_ff%' ORDER BY relname;
-- Expect: fillfactor 70 -> ~100% HOT; fillfactor 100 -> close to 0% HOT.
-- Trade-off: lower fillfactor = bigger table, fewer index writes on update-heavy tables.


\echo '== 4. Per-table autovacuum settings =='
-- Global default: vacuum when dead rows > 50 + 20% of the table. Too lazy for big hot tables.
SELECT name, setting FROM pg_settings
WHERE name IN ('autovacuum_vacuum_scale_factor', 'autovacuum_vacuum_threshold',
               'autovacuum_analyze_scale_factor', 'autovacuum_max_workers',
               'autovacuum_vacuum_cost_limit', 'log_autovacuum_min_duration');

ALTER TABLE bloat_demo SET (
  autovacuum_enabled              = true,
  autovacuum_vacuum_scale_factor  = 0.01,   -- 1% instead of 20%
  autovacuum_vacuum_threshold     = 1000,
  autovacuum_analyze_scale_factor = 0.02
);
SELECT relname, reloptions FROM pg_class WHERE relname = 'bloat_demo';

-- Tables closest to needing vacuum:
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_vacuum, last_autovacuum, autovacuum_count
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;


\echo '== 5. Long transaction holding back the xmin horizon (two sessions) =='
-- Session A (second Session Manager window: bash -l; use_primary; psql):
--     BEGIN ISOLATION LEVEL REPEATABLE READ;
--     SELECT count(*) FROM bloat_demo;       -- takes a snapshot; leave the transaction OPEN
-- Session B (this one):
--     UPDATE bloat_demo SET counter = counter + 1;
--     VACUUM (VERBOSE) bloat_demo;
--     -> "200000 are dead but not yet removable, oldest xmin: ..."  Vacuum cannot clean
--        anything newer than the oldest open snapshot, so bloat grows while A stays open.
-- Session A:  COMMIT;
-- Session B:  VACUUM (VERBOSE) bloat_demo;   -> now the dead rows are removed.
--
-- Find the session holding the horizon:
SELECT pid, usename, state, now() - xact_start AS xact_age,
       backend_xmin, age(backend_xmin) AS xmin_age, left(query, 60) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC LIMIT 5;
-- Other horizon holders: replication slots (pg_replication_slots.xmin), prepared
-- transactions (pg_prepared_xacts), and replica queries when hot_standby_feedback = on.
-- Guard rail: idle_in_transaction_session_timeout.


\echo '== 6. XID wraparound monitoring =='
-- Transaction IDs are 32-bit. Vacuum must "freeze" old rows before age reaches ~2 billion,
-- or Postgres stops accepting writes. Autovacuum forces this at autovacuum_freeze_max_age.
SELECT datname, age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2147483647, 3) AS pct_to_wraparound
FROM pg_database ORDER BY xid_age DESC;

SELECT c.oid::regclass AS table_name, age(c.relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class c
WHERE c.relkind IN ('r', 'm', 't')
ORDER BY age(c.relfrozenxid) DESC LIMIT 10;
-- On RDS also alarm on the CloudWatch metric MaximumUsedTransactionIDs (e.g. > 1 billion).


\echo '== 7. Watching a vacuum in progress =='
-- Session A:  VACUUM (VERBOSE) pgbench_accounts;   (or orders, from lab 01)
-- Session B:  run this and add \watch 1 to refresh every second:
SELECT p.pid, p.relid::regclass AS table_name, p.phase,
       p.heap_blks_scanned, p.heap_blks_total,
       round(100.0 * p.heap_blks_scanned / nullif(p.heap_blks_total, 0), 1) AS pct_scanned,
       p.index_vacuum_count, p.num_dead_tuples   -- PG 16 column names (PG 17 renamed them)
FROM pg_stat_progress_vacuum p;
