#!/usr/bin/env bash
# Generate configs/lab-06.env by LOOKUP (Lab 06 Step 16), never from shell variables,
# so a populated value in the file is evidence the resource actually exists.
#   ./scripts/utilities/write-lab-06-env.sh                    22 exports
#   ./scripts/utilities/write-lab-06-env.sh --with-exercise5   24 (history file + latency)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

SVC_ARN=$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
RID="${SVC_ARN##*:}"

# A policy ARN, or the word not-created: an unsupported feature is not the same as a skipped step.
policy_arn() {
  aws application-autoscaling describe-scaling-policies --service-namespace ecs \
    --resource-id "$RID" --policy-names "$1" \
    --query 'ScalingPolicies[0].PolicyARN' --output text 2>/dev/null | grep -E '^arn:' || echo not-created
}
bound() {
  aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" \
    --query "ScalableTargets[0].$1" --output text
}

# Unquoted heredoc: every $(...) runs NOW and its result lands in the file.
cat > configs/lab-06.env << EOF
# Lab 06 - ECS service auto scaling outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs, ARNs and numbers only. NO SECRETS. Safe to commit.
#
# Sourced alongside lab-01/02/03/04/05. The CloudWatch lab reads the alarm and the
# custom metric; the CloudFormation lab re-declares every object named here.
# The two USMS_SCHEDULED_* names are the actions Step 11 specifies. Floci 2.2.0 answers
# PutScheduledAction with UnsupportedOperation, so on this build they do not exist.

export USMS_SCALABLE_NAMESPACE=ecs
export USMS_SCALABLE_RESOURCE_ID=$RID
export USMS_SCALABLE_DIMENSION=$(bound ScalableDimension)
export USMS_SCALE_MIN=$(bound MinCapacity)
export USMS_SCALE_MAX=$(bound MaxCapacity)

export USMS_POLICY_CPU_TT=usms-enrolment-cpu-target-tracking
export USMS_POLICY_CPU_TT_ARN=$(policy_arn usms-enrolment-cpu-target-tracking)
export USMS_SCALE_TARGET_CPU=50
export USMS_POLICY_REQ_TT=usms-enrolment-requests-target-tracking
export USMS_POLICY_REQ_TT_ARN=$(policy_arn usms-enrolment-requests-target-tracking)
export USMS_SCALE_TARGET_REQUESTS=1000
export USMS_POLICY_STEP_OUT=usms-enrolment-queue-step-out
export USMS_POLICY_STEP_OUT_ARN=$(policy_arn usms-enrolment-queue-step-out)

export USMS_SCALE_OUT_COOLDOWN=60
export USMS_SCALE_IN_COOLDOWN=300

export USMS_ALARM_QUEUE_HIGH=$(aws cloudwatch describe-alarms --alarm-names usms-enrolment-queue-high \
  --query 'MetricAlarms[0].AlarmName' --output text)
export USMS_METRIC_NAMESPACE=USMS/Enrolment
export USMS_METRIC_NAME=EnrolmentQueueDepth
export USMS_METRIC_DIMENSION=Service=enrolment

export USMS_SCHEDULED_OUT=usms-enrolment-morning-scale-out
export USMS_SCHEDULED_IN=usms-enrolment-evening-scale-in

export USMS_ASA_SLR=AWSServiceRoleForApplicationAutoScaling_ECSService
EOF

if [ "${1:-}" = "--with-exercise5" ]; then
  # Both derived: the file must exist, and the latency comes from the measurement file.
  test -s outputs/lab-06-scaling-history.json
  LAT=$(awk '$1=="elapsed_seconds"{print $2}' outputs/lab-06-scale-latency.txt)
  {
    echo "export USMS_SCALING_HISTORY_FILE=outputs/lab-06-scaling-history.json"
    echo "export USMS_SCALE_LATENCY_SECONDS=${LAT}"
  } >> configs/lab-06.env
fi

echo "wrote configs/lab-06.env ($(grep -c '^export' configs/lab-06.env) exports)"
