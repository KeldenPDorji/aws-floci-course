#!/usr/bin/env bash
# Lab 05 Step 12 - prove the path client -> listener -> target group -> tasks, link by link,
# from the control plane, then try the data path from three places:
#   the host (public DNS - expected to fail on Floci),
#   inside the Floci container (where its ELBv2 data plane binds the listener port),
#   usms-web-01 (the portal, on the same Docker network) - the real client in the story.
# Read-only. Writes nothing; pipe to tee for evidence.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env

# Derived by name, never from the shell that created them.
ALB_ARN=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].DNSName' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names usms-enrolment-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB_SG=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=usms-alb-sg" --query 'SecurityGroups[0].GroupId' --output text)

echo "== 1. listener a client connects to =="
aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].[Protocol,Port,DefaultActions[0].Type,DefaultActions[0].TargetGroupArn]' --output text | sed 's#arn:.*:targetgroup/#tg/#'

echo "== 2. target group it forwards to =="
aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].[TargetGroupName,TargetType,Protocol,Port,HealthCheckPath,VpcId]' --output text

echo "== 3. targets in it, and where each address lives =="
for ip in $(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[].Target.Id' --output text); do
  st=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query "TargetHealthDescriptions[?Target.Id=='$ip'].TargetHealth.State | [0]" --output text)
  case "$ip" in
    10.0.3.*) where="usms-private-subnet-a (us-east-1a)" ;;
    10.0.4.*) where="usms-private-subnet-b (us-east-1b)" ;;
    172.*)    where="Floci Docker network - on AWS an ENI address in 10.0.3.0/24 or 10.0.4.0/24" ;;
    *)        where="NOT in a Lab 02 private subnet - investigate" ;;
  esac
  printf '  %-12s %-9s %s\n' "$ip" "$st" "$where"
done

echo "== 4. the service that put them there =="
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].[serviceName,loadBalancers[0].containerName,loadBalancers[0].containerPort,healthCheckGracePeriodSeconds]' --output text
aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
  --query 'services[0].loadBalancers[0].targetGroupArn' --output text | sed 's#arn:.*:targetgroup/#  names tg/#'

echo "== 5. the firewall between 1 and 3 =="
echo "  usms-alb-sg = $ALB_SG"
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$USMS_ENROLMENT_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false`].[SecurityGroupRuleId,IpProtocol,FromPort,ReferencedGroupInfo.GroupId]' --output text | sed 's/^/  /'

echo "== 6. data path =="
printf '  %-34s ' "host -> http://$ALB_DNS/"
python3 -c 'import socket,sys; socket.gethostbyname(sys.argv[1]); print("resolves")' "$ALB_DNS" 2>/dev/null || echo "does not resolve (no public DNS on Floci)"

printf '  %-34s ' "floci -> http://localhost:80/"
docker exec floci sh -c "curl -s -i --max-time 5 http://localhost:80/ | grep -iE '^HTTP/|^server:' | tr -d '\r' | tr '\n' ' '" 2>/dev/null; echo

WEB=$(docker ps --filter "name=$USMS_WEB_INSTANCE" --format '{{.Names}}' | head -1)
printf '  %-34s ' "usms-web-01 -> http://floci:80/"
if [ -n "$WEB" ]; then
  docker exec "$WEB" sh -c "curl -s -i --max-time 5 http://floci:80/ | grep -iE '^HTTP/|^server:' | tr -d '\r' | tr '\n' ' '"; echo
else
  echo "usms-web-01 container not running - skipped"
fi
