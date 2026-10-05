#!/usr/bin/env bash
# Lab 05 Exercise 5 points 3 and 4 - write outputs/lab-05-lab04c-readiness.txt for Lab 06,
# and measure how long a full replacement of capacity takes in THIS environment.
#   ./labs/lab-05-ecs-alb/lab06-readiness.sh
# The measurement forces a new deployment of usms-enrolment-svc (same revision).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env

OUT=outputs/lab-05-lab04c-readiness.txt
TIMEOUT=90
now() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
epoch() { python3 -c 'import time; print(int(time.time()))'; }
tasks() { aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER" --service-name "$USMS_ENROLMENT_SERVICE" \
            --query 'sort(taskArns)' --output text; }

LABEL=$(scripts/utilities/usms-resource-label.sh) || exit 1
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
LB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
DESIRED=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" --query 'services[0].desiredCount' --output text)

# Point 4: timestamp, force a deployment, poll until the task set has been replaced and the
# target list is back to DESIRED healthy targets (one deployment can't be read: it is null here).
BEFORE=$(tasks); T0=$(epoch); START=$(now)
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --force-new-deployment >/dev/null
VERDICT="no replacement observed within ${TIMEOUT}s"
while [ $(( $(epoch) - T0 )) -lt "$TIMEOUT" ]; do
  NOWT=$(tasks)
  H=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  T=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'length(TargetHealthDescriptions)' --output text)
  if [ "$NOWT" != "$BEFORE" ] && [ "$H" = "$DESIRED" ] && [ "$T" = "$DESIRED" ]; then
    VERDICT="replaced"; break
  fi
  python3 -c 'import time; time.sleep(3)'
done
END=$(now); ELAPSED=$(( $(epoch) - T0 ))

{
  echo "resource_label        $LABEL"
  echo "target_group_arn      $TG_ARN"
  echo "load_balancer_arn     $LB_ARN"
  echo "scalable_resource_id  service/$USMS_ECS_CLUSTER/$USMS_ENROLMENT_SERVICE"
  echo "scalable_dimension    ecs:service:DesiredCount"
  echo "desired_count         $DESIRED"
  echo "recommended_metric    ALBRequestCountPerTarget - enrolment load arrives as requests, and requests per target is the demand signal itself rather than CPU, a lagging side effect of it"
  echo "replacement_start     $START"
  echo "replacement_end       $END"
  echo "replacement_seconds   $ELAPSED  ($VERDICT)"
} > "$OUT"

cat "$OUT"
