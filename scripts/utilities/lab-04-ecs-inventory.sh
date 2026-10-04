#!/usr/bin/env bash
# Lab 04 Exercise 3 - one drift line per service in usms-ecs-cluster, plus the same
# data as JSON in outputs/lab-04-ecs-inventory.json.
# Every verdict is computed from the service and its task definition - never from a
# name or a tag.
#
# -e is deliberately OFF. One service whose task definition cannot be described, or
# which has no networkConfiguration (an EC2 launch type service), must produce an
# explicit N/A on its own line - not abort the inventory and silently omit every
# service after it. The two calls the report cannot work without are checked explicitly.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
OUT="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"

die() { echo "lab-04-ecs-inventory: $*" >&2; exit 1; }

arns=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text) \
  || die "list-services failed for $CLUSTER"
[ -n "$arns" ] && [ "$arns" != "None" ] || die "no services in $CLUSTER"

# describe-services takes at most 10 names per call; a course cluster never gets near that.
# shellcheck disable=SC2086
services=$(aws ecs describe-services --cluster "$CLUSTER" --services $arns --output json) \
  || die "describe-services failed"

rows="[]"
while read -r s; do
  name=$(jq -r '.serviceName' <<<"$s")
  desired=$(jq -r '.desiredCount // "N/A"' <<<"$s")
  running=$(jq -r '.runningCount // "N/A"' <<<"$s")
  td_arn=$(jq -r '.taskDefinition // ""' <<<"$s")
  public=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "N/A"' <<<"$s")

  taskdef="N/A"; roles="N/A"
  if [ -n "$td_arn" ]; then
    taskdef=${td_arn##*/}
    td=$(aws ecs describe-task-definition --task-definition "$td_arn" \
           --query 'taskDefinition.{e:executionRoleArn,t:taskRoleArn}' --output json 2>/dev/null)
    if [ -n "$td" ]; then
      exec_role=$(jq -r '.e // ""' <<<"$td"); task_role=$(jq -r '.t // ""' <<<"$td")
      if [ -z "$exec_role" ] || [ -z "$task_role" ]; then roles="INCOMPLETE"
      elif [ "$exec_role" = "$task_role" ]; then roles="SAME"
      else roles="SEPARATE"; fi
    fi
  fi

  case "$public" in
    ENABLED)  publicip=RISK ;;
    DISABLED) publicip=OK ;;
    *)        publicip=N/A ;;
  esac

  printf '%-22s desired=%-3s running=%-3s taskdef=%-18s roles=%-10s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef" "$roles" "$publicip"

  rows=$(jq -c --arg n "$name" --arg d "$desired" --arg r "$running" --arg t "$taskdef" \
           --arg ro "$roles" --arg p "$publicip" \
           '. + [{service:$n, desired:$d, running:$r, taskdef:$t, roles:$ro, publicip:$p}]' <<<"$rows")
done < <(jq -c '.services | sort_by(.serviceName) | .[]' <<<"$services")

jq --arg c "$CLUSTER" '{cluster:$c, services:.}' <<<"$rows" > "$OUT"
