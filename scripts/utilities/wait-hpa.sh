#!/usr/bin/env bash
# Block until usms-enrolment-hpa reaches a state, then print how long it took.
# Replaces the guide's `sleep 30` (Step 8) and the open-ended "watch it" of Step 9.
#   ./scripts/utilities/wait-hpa.sh metrics   [timeout]   the HPA has computed a CPU percentage
#   ./scripts/utilities/wait-hpa.sh ge <n>    [timeout]   currentReplicas >= n and that many ready
#   ./scripts/utilities/wait-hpa.sh le <n>    [timeout]   currentReplicas <= n and that many ready
set -uo pipefail

NS=usms
MODE="$1"
if [ "$MODE" = metrics ]; then N=0; TIMEOUT="${2:-120}"; else N="$2"; TIMEOUT="${3:-600}"; fi

START=$SECONDS
while :; do
  CPU=$(kubectl get hpa usms-enrolment-hpa -n "$NS" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  CUR=$(kubectl get hpa usms-enrolment-hpa -n "$NS" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)
  RDY=$(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  CUR=${CUR:-0}; RDY=${RDY:-0}
  case "$MODE" in
    metrics) [ -n "$CPU" ] && OK=1 || OK=0 ;;
    ge)      [ "$CUR" -ge "$N" ] && [ "$RDY" -ge "$N" ] && OK=1 || OK=0 ;;
    le)      [ "$CUR" -le "$N" ] && [ "$RDY" -le "$N" ] && OK=1 || OK=0 ;;
    *)       echo "usage: $0 metrics|ge <n>|le <n> [timeout]"; exit 2 ;;
  esac
  if [ "$OK" = 1 ]; then
    echo "usms-enrolment-hpa: cpu ${CPU:-unknown}%  replicas $CUR  ready $RDY  after $((SECONDS-START))s"
    exit 0
  fi
  if [ $((SECONDS-START)) -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${TIMEOUT}s: cpu ${CPU:-unknown}%  replicas $CUR  ready $RDY"; exit 1
  fi
  sleep 3
done
