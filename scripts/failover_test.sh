#!/usr/bin/env bash
# Multi-AZ failover test. Writes to the primary endpoint twice a second, forces a
# failover to the standby, and reports how long writes were unavailable.
# Run on the workload server: bash /opt/dblab/scripts/failover_test.sh  (~5 min)
set -euo pipefail
. /etc/profile.d/dblab.sh

AWS="aws --region $DBLAB_REGION"
LOG=$(mktemp /tmp/failover_probe.XXXXXX)
export PGCONNECT_TIMEOUT=2

azs() {
  $AWS rds describe-db-instances --db-instance-identifier "$PRIMARY_ID" \
    --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text
}

use_primary >/dev/null
psql -XqAt -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS failover_probe (id bigserial PRIMARY KEY, written_at timestamptz NOT NULL DEFAULT clock_timestamp());"
echo "Before: primary AZ / standby AZ = $(azs)"

probe() {
  while true; do
    ts=$(date +%s.%N)
    # New connection every probe: also measures DNS switching to the new primary.
    if out=$(timeout 3 psql -XqAt -F ' ' -c "INSERT INTO failover_probe DEFAULT VALUES RETURNING inet_server_addr(), pg_is_in_recovery()" 2>/dev/null); then
      echo "$ts OK $out"
    else
      echo "$ts FAIL"
    fi
    sleep 0.5
  done
}

probe >"$LOG" &
PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT

sleep 10
echo "[$(date -u +%T)] Forcing failover of $PRIMARY_ID"
$AWS rds reboot-db-instance --db-instance-identifier "$PRIMARY_ID" --force-failover >/dev/null
sleep 30 # give the status time to leave 'available'
$AWS rds wait db-instance-available --db-instance-identifier "$PRIMARY_ID"
echo "[$(date -u +%T)] Instance available again, probing 20 more seconds"
sleep 20
kill $PROBE_PID 2>/dev/null || true

echo "After:  primary AZ / standby AZ = $(azs)"
echo "Probe log: $LOG"
awk '
  $2 == "FAIL" { if (!first_fail) first_fail = $1; need_recover = 1; fails++ }
  $2 == "OK"   { if (!ip_before) ip_before = $3; ip_after = $3; ok++
                 if (need_recover) { recovered = $1; need_recover = 0 } }
  END {
    printf "Probes: %d ok, %d failed\n", ok, fails
    if (!fails)            print "No failed writes observed."
    else if (need_recover) print "Writes had not recovered when probing stopped."
    else printf "Write unavailability: %.1f s (first failed write -> first successful write after the last failure)\n", recovered - first_fail
    printf "Server IP before: %s  after: %s\n", ip_before, ip_after
  }' "$LOG"
