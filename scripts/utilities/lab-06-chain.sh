#!/usr/bin/env bash
# Lab 06 Step 15 - from one request to one new task: the seven blocks, every identifier
# derived. Read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env
source configs/lab-05.env

SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"
svc() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
          --query "services[0].$1" --output text; }

echo "== 1. The metrics that would start it =="
aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$RID" \
  --query 'MetricAlarms[?contains(AlarmName, `AlarmHigh`)].[Namespace,MetricName,Threshold,ComparisonOperator]' --output text
aws cloudwatch describe-alarms --alarm-name-prefix usms-enrolment-queue \
  --query 'MetricAlarms[].[Namespace,MetricName,Threshold,ComparisonOperator]' --output text
echo "== 2. The policies those alarms invoke =="
aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$RID" \
  --query 'ScalingPolicies[].[PolicyName,PolicyType]' --output text
echo "== 3. The one integer they write, and its bounds =="
aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
  --query 'ScalableTargets[0].[ResourceId,ScalableDimension,MinCapacity,MaxCapacity]' --output text
echo "== 4. The service that reads it, and how long a new task takes to count =="
svc '[serviceName,desiredCount,runningCount,taskDefinition,healthCheckGracePeriodSeconds]'
echo "== 5. Where a new task appears =="
svc 'networkConfiguration.awsvpcConfiguration.[join(`,`,subnets),join(`,`,securityGroups),assignPublicIp]'
echo "== 6. Who registers it as a target, and where =="
svc 'loadBalancers[0].[containerName,containerPort,targetGroupArn]'
aws elbv2 describe-target-health --target-group-arn "$USMS_TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
echo "== 7. What this lab changed about any of that =="
svc '[taskDefinition,length(loadBalancers),length(deployments)]'
