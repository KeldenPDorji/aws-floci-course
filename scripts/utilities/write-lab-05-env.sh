#!/usr/bin/env bash
# Generate configs/lab-05.env by LOOKUP (Lab 05 Step 18), never from shell variables,
# so a populated value in the file is evidence the resource actually exists.
#   ./scripts/utilities/write-lab-05-env.sh                         15 exports
#   ./scripts/utilities/write-lab-05-env.sh --with-resource-label   16 (Exercise 5)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Looked up OUT here, not inside the heredoc: in an unquoted heredoc the guide's \`80\`
# reaches JMESPath with the backslashes still on, the query fails, and the value is empty.
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)

# Floci accepts --health-check-grace-period-seconds and does not store it (Lab 05 README).
# Record the stored value when there is one; otherwise the value the service was created
# with, and say so in the file. verify-lab-05.sh still reads the API and still fails.
GRACE=$(aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].healthCheckGracePeriodSeconds' --output text)
GRACE_NOTE=""
if [ "$GRACE" = "None" ]; then
  GRACE=60
  GRACE_NOTE="# USMS_SVC_GRACE_PERIOD: requested 60 at create-service; Floci does not store it (describe-services returns null)."
fi

# Unquoted heredoc: every $(...) must run NOW and its result land in the file.
cat > configs/lab-05.env << EOF
# Lab 05 - ECS service behind an Application Load Balancer
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Sourced alongside lab-01/02/03/04. Lab 06 sources this
# file for the target group its ALBRequestCountPerTarget policy names.
$GRACE_NOTE

export USMS_ALB_NAME=usms-enrolment-alb
export USMS_ALB_ARN=$ALB_ARN
export USMS_ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
export USMS_ALB_SCHEME=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb \
  --query 'LoadBalancers[0].Scheme' --output text)
export USMS_ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_TG_NAME=usms-enrolment-tg
export USMS_TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
export USMS_TG_TARGET_TYPE=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].TargetType' --output text)
export USMS_TG_HEALTH_PATH=$(aws elbv2 describe-target-groups --names usms-enrolment-tg \
  --query 'TargetGroups[0].HealthCheckPath' --output text)

export USMS_ALB_LISTENER_ARN=$LISTENER_ARN

export USMS_ALB_LISTENER_PORT=80
export USMS_ALB_HEALTH_RULE_PATH=/alb-health

export USMS_SVC_LB_CONTAINER=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerName' --output text)
export USMS_SVC_LB_PORT=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].loadBalancers[0].containerPort' --output text)
export USMS_SVC_GRACE_PERIOD=$GRACE
EOF

if [ "${1:-}" = "--with-resource-label" ]; then
  # Exercise 5: derived by the script from the API, not typed.
  echo "export USMS_ALB_RESOURCE_LABEL=$("$REPO_ROOT/scripts/utilities/usms-resource-label.sh")" >> configs/lab-05.env
fi

echo "wrote configs/lab-05.env ($(grep -c '^export' configs/lab-05.env) exports)"
