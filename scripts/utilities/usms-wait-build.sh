#!/usr/bin/env bash
# Block until a CodeBuild build reaches a terminal status, then print one summary line.
# Replaces the guide's `sleep 10` polling loops (Steps 12 and 20) with a deterministic wait.
#   ./scripts/utilities/usms-wait-build.sh <build-id> [timeout-seconds]
# Exit 0 if SUCCEEDED, 1 for any other terminal status, 2 on timeout.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"

ID="${1:-}"; TIMEOUT="${2:-600}"
[ -n "$ID" ] || { echo "usage: $0 <build-id> [timeout-seconds]" >&2; exit 2; }

START=$SECONDS
while :; do
  read -r STATUS PHASE < <(aws codebuild batch-get-builds --ids "$ID" \
      --query 'builds[0].[buildStatus,currentPhase]' --output text 2>/dev/null)
  case "${STATUS:-}" in
    SUCCEEDED|FAILED|FAULT|STOPPED|TIMED_OUT) break ;;
  esac
  [ $((SECONDS-START)) -ge "$TIMEOUT" ] && { echo "TIMEOUT: $ID still ${STATUS:-unknown}/${PHASE:-unknown} after ${TIMEOUT}s"; exit 2; }
  sleep 2
done
echo "$ID  status=$STATUS  phase=$PHASE  waited=$((SECONDS-START))s"
[ "$STATUS" = SUCCEEDED ]
