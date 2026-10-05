#!/usr/bin/env bash
# Lab 05 Exercise 5 - build the ALBRequestCountPerTarget ResourceLabel FROM THE API.
#   ./scripts/utilities/usms-resource-label.sh [load-balancer-name] [target-group-name]
# Prints:  app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
# Reads no env file for the ARNs: deriving them is the point. Exit 1 if the result is implausible.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)

# The two suffixes need different treatment, as PredefinedMetricSpecification specifies:
#   ...:loadbalancer/app/<name>/<id>   -> the label wants what comes AFTER "loadbalancer/"
#   ...:targetgroup/<name>/<id>        -> the label KEEPS "targetgroup/"
# So the LB suffix strips through ":loadbalancer/" (shortest-prefix #), while the TG
# suffix strips only through the last ":" (longest-prefix ##), leaving the resource type in.
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"
TG_SUFFIX="${TG_ARN##*:}"
LABEL="$LB_SUFFIX/$TG_SUFFIX"

IFS=/ read -r -a SEG <<< "$LABEL"
if [ "${#SEG[@]}" -ne 6 ] || [ "${SEG[0]}" != app ] || [ "${SEG[1]}" != "$LB_NAME" ] \
   || [ "${SEG[3]}" != targetgroup ] || [ "${SEG[4]}" != "$TG_NAME" ]; then
  echo "implausible ResourceLabel '$LABEL' (lb='$LB_ARN' tg='$TG_ARN')" >&2
  exit 1
fi

echo "$LABEL"
