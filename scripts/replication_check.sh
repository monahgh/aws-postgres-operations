#!/usr/bin/env bash
# Replication health check: SQL view from the primary and the replica, plus the
# CloudWatch ReplicaLag metric. Exits 1 if the max lag exceeds LAG_THRESHOLD_SECONDS,
# so it can be used by cron or a monitoring job.
#   bash /opt/dblab/scripts/replication_check.sh
set -euo pipefail
. /etc/profile.d/dblab.sh

LAG_THRESHOLD_SECONDS="${LAG_THRESHOLD_SECONDS:-30}"

echo "== Primary: pg_stat_replication =="
use_primary >/dev/null
psql -X -P pager=off -c "
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;"

echo "== Primary: replication slots (WAL retained on the primary) =="
psql -X -P pager=off -c "
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;"

echo "== Replica: replay position and delay =="
use_replica >/dev/null
psql -X -P pager=off -c "
SELECT pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS received,
       pg_last_wal_replay_lsn() AS replayed,
       now() - pg_last_xact_replay_timestamp() AS since_last_replayed_xact;"

echo "== CloudWatch ReplicaLag, last 15 minutes (seconds) =="
aws cloudwatch get-metric-statistics --region "$DBLAB_REGION" \
  --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_ID" \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' --output table

MAX_LAG=$(aws cloudwatch get-metric-statistics --region "$DBLAB_REGION" \
  --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_ID" \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 900 --statistics Maximum --query 'Datapoints[0].Maximum' --output text)

if [ "$MAX_LAG" = "None" ]; then
  echo "No ReplicaLag datapoints yet."
elif awk -v lag="$MAX_LAG" -v t="$LAG_THRESHOLD_SECONDS" 'BEGIN { exit !(lag > t) }'; then
  echo "ALERT: max replica lag ${MAX_LAG}s is above ${LAG_THRESHOLD_SECONDS}s"
  exit 1
else
  echo "OK: max replica lag ${MAX_LAG}s (threshold ${LAG_THRESHOLD_SECONDS}s)"
fi
