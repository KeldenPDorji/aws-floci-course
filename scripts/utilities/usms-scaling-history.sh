#!/usr/bin/env bash
# Lab 06 Exercise 5 point 1-2 - export the enrolment service's complete scaling configuration
# and history as ONE JSON document: outputs/lab-06-scaling-history.json.
# Every identifier is discovered; nothing is typed. Works from any directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env

OUT=outputs/lab-06-scaling-history.json
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --output json > "$TMP/targets.json"
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --output json > "$TMP/policies.json"
aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$RID" \
  --output json > "$TMP/scheduled.json" 2> "$TMP/scheduled.err" || true
aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$RID" \
  --include-not-scaled-activities --output json > "$TMP/activities.json"
# Every alarm involved: the ones the policies name, PLUS any alarm whose AlarmActions name a
# policy ARN (Floci 2.2.0 lists no alarms on a step policy; asking from the alarm's side
# finds usms-enrolment-queue-high on both Floci and real AWS). One batched call at the end.
aws cloudwatch describe-alarms --query 'MetricAlarms[].{n:AlarmName,a:AlarmActions}' --output json > "$TMP/all.json"
NAMES=($( { jq -r '.ScalingPolicies[].Alarms[]?.AlarmName' "$TMP/policies.json";
            jq -r --slurpfile p "$TMP/policies.json" \
              '.[] | select(any(.a[]?; . as $x | ($p[0].ScalingPolicies | map(.PolicyARN) | index($x)))) | .n' \
              "$TMP/all.json"; } | sort -u))
if [ "${#NAMES[@]}" -gt 0 ]; then
  aws cloudwatch describe-alarms --alarm-names "${NAMES[@]}" --output json > "$TMP/alarms.json"
else
  echo '{"MetricAlarms":[]}' > "$TMP/alarms.json"
fi

python3 - "$TMP" "$RID" "$OUT" <<'PY'
import datetime, json, os, sys
tmp, rid, out = sys.argv[1:4]
L = lambda n: json.load(open(os.path.join(tmp, n)))
sched_err = open(os.path.join(tmp, "scheduled.err")).read().strip()
doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": rid,
    "scalableTargets": L("targets.json")["ScalableTargets"],
    "scalingPolicies": L("policies.json")["ScalingPolicies"],
    "scheduledActions": ({"unavailable": sched_err.splitlines()[-1] if sched_err else "error"}
                         if sched_err else L("scheduled.json")["ScheduledActions"]),
    "alarms": L("alarms.json")["MetricAlarms"],
    "scalingActivities": L("activities.json")["ScalingActivities"],
}
json.dump(doc, open(out, "w"), indent=2, default=str)
PY

python3 -m json.tool "$OUT" >/dev/null && echo "valid JSON: $OUT  $(wc -c < "$OUT" | tr -d ' ') bytes"
python3 -c "import json;d=json.load(open('$OUT'));print('targets',len(d['scalableTargets']),'policies',len(d['scalingPolicies']),'alarms',len(d['alarms']),'activities',len(d['scalingActivities']))"
