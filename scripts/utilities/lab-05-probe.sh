#!/usr/bin/env bash
# Lab 05 Step 3 - which parts of ELBv2 (and its ECS integration) this Floci build implements.
# Read-only. Classifies by the error TEXT, not the exit code: a ValidationError or a
# NotFound means the service answered; UnknownOperation / InvalidAction / a connection
# error means it did not (same fix as Lab 04's probe).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-02.env 2>/dev/null || true
source configs/lab-04.env 2>/dev/null || true

probe() {
  local out
  out=$(eval "$2" 2>&1)
  printf '%-40s ' "$1"
  if echo "$out" | grep -qE 'UnknownOperation|UnsupportedOperation|InvalidAction|Could not connect|invalid choice|not yet implemented'; then
    echo "not available"
  else
    echo "SUPPORTED"
  fi
}

echo "== Elastic Load Balancing v2 =="
probe "elbv2 describe-load-balancers"         "aws elbv2 describe-load-balancers"
probe "elbv2 describe-target-groups"          "aws elbv2 describe-target-groups"
probe "elbv2 describe-listeners (bad arn)"    "aws elbv2 describe-listeners --load-balancer-arn probe"
probe "elbv2 describe-account-limits"         "aws elbv2 describe-account-limits"
probe "elbv2 create-load-balancer (skeleton)" "aws elbv2 create-load-balancer --generate-cli-skeleton"
echo "== ECS integration =="
probe "ecs describe-services"                 "aws ecs describe-services --cluster ${USMS_ECS_CLUSTER:-x} --services ${USMS_ENROLMENT_SERVICE:-x}"
probe "application-autoscaling (Lab 06)"      "aws application-autoscaling describe-scalable-targets --service-namespace ecs"
echo "== Already used in Labs 1 to 4 =="
probe "ec2 describe-security-group-rules"     "aws ec2 describe-security-group-rules --max-items 1"
probe "ec2 describe-subnets"                  "aws ec2 describe-subnets --subnet-ids ${USMS_PUBLIC_SUBNET_A:-x}"
