-- Lab 04: streaming replication, lag and replication slots
-- Run it TWICE, once on each side; it detects which one it is connected to:
--   use_primary && psql -f /opt/dblab/sql/04_replication.sql
--   use_replica && psql -f /opt/dblab/sql/04_replication.sql
--
-- Two kinds of replication in this project:
--   * Read replica: asynchronous Postgres streaming replication. Readable, can lag,
--     visible in pg_stat_replication.
--   * Multi-AZ standby: synchronous storage-level replication managed by RDS. Not
--     readable, no lag for committed data, invisible to Postgres (not in pg_stat_replication).

\pset pager off

SELECT pg_is_in_recovery() AS is_replica \gset

\if :is_replica

\echo '== Connected to the READ REPLICA =='

\echo '-- Replay position and delay'
SELECT pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn()  AS replayed_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS replay_backlog,
       now() - pg_last_xact_replay_timestamp() AS since_last_replayed_xact;
-- since_last_replayed_xact grows when the primary is idle, so it overstates lag without
-- traffic. The pgbench-load service keeps writes flowing, so here it is close to real lag.

\echo '-- WAL receiver'
SELECT status, sender_host, slot_name, latest_end_time FROM pg_stat_wal_receiver;

\echo '-- Marker written on the primary (run the primary part first)'
SELECT marker, written_at, now() - written_at AS age_on_replica
FROM replication_marker ORDER BY id DESC LIMIT 1;

\echo '-- Queries cancelled because of replay conflicts'
SELECT datname, confl_snapshot, confl_lock, confl_bufferpin, confl_deadlock
FROM pg_stat_database_conflicts WHERE datname = current_database();
SELECT name, setting FROM pg_settings
WHERE name IN ('hot_standby_feedback', 'max_standby_streaming_delay', 'max_standby_archive_delay');
-- Long replica queries either get cancelled (conflict) or, with hot_standby_feedback = on,
-- hold back vacuum on the primary. That is the trade-off.

\echo '-- Writes are rejected: expect "cannot execute INSERT in a read-only transaction"'
INSERT INTO replication_marker (marker) VALUES ('from-replica');

\else

\echo '== Connected to the PRIMARY =='

\echo '-- Connected replicas and lag'
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn))   AS not_yet_sent,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn))            AS sent_not_replayed,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
-- sync_state = async: a commit on the primary does not wait for the replica.

\echo '-- Replication slots: WAL the primary must keep for each consumer'
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
-- An inactive slot retains WAL forever and can fill the disk. On RDS watch the
-- CloudWatch metrics OldestReplicationSlotLag and TransactionLogsDiskUsage.

\echo '-- Write a marker, then run this file on the replica to see it arrive'
CREATE TABLE IF NOT EXISTS replication_marker (
  id         bigserial PRIMARY KEY,
  marker     text        NOT NULL,
  written_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO replication_marker (marker) VALUES ('from-primary') RETURNING id, written_at;

\endif
