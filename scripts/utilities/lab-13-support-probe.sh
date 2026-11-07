#!/usr/bin/env bash
# Lab 13 Step 4 - which observability APIs this Floci build answers. Read-only.
# The guide's inline probe() in a script, with the time window from python3 (portable),
# and three extra probes that later steps depend on.
#   ./scripts/utilities/lab-13-support-probe.sh | tee outputs/lab-13-support-probe.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

probe() {   # $1 = label, then the command as words
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  SUPPORTED    %s\n' "$label"
  else printf '  UNSUPPORTED  %s\n' "$label"; fi
}
read -r T0 T1 < <(python3 -c 'import time; n=int(time.time()); print(n-300, n)')

printf 'Floci support probe for Lab 13 - %s\n\n' "$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
probe "logs       (describe-log-groups)"    aws logs describe-log-groups --limit 1
probe "logs       (put-metric-filter API)"  aws logs describe-metric-filters --limit 1
# The guide labels this probe "Insights start-query" but runs describe-queries; labelled for what it runs.
probe "logs       (Insights describe-queries)" aws logs describe-queries --max-results 1
probe "cloudwatch (list-metrics)"           aws cloudwatch list-metrics --namespace AWS/Lambda
probe "cloudwatch (describe-alarms)"        aws cloudwatch describe-alarms --max-records 1
probe "cloudwatch (list-dashboards)"        aws cloudwatch list-dashboards
probe "xray       (get-sampling-rules)"     aws xray get-sampling-rules
probe "xray       (get-service-graph)"      aws xray get-service-graph --start-time "$T0" --end-time "$T1"
probe "lambda     (get-function-config)"    aws lambda get-function-configuration --function-name usms-transcript-notifier
# Added: the later steps that change their path on the answer.
probe "xray       (get-trace-summaries)"    aws xray get-trace-summaries --start-time "$T0" --end-time "$T1"
probe "logs       (test-metric-filter)"     aws logs test-metric-filter --filter-pattern X --log-event-messages X
# Insights itself: start-query with the simplest query. SUPPORTED here only means the call is
# accepted - on Floci 2.2.0 just `fields | limit` completes (outputs/lab-13-insights-probe.txt).
probe "logs       (Insights start-query)"   aws logs start-query --log-group-name /usms/central/application \
                                              --start-time "$T0" --end-time "$T1" --query-string 'fields @message | limit 1'
# A read probe cannot show write support, and a write probe would create an alarm on real AWS,
# so this one reads only. Floci 2.2.0 answers it but rejects PutCompositeAlarm (Step 21).
probe "cloudwatch (composite: describe only)" aws cloudwatch describe-alarms --alarm-types CompositeAlarm --max-records 1
printf '\n  note: PutCompositeAlarm is UNSUPPORTED (Step 21); Insights runs fields|limit only\n'
