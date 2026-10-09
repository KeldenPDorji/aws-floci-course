#!/usr/bin/env bash
# Block until the enrolment service's desiredCount satisfies a condition, then print the
# number of seconds it took. There is no aws waiter for "desiredCount reached N".
#   ./scripts/utilities/wait-desired.sh <eq|ge|ne> <n> [timeout-seconds]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"

OP="$1"; N="$2"; TIMEOUT="${3:-180}"
START=$SECONDS
while :; do
  D=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
        --query 'services[0].desiredCount' --output text 2>/dev/null || echo 0)
  if [ "$D" -"$OP" "$N" ] 2>/dev/null; then
    echo "desiredCount=$D ($OP $N) after $((SECONDS-START))s"
    exit 0
  fi
  if [ $((SECONDS-START)) -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s: desiredCount=$D, wanted $OP $N"
    exit 1
  fi
  sleep 2
done
