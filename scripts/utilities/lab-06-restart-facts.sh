#!/usr/bin/env bash
# Lab 06 Step 14 - the configuration facts compared across a Floci restart. Every identifier
# is RE-DERIVED from the API: the resource ID from the ECS service's ARN, the dimension by
# filtering on it, the policies by TYPE and name fragment, the alarm by prefix.
# Alarm state, running counts and the activity log are deliberately absent: they may move.
# Scheduled actions are absent because this build does not implement them (Step 11).
#   ./scripts/utilities/lab-06-restart-facts.sh > outputs/lab-06-pre-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

SVC_ARN=$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"
SDIM=$(aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query "ScalableTargets[?ResourceId=='$RID'].ScalableDimension | [0]" --output text)
CPU_POLICY=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query "ScalingPolicies[?contains(PolicyName, 'cpu-target-tracking')].PolicyName | [0]" --output text)
STEP_POLICY=$(aws application-autoscaling describe-scaling-policies --service-namespace ecs \
  --query "ScalingPolicies[?PolicyType=='StepScaling'].PolicyName | [0]" --output text)
QUEUE_ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix usms-enrolment-queue \
  --query 'MetricAlarms[0].AlarmName' --output text)

echo "re-derived  $RID  $SDIM  $CPU_POLICY  $STEP_POLICY  $QUEUE_ALARM"
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[ServiceNamespace,ResourceId,ScalableDimension,MinCapacity,MaxCapacity]' --output text
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].SuspendedState.*' --output text
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'sort_by(ScalingPolicies,&PolicyName)[].[PolicyName,PolicyType]' --output text
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --policy-names "$CPU_POLICY" \
  --query 'ScalingPolicies[0].TargetTrackingScalingPolicyConfiguration.[TargetValue,ScaleOutCooldown,ScaleInCooldown,DisableScaleIn,PredefinedMetricSpecification.PredefinedMetricType]' --output text
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --policy-names "$STEP_POLICY" \
  --query 'ScalingPolicies[0].StepScalingPolicyConfiguration.[AdjustmentType,MetricAggregationType,Cooldown,length(StepAdjustments)]' --output text
aws cloudwatch describe-alarms --alarm-names "$QUEUE_ALARM" \
  --query 'MetricAlarms[0].[AlarmName,Namespace,MetricName,Threshold,ComparisonOperator,EvaluationPeriods,TreatMissingData,length(AlarmActions)]' --output text
echo "managed alarms: $(aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RID" --query 'length(MetricAlarms)' --output text)"
