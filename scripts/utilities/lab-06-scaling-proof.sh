#!/usr/bin/env bash
# Lab 06 Step 12 part 5 - the control-plane proof of the alarm -> policy -> desiredCount
# wiring, link by link. Read-only. Every identifier is derived from the API.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"
STEP_POLICY=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query "ScalingPolicies[?PolicyType=='StepScaling'].PolicyName | [0]" --output text)
ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix usms-enrolment-queue \
  --query 'MetricAlarms[0].AlarmName' --output text)

echo "== 1. The alarm, and what it watches =="
aws cloudwatch describe-alarms --alarm-names "$ALARM" \
  --query 'MetricAlarms[0].[AlarmName,Namespace,MetricName,ComparisonOperator,Threshold,StateValue]' --output text
echo "== 2. What the alarm invokes =="
aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].AlarmActions[]' --output text \
  | sed 's#.*:policyName/#policyName/#'
echo "== 3. That ARN belongs to this policy, on this target =="
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --policy-names "$STEP_POLICY" --query 'ScalingPolicies[0].[PolicyName,ResourceId,ScalableDimension]' --output text
echo "== 4. The step a breach of 160 (260 against 100) selects =="
python3 - <<'PY'
import json
cfg = json.load(open('templates/lab-06-step-scaling-out.json'))
breach = 260 - 100
for s in cfg['StepAdjustments']:
    lo, hi = s.get('MetricIntervalLowerBound'), s.get('MetricIntervalUpperBound')
    if (lo is None or breach >= lo) and (hi is None or breach < hi):
        print(f"breach {breach} selects ScalingAdjustment {s['ScalingAdjustment']:+d}")
PY
echo "== 5. The bounds that clamp the result =="
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text
echo "== 6. The current desired count =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].desiredCount' --output text
