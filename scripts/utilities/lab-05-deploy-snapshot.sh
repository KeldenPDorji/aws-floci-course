#!/usr/bin/env bash
# Lab 05 Step 14 - one snapshot of the service before or after a forced deployment:
# timestamp, revision, desired/running, sorted target addresses, sorted task IDs.
#   ./scripts/utilities/lab-05-deploy-snapshot.sh > outputs/lab-05-pre-deploy.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env

TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)

date -u +%Y-%m-%dT%H:%M:%SZ
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[taskDefinition,desiredCount,runningCount]' --output text
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'sort(TargetHealthDescriptions[].Target.Id)' --output text | tr '\t' ' '
aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER" --service-name "$USMS_ENROLMENT_SERVICE" \
  --query 'sort(taskArns)' --output text | tr '\t' '\n' | sed 's#.*/#task #'
