#!/usr/bin/env bash
# Lab 06 Step 3 - which parts of Application Auto Scaling and CloudWatch this Floci build
# implements. Read-only. Classifies by the error TEXT, not the exit code (same fix as Labs
# 04 and 05): an empty list or a NotFound means the service answered.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env 2>/dev/null || true
source configs/lab-05.env 2>/dev/null || true

probe() {
  local out
  out=$(eval "$2" 2>&1)
  printf '%-44s ' "$1"
  if echo "$out" | grep -qE 'UnknownOperation|UnsupportedOperation|not supported|InvalidAction|Could not connect|invalid choice'; then
    echo "not available"
  else
    echo "SUPPORTED"
  fi
}

printf 'floci version: '
curl -s http://localhost:4566/_floci/health | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","unknown"))'

echo "== Application Auto Scaling =="
probe "describe-scalable-targets"      "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
probe "describe-scaling-policies"      "aws application-autoscaling describe-scaling-policies --service-namespace ecs"
probe "describe-scheduled-actions"     "aws application-autoscaling describe-scheduled-actions --service-namespace ecs"
probe "describe-scaling-activities"    "aws application-autoscaling describe-scaling-activities --service-namespace ecs"
echo "== CloudWatch =="
probe "describe-alarms"                "aws cloudwatch describe-alarms --max-items 1"
probe "list-metrics"                   "aws cloudwatch list-metrics --max-items 1"
probe "describe-alarm-history"         "aws cloudwatch describe-alarm-history --max-items 1"
echo "== IAM, ECS, ELBv2 =="
probe "iam list-roles"                 "aws iam list-roles --max-items 1"
probe "ecs describe-services"          "aws ecs describe-services --cluster ${USMS_ECS_CLUSTER:-x} --services ${USMS_ENROLMENT_SERVICE:-x}"
probe "elbv2 describe-target-groups"   "aws elbv2 describe-target-groups --names ${USMS_TG_NAME:-x}"
