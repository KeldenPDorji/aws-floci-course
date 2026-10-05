#!/usr/bin/env bash
# Block until a target group holds exactly N targets in a given state (or in any state).
# There is no aws waiter for "N targets": target-in-service returns as soon as every
# CURRENT target is healthy, which is immediately true before a new task has registered.
#   ./scripts/utilities/wait-targets.sh <target-group-arn> <count> [healthy|initial|draining|any] [timeout-seconds]
set -uo pipefail

TG="$1"; WANT="$2"; STATE="${3:-healthy}"; TIMEOUT="${4:-180}"

if [ "$STATE" = any ]; then
  Q='length(TargetHealthDescriptions)'
else
  Q="length(TargetHealthDescriptions[?TargetHealth.State=='$STATE'])"
fi

START=$SECONDS
while :; do
  N=$(aws elbv2 describe-target-health --target-group-arn "$TG" --query "$Q" --output text 2>/dev/null || echo 0)
  if [ "$N" = "$WANT" ]; then
    echo "ready: $N target(s) $STATE after $((SECONDS-START))s"
    exit 0
  fi
  if [ $((SECONDS-START)) -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s: $N target(s) $STATE, wanted $WANT"
    exit 1
  fi
  sleep 2
done
