#!/usr/bin/env bash
# Lab 13 Step 24 - the guide's inventory(), in a script, re-deriving every value from the API.
# One change: alarms are listed by their CONFIGURATION (metric, statistic, threshold,
# missing-data policy), not their state. On Floci 2.2.0 alarms are really evaluated, so a
# state can change between two readings for reasons that have nothing to do with persistence
# (usms-notify-silence above all). States are printed by lab-13-alarm-states.sh instead.
# Floci has no composite alarms, so the composite is represented by its committed document.
#   ./scripts/utilities/lab-13-restart-facts.sh > outputs/lab-13-pre-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

echo "--- log groups ---"
aws logs describe-log-groups \
  --query 'sort_by(logGroups, &logGroupName)[?starts_with(logGroupName, `/usms/`) || contains(logGroupName, `usms`)].[logGroupName,retentionInDays]' --output text
echo "--- metric filters ---"
aws logs describe-metric-filters \
  --query 'sort_by(metricFilters, &filterName)[].[filterName,logGroupName,filterPattern]' --output text
echo "--- metrics ---"
aws cloudwatch list-metrics --namespace USMS/Application \
  --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u
echo "--- alarms (configuration) ---"
aws cloudwatch describe-alarms --alarm-name-prefix usms- \
  --query 'sort_by(MetricAlarms, &AlarmName)[].[AlarmName,MetricName,Statistic,Threshold,TreatMissingData]' --output text
echo "--- composite (document; no composite alarms on this build) ---"
python3 -c 'import json;d=json.load(open("templates/lab-13-composite-alarm.json"));print(d["AlarmName"], d["AlarmRule"], sep="\t")'
echo "--- dashboards ---"
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text
echo "--- iam ---"
aws iam list-attached-role-policies --role-name usms-lambda-exec-role --query 'AttachedPolicies[].PolicyName' --output text
echo "--- notifier ---"
aws lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live \
  --query '[Version,TracingConfig.Mode]' --output text
