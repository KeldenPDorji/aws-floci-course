#!/usr/bin/env bash
# Block until the current kubectl context's API server answers /readyz and the usms
# Deployments are back, then print how long it took. Replaces the guide's `sleep 20`
# after the Step 22 restart: Floci recreates the k3s container, so the API server is
# briefly absent even after `aws eks wait cluster-active` returns.
#   ./scripts/utilities/wait-kube.sh [timeout-seconds]
set -uo pipefail

TIMEOUT="${1:-240}"
START=$SECONDS
until kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1; do
  [ $((SECONDS-START)) -ge "$TIMEOUT" ] && { echo "TIMEOUT: API server not ready after ${TIMEOUT}s"; exit 1; }
  sleep 3
done
echo "API server ready after $((SECONDS-START))s"
for d in usms-enrolment usms-results usms-gateway; do
  kubectl rollout status "deployment/$d" -n usms --timeout="$((TIMEOUT > SECONDS-START ? TIMEOUT-(SECONDS-START) : 30))s" >/dev/null 2>&1 \
    && echo "  $d ready" || echo "  $d NOT ready"
done
