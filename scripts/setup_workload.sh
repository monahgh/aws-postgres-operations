#!/usr/bin/env bash
# One-time setup of the workload server. Run in a Session Manager shell (see the
# Terraform output workload_bootstrap_command):
#   sudo aws s3 sync --region <region> s3://<lab-bucket> /opt/dblab
#   sudo bash /opt/dblab/scripts/setup_workload.sh
#
# Installs psql/pgbench/jq, installs shell helpers (use_primary, use_replica, labsync),
# seeds pgbench tables and starts a continuous, rate-limited pgbench load service.
# Idempotent: safe to run again.
set -euo pipefail

DBLAB_DIR=/opt/dblab

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[ -f "$DBLAB_DIR/dblab.env" ] || { echo "Missing $DBLAB_DIR/dblab.env. Run the aws s3 sync command first."; exit 1; }
. "$DBLAB_DIR/dblab.env"

echo "== Installing PostgreSQL client tools =="
if command -v psql >/dev/null 2>&1; then
  # Keep the already installed client version and add its contrib package (pgbench).
  PG_MAJOR=$(psql --version | awk '{print $3}' | cut -d. -f1)
  dnf install -y "postgresql${PG_MAJOR}-contrib" || true
else
  for v in 17 16 15; do
    if dnf install -y "postgresql${v}" "postgresql${v}-contrib"; then break; fi
  done
fi
dnf install -y jq
command -v psql >/dev/null || { echo "psql is not installed"; exit 1; }
command -v pgbench >/dev/null || { echo "pgbench is not installed"; exit 1; }
chmod +x "$DBLAB_DIR"/scripts/*.sh

echo "== Installing shell helpers in /etc/profile.d/dblab.sh =="
cat > /etc/profile.d/dblab.sh <<'EOF'
# PostgreSQL lab helpers (installed by /opt/dblab/scripts/setup_workload.sh).
# use_primary / use_replica export PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE
# from Secrets Manager and the RDS API, so plain `psql` connects.
if [ -f /opt/dblab/dblab.env ]; then
  . /opt/dblab/dblab.env

  _dblab_creds() {
    _s=$(aws secretsmanager get-secret-value --region "$DBLAB_REGION" --secret-id "$SECRET_ID" \
      --query SecretString --output text) || return 1
    PGUSER=$(printf '%s' "$_s" | jq -r .username)
    PGPASSWORD=$(printf '%s' "$_s" | jq -r .password)
    export PGUSER PGPASSWORD
    unset _s
  }

  _dblab_endpoint() {
    aws rds describe-db-instances --region "$DBLAB_REGION" --db-instance-identifier "$1" \
      --query 'DBInstances[0].Endpoint.Address' --output text
  }

  _dblab_use() {
    _dblab_creds || return 1
    PGHOST=$(_dblab_endpoint "$1") || return 1
    export PGHOST PGPORT=5432 PGDATABASE="$DB_NAME" PGSSLMODE=require
    echo "psql now points at $1 ($PGHOST)"
  }

  use_primary() { _dblab_use "$PRIMARY_ID"; }
  use_replica() { _dblab_use "$REPLICA_ID"; }

  labsync() {
    sudo aws s3 sync --region "$DBLAB_REGION" --quiet "s3://$DBLAB_BUCKET" /opt/dblab &&
      sudo chmod +x /opt/dblab/scripts/*.sh &&
      . /opt/dblab/dblab.env &&
      echo "synced s3://$DBLAB_BUCKET -> /opt/dblab"
  }
fi
EOF
. /etc/profile.d/dblab.sh

echo "== Seeding pgbench tables on the primary =="
use_primary
if [ "$(psql -XAtc "SELECT to_regclass('public.pgbench_accounts') IS NOT NULL")" = "t" ]; then
  echo "pgbench tables already exist, skipping."
else
  pgbench -i -s "${PGBENCH_SCALE:-10}" --foreign-keys
fi

echo "== Installing pgbench-load.service =="
cat > /etc/systemd/system/pgbench-load.service <<EOF
[Unit]
Description=Continuous rate-limited pgbench load against the RDS primary
After=network-online.target
Wants=network-online.target

[Service]
User=ec2-user
Environment=PGBENCH_CLIENTS=4
Environment=PGBENCH_RATE=20
ExecStart=$DBLAB_DIR/scripts/pgbench_load.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pgbench-load.service
systemctl restart pgbench-load.service

echo
echo "Done. Next:"
echo "  bash -l                       # load the helpers into your shell"
echo "  use_primary && psql           # or: use_replica && psql"
echo "  sudo journalctl -u pgbench-load -f # watch the background load"
