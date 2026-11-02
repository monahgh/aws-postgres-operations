#!/usr/bin/env bash
# Continuous, rate-limited pgbench load against the primary.
# Started by pgbench-load.service (see setup_workload.sh). Tune with
# PGBENCH_CLIENTS / PGBENCH_RATE (transactions per second) / PGBENCH_DURATION.
set -uo pipefail
. /etc/profile.d/dblab.sh

CLIENTS="${PGBENCH_CLIENTS:-4}"
RATE="${PGBENCH_RATE:-20}"
DURATION="${PGBENCH_DURATION:-300}"

while true; do
  # Re-read the secret and endpoint every round, so the load survives failovers.
  if use_primary; then
    pgbench -n -c "$CLIENTS" -j 2 -R "$RATE" -T "$DURATION" -P 60 || echo "pgbench exited with $?, retrying"
  fi
  sleep 5
done
