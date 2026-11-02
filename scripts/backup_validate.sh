#!/usr/bin/env bash
# Backup validation: prove a snapshot is restorable and contains the data.
#   1. write a canary row and record exact row counts on the primary
#   2. take a manual snapshot
#   3. restore it to a temporary instance
#   4. verify the canary and the counts on the restored instance
#   5. publish RestoreSeconds / ValidationSuccess to CloudWatch
#   6. always delete the temporary instance and snapshot (trap)
# Run on the workload server: bash /opt/dblab/scripts/backup_validate.sh  (~20-30 min)
set -euo pipefail
. /etc/profile.d/dblab.sh

RUN_ID=$(date -u +%Y%m%d%H%M%S)
SNAP_ID="${VALIDATE_PREFIX}-snap-${RUN_ID}"
TEMP_ID="${VALIDATE_PREFIX}-db-${RUN_ID}"
# Tables pgbench only updates (no inserts), so their counts are stable under load.
TABLES="${VALIDATE_TABLES:-pgbench_accounts pgbench_branches pgbench_tellers}"
AWS="aws --region $DBLAB_REGION"

cleanup() {
  echo "== Cleanup: deleting $TEMP_ID and $SNAP_ID =="
  if $AWS rds delete-db-instance --db-instance-identifier "$TEMP_ID" \
       --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1; then
    $AWS rds wait db-instance-deleted --db-instance-identifier "$TEMP_ID" || true
  fi
  $AWS rds delete-db-snapshot --db-snapshot-identifier "$SNAP_ID" >/dev/null 2>&1 || true
  echo "Cleanup done."
}
trap cleanup EXIT

log() { echo "[$(date -u +%T)] $*"; }

log "Writing canary row and recording row counts on the primary"
use_primary >/dev/null
psql -XqAt -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS backup_canary (run_id text PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now());"
psql -XqAt -v ON_ERROR_STOP=1 -c "INSERT INTO backup_canary (run_id) VALUES ('$RUN_ID');"
declare -A EXPECTED
for t in $TABLES; do
  EXPECTED[$t]=$(psql -XAt -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM $t")
  log "  $t = ${EXPECTED[$t]}"
done

log "Creating snapshot $SNAP_ID"
START=$(date +%s)
$AWS rds create-db-snapshot --db-instance-identifier "$PRIMARY_ID" --db-snapshot-identifier "$SNAP_ID" \
  --tags Key=Purpose,Value=backup-validation >/dev/null
$AWS rds wait db-snapshot-available --db-snapshot-identifier "$SNAP_ID"
SNAP_DONE=$(date +%s)
log "Snapshot available after $((SNAP_DONE - START))s"

# Restore into the same subnet group and security group as the primary,
# so this server can reach it on 5432.
read -r SUBNET_GROUP SG_ID <<<"$($AWS rds describe-db-instances --db-instance-identifier "$PRIMARY_ID" \
  --query 'DBInstances[0].[DBSubnetGroup.DBSubnetGroupName,VpcSecurityGroups[0].VpcSecurityGroupId]' --output text)"

log "Restoring to temporary instance $TEMP_ID"
$AWS rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$TEMP_ID" --db-snapshot-identifier "$SNAP_ID" \
  --db-instance-class "${VALIDATE_INSTANCE_CLASS:-db.t4g.micro}" \
  --db-subnet-group-name "$SUBNET_GROUP" --vpc-security-group-ids "$SG_ID" \
  --no-multi-az --no-publicly-accessible \
  --tags Key=Purpose,Value=backup-validation >/dev/null
$AWS rds wait db-instance-available --db-instance-identifier "$TEMP_ID"
RESTORE_DONE=$(date +%s)
RESTORE_SECONDS=$((RESTORE_DONE - SNAP_DONE))
log "Restore available after ${RESTORE_SECONDS}s"

# The restored instance keeps the snapshot's master password (same secret).
# With manage_master_user_password you would set a temporary password here instead.
export PGHOST
PGHOST=$($AWS rds describe-db-instances --db-instance-identifier "$TEMP_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

OK=1
CANARY=$(psql -XAt -c "SELECT count(*) FROM backup_canary WHERE run_id = '$RUN_ID'")
if [ "$CANARY" = "1" ]; then log "PASS canary row $RUN_ID found"; else log "FAIL canary row $RUN_ID missing"; OK=0; fi

for t in $TABLES; do
  GOT=$(psql -XAt -c "SELECT count(*) FROM $t" || echo "error")
  if [ "$GOT" = "${EXPECTED[$t]}" ]; then
    log "PASS $t: $GOT rows"
  else
    log "FAIL $t: expected ${EXPECTED[$t]}, got $GOT"; OK=0
  fi
done

TOTAL=$(( $(date +%s) - START ))
log "Total validation time: ${TOTAL}s (snapshot $((SNAP_DONE - START))s, restore ${RESTORE_SECONDS}s)"

METRICS=$(jq -n --arg db "$PRIMARY_ID" --argjson restore "$RESTORE_SECONDS" --argjson ok "$OK" '[
  {MetricName: "RestoreSeconds",    Value: $restore, Unit: "Seconds", Dimensions: [{Name: "DBInstanceIdentifier", Value: $db}]},
  {MetricName: "ValidationSuccess", Value: $ok,      Unit: "Count",   Dimensions: [{Name: "DBInstanceIdentifier", Value: $db}]}
]')
$AWS cloudwatch put-metric-data --namespace DBLab/BackupValidation --metric-data "$METRICS"
log "Published DBLab/BackupValidation metrics"

if [ "$OK" = "1" ]; then log "RESULT: backup is restorable and consistent"; else log "RESULT: validation FAILED"; exit 1; fi
