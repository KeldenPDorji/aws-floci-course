#!/usr/bin/env bash
# Lab 13 Step 5 - the monitoring the course already created. Read-only.
# The guide's inventory block, in a script so it can be re-run (and compared after Step 6).
#   ./scripts/utilities/lab-13-telemetry-inventory.sh | tee outputs/lab-13-telemetry-inventory.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

printf 'USMS telemetry inventory - %s\n\n' "$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
printf '== log groups ==\n'
aws logs describe-log-groups \
  --query 'sort_by(logGroups, &logGroupName)[].[logGroupName,retentionInDays,storedBytes]' --output text
printf '\n== alarms ==\n'
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[].[AlarmName,Namespace,MetricName,StateValue]' --output text
printf '\n== metric namespaces already present ==\n'
aws cloudwatch list-metrics --query 'sort_by(Metrics, &Namespace)[].Namespace' --output text \
  | tr '\t' '\n' | sort -u
printf '\n== dashboards ==\n'
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text
