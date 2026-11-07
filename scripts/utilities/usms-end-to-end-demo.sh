#!/usr/bin/env bash
# Project Checkpoint 1 - one path through USMS, end to end, captured as text so a doubter can
# re-run it. The guide's nine stages (Lab 13 appendix, section 4) as a script, with one addition:
# the guide's stage 5 says "upload a transcript" but runs only the telemetry emitter, which never
# touches the bucket. Stage 5b uploads a real object, so the chain bucket -> notification ->
# notifier (alias live) -> USMS_NOTIFY line -> NotifyCount is exercised, not just described.
# Writes one object, transcripts/evidence/checkpoint-01-demo.json, overwritten on every run.
#   ./scripts/utilities/usms-end-to-end-demo.sh | tee project/checkpoint-01/evidence/end-to-end.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-13.env

KEY=transcripts/evidence/checkpoint-01-demo.json
FN_LOG=/aws/lambda/usms-transcript-notifier
utc() { python3 -c 'import datetime as d;print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }

printf 'USMS end-to-end demonstration - %s\n\n' "$(utc)"

printf -- '--- 1. identity: who am I, and what may this role do ---\n'
./scripts/utilities/whoami.sh | perl -pe 's/\e\[[0-9;]*m//g'   # colour codes off: this is a text file
aws iam list-attached-role-policies --role-name usms-lambda-exec-role \
  --query 'AttachedPolicies[].PolicyName' --output text

printf -- '\n--- 2. storage: the bucket four policies have named since Lab 01 ---\n'
aws s3api head-bucket --bucket usms-student-data && echo "head-bucket: exit 0"

printf -- '\n--- 3. trigger: what the bucket does when an object arrives ---\n'
aws s3api get-bucket-notification-configuration --bucket usms-student-data \
  --query 'LambdaFunctionConfigurations[].[Id,LambdaFunctionArn]' --output text

printf -- '\n--- 4. compute: the function that runs, and the version behind the alias ---\n'
aws lambda get-function-configuration --function-name usms-transcript-notifier \
  --qualifier live --query '[Version,Runtime,TracingConfig.Mode]' --output text

printf -- '\n--- 5. the event: one transcript, as telemetry (usms-emit-telemetry.sh) ---\n'
./scripts/utilities/usms-emit-telemetry.sh science 0.63

printf -- '\n--- 5b. the event, for real: upload an object and let the bucket call the notifier ---\n'
SINCE_MS=$(python3 -c 'import time;print(int(time.time()*1000))')
printf '{"student":"stu-demo","faculty":"science","note":"Project Checkpoint 1 demonstration","at":"%s"}\n' "$(utc)" \
  | aws s3 cp - "s3://usms-student-data/${KEY}" --content-type application/json
LINE=""
for _ in $(seq 1 12); do
  # Filter on the marker and select the key client-side. A quoted '"checkpoint-01-demo"' pattern
  # matches nothing on Floci 2.2.0 (the unquoted form does), while AWS requires the quotes for a
  # term with hyphens - so neither pattern is portable, and contains() is.
  LINE=$(aws logs filter-log-events --log-group-name "$FN_LOG" --start-time "$SINCE_MS" \
           --filter-pattern USMS_NOTIFY --query 'events[?contains(message, `checkpoint-01-demo`)].message | [-1]' \
           --output text 2>/dev/null)
  [ -n "$LINE" ] && [ "$LINE" != "None" ] && break
  sleep 5
done
if [ -n "$LINE" ] && [ "$LINE" != "None" ]; then
  printf 'the notifier logged, within a minute of the upload:\n%s\n' "$LINE"
else
  echo "no USMS_NOTIFY line for ${KEY} within 60 s - the bucket-to-function link did not fire"
fi

printf -- '\n--- 6. logs: what it said ---\n'
aws logs filter-log-events --log-group-name /usms/central/application \
  --filter-pattern 'USMS_EVENT' --query 'events[-1].message' --output text

printf -- '\n--- 7. metrics: what it counted ---\n'
aws cloudwatch list-metrics --namespace USMS/Application \
  --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u

printf -- '\n--- 8. alarms: what would page somebody ---\n'
aws cloudwatch describe-alarms --alarm-name-prefix usms- \
  --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].[AlarmName,AlarmRule]' --output text
echo "(no composite above: Floci 2.2.0 has none; the rule is templates/lab-13-composite-alarm.json)"
./scripts/utilities/lab-13-composite-eval.sh | grep -E '^(rule|child|composite)'

printf -- '\n--- 9. the dashboard somebody would look at ---\n'
aws cloudwatch get-dashboard --dashboard-name usms-overview \
  --query 'DashboardBody' --output text \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["widgets"]), "widgets")'
