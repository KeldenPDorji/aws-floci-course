#!/usr/bin/env bash
# Lab 05 Step 16 - the facts compared across a Floci restart. Every ARN is RE-DERIVED from
# the API (by name, or by walking down from the load balancer), never reused from the shell.
# runningCount and target health are deliberately absent: they are allowed to move.
#   ./scripts/utilities/lab-05-restart-facts.sh > outputs/lab-05-pre-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-04.env

ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
ALB_SG=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=usms-alb-sg" --query 'SecurityGroups[0].GroupId' --output text)

echo "alb      ${ALB_ARN##*:loadbalancer/}"
echo "tg       ${TG_ARN##*:}"
echo "listener ${LISTENER_ARN##*/}"
echo "alb-sg   $ALB_SG"
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].[LoadBalancerName,Scheme,Type,State.Code,length(AvailabilityZones),length(SecurityGroups)]' --output text
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,Matcher.HttpCode,HealthCheckIntervalSeconds,UnhealthyThresholdCount]' --output text
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'sort_by(Listeners,&Port)[].[Port,Protocol,DefaultActions[0].Type]' --output text
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query 'sort_by(Rules,&Priority)[].[Priority,Actions[0].Type]' --output text
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[serviceName,status,desiredCount,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
aws ec2 describe-security-groups --group-ids "$ALB_SG" \
  --query 'SecurityGroups[0].[GroupName,join(`,`,sort(IpPermissions[].to_string(FromPort)))]' --output text
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query 'sort(SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId)' --output text | sed 's/^/usms-enrolment-sg ingress /'
