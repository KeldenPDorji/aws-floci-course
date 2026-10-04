#!/bin/bash
# USMS data tier bootstrap (Lab 03 Exercise 2). Runs as root at first boot, via cloud-init.
# Idempotent: the marker file is the guard. A second run exits here and changes nothing.
MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then
  echo "usms-db bootstrap already done: $(cat "$MARKER")"
  exit 0
fi

set -euxo pipefail
exec > /var/log/usms-db-bootstrap.log 2>&1
echo "USMS db bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

dnf -y install postgresql15-server

# Each step is guarded too, so a run interrupted half-way can be resumed safely.
[ -f /var/lib/pgsql/data/PG_VERSION ] || postgresql-setup --initdb
systemctl enable --now postgresql

runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='usms'" | grep -q 1 \
  || runuser -u postgres -- createdb usms

# IMDSv2, same as the web tier's user data.
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")

# Written LAST: the marker only exists if everything above succeeded.
printf '%s %s\n' "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
echo "USMS db bootstrap complete"
