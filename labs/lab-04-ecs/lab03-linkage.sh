#!/usr/bin/env bash
# Lab 04 Exercise 5 - resolve usms-enrolment-sg's inbound source group back to the
# instance(s) that carry it, compare with Lab 03's usms-web-01, audit the ECS tags,
# and write it all to outputs/lab-04-lab03-linkage.txt for Lab 05's cutover step.
#
# No -e: a lookup that comes back empty is a finding to record, not a reason to stop.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-03.env
source configs/lab-04.env

OUT=outputs/lab-04-lab03-linkage.txt

# 1. The source group, as the API stores it - and as the rule was written.
api_source=$(aws ec2 describe-security-groups --group-ids "$USMS_ENROLMENT_SG" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)
doc_source=$(jq -r '.[0].UserIdGroupPairs[0].GroupId' policies/usms-enrolment-sg-ingress.json)
if [ "$api_source" != "None" ] && [ -n "$api_source" ]; then
  source_group=$api_source; source_from="the live rule (describe-security-groups)"
else
  source_group=$doc_source
  source_from="policies/usms-enrolment-sg-ingress.json - the live rule stores no group reference on this Floci build (see Lab 02 report, Section 7)"
fi

# 2. Reverse lookup: which running instances carry that group? Server-side filter first,
#    then the same question answered client-side, because Lab 02 found Floci ignores
#    some EC2 filters. Both answers are recorded.
filtered=$(aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=$source_group" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')
carriers=$(aws ec2 describe-instances --output json | jq -r --arg g "$source_group" '
  [.Reservations[].Instances[]
   | select(.State.Name == "running")
   | select(any(.SecurityGroups[]?; .GroupId == $g))
   | "\(.InstanceId) (\((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // "unnamed"))"]
  | join(", ")')

if grep -q "$USMS_WEB_INSTANCE" <<<"$carriers"; then
  extra=$(sed "s/$USMS_WEB_INSTANCE ([^)]*)//; s/^, //; s/, $//; s/, ,/,/" <<<"$carriers")
  verdict="LOOP CLOSED"
  [ -n "$extra" ] && verdict="LOOP CLOSED - usms-web-01 carries the group; also carried by: $extra"
else
  verdict="MISMATCH - $USMS_WEB_INSTANCE does not carry $source_group"
fi

# 4. Tag audit on the two ECS ARNs (list-tags-for-resource takes an ARN, not a name).
tags_of() { aws ecs list-tags-for-resource --resource-arn "$1" \
              --query 'tags[].[key,value]' --output text 2>&1 | tr '\t\n' '= ' ; }

{
  echo "# Lab 04 -> Lab 05 linkage: usms-enrolment-sg's caller"
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "enrolment sg        : $USMS_ENROLMENT_SG"
  echo "source group        : $source_group"
  echo "  resolved from     : $source_from"
  echo "carriers (filter)   : ${filtered:-<none>}"
  echo "carriers (verified) : ${carriers:-<none>}"
  echo "lab-03 web instance : $USMS_WEB_INSTANCE"
  echo "verdict             : $verdict"
  echo
  echo "This rule is temporary: Lab 05 removes it once the load balancer becomes the"
  echo "only caller of the enrolment service."
  echo
  echo "== ECS tag audit (Project=USMS expected) =="
  echo "cluster $USMS_ECS_CLUSTER_ARN"
  echo "  tags: $(tags_of "$USMS_ECS_CLUSTER_ARN")"
  echo "service $USMS_ENROLMENT_SERVICE_ARN"
  echo "  tags: $(tags_of "$USMS_ENROLMENT_SERVICE_ARN")"
} > "$OUT"

cat "$OUT"
