#!/usr/bin/env bash
# Lab 12 Exercise 3 - replace the two listener placeholders in
# templates/lab-12-codedeploy-deployment-group.json with the real ARNs, BY LOOKUP, then
# validate the document three ways. Creates nothing.
#   1. JSON parses, and no angle-bracket placeholder is left
#   2. every target group and listener it names exists, on usms-enrolment-alb
#   3. the AWS CLI's own CodeDeploy request model accepts it: the request is sent to an
#      UNREACHABLE endpoint, so a valid document fails only at connection time and an
#      invalid one fails earlier with "Parameter validation failed"
#   ./scripts/utilities/lab-12-fill-deployment-group.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

DOC=templates/lab-12-codedeploy-deployment-group.json
ALB=$(aws elbv2 describe-load-balancers --names usms-enrolment-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
PROD=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB" --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
TEST=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB" --query 'Listeners[?Port==`8080`].ListenerArn | [0]' --output text)
for v in "$PROD" "$TEST"; do case "$v" in arn:*) ;; *) echo "STOP - a listener is missing (got '$v')" >&2; exit 1 ;; esac; done

python3 - "$DOC" "$PROD" "$TEST" << 'PY'
import json, sys
doc, prod, test = sys.argv[1:]
d = json.load(open(doc))
pair = d["loadBalancerInfo"]["targetGroupPairInfoList"][0]
pair["prodTrafficRoute"]["listenerArns"] = [prod]
pair["testTrafficRoute"]["listenerArns"] = [test]
json.dump(d, open(doc, "w"), indent=2)
open(doc, "a").write("\n")
PY

echo "1. $(python3 -m json.tool "$DOC" >/dev/null && echo 'valid JSON'), placeholders left: $(grep -c '<' "$DOC")"
echo "2. resources named in the document:"
for TG in $(python3 -c "import json;print(' '.join(t['name'] for t in json.load(open('$DOC'))['loadBalancerInfo']['targetGroupPairInfoList'][0]['targetGroups']))"); do
  printf '     target group %-24s %s\n' "$TG" "$(aws elbv2 describe-target-groups --names "$TG" --query 'TargetGroups[0].LoadBalancerArns[0]' --output text 2>&1 | grep -q usms-enrolment-alb && echo 'exists, on usms-enrolment-alb' || echo 'exists, NOT attached to the ALB')"
done
printf '     prod listener  port %s\n     test listener  port %s\n' \
  "$(aws elbv2 describe-listeners --listener-arns "$PROD" --query 'Listeners[0].Port' --output text)" \
  "$(aws elbv2 describe-listeners --listener-arns "$TEST" --query 'Listeners[0].Port' --output text)"
OUT=$(aws deploy create-deployment-group --cli-input-json "file://$DOC" \
        --endpoint-url http://127.0.0.1:9 --cli-connect-timeout 2 2>&1)
case "$OUT" in
  *"Parameter validation failed"*) echo "3. CLI request model: REJECTED"; echo "$OUT" | head -5; exit 1 ;;
  *"Could not connect"*)           echo "3. CLI request model: accepted (failed only at connection, as intended)" ;;
  *)                               echo "3. CLI request model: unexpected result:"; echo "$OUT" | head -3 ;;
esac
