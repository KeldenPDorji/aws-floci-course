#!/usr/bin/env bash
# Block until ANY pod matching a selector (or a named pod) reaches a state, then print it.
# Replaces the guide's `sleep 20` in Step 19. `kubectl wait -l` is unsuitable there: it
# waits on EVERY matching pod, including the healthy old ones that never reach the state.
#   ./scripts/utilities/wait-pod-state.sh <namespace> <-l selector | pod-name> <state> [timeout]
# <state> is a waiting reason (ImagePullBackOff, CrashLoopBackOff, ...) or a phase (Pending, Running).
set -uo pipefail

NS="$1"; shift
if [ "$1" = "-l" ]; then TARGET=(-l "$2"); shift 2; else TARGET=("$1"); shift; fi
STATE="$1"; TIMEOUT="${2:-120}"

START=$SECONDS
while :; do
  ROWS=$(kubectl get pod "${TARGET[@]}" -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null)
  [ -z "$ROWS" ] && ROWS=$(kubectl get pod "${TARGET[@]}" -n "$NS" -o jsonpath='{.metadata.name} {.status.phase} {.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  HIT=$(echo "$ROWS" | awk -v s="$STATE" '$2==s || $3==s {print $1; exit}')
  if [ -n "$HIT" ]; then
    echo "$HIT reached $STATE after $((SECONDS-START))s"
    exit 0
  fi
  if [ $((SECONDS-START)) -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s waiting for $STATE"; echo "$ROWS"; exit 1
  fi
  sleep 2
done
