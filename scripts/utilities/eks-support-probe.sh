#!/usr/bin/env bash
# Lab 07 Step 2 - decide which EKS support path this build gives us. Read-only. Never exits non-zero.
# Classifies by the error TEXT, as Labs 04-06's probes do: an answer (even an error about an
# argument) means the service exists; UnknownOperation / a connection error means it does not.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

echo "== Floci =="
docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format 'running={{.State.Running}} image={{.Config.Image}}' 2>/dev/null || echo "running=NO-SUCH-CONTAINER"

echo
echo "== Does the eks API answer at all? =="
OUT=$(aws eks list-clusters --output text 2>&1)
if echo "$OUT" | grep -qE 'UnknownOperation|not supported|Could not connect|invalid choice'; then
  echo "eks list-clusters      : FAILED  ($OUT)"; EKS_API=no
else
  echo "eks list-clusters      : OK"; EKS_API=yes
fi
for op in "list-access-entries --cluster-name probe" "describe-addon-versions --max-items 1"; do
  O=$(aws eks $op 2>&1)
  if echo "$O" | grep -qE 'UnknownOperation|not supported'; then r="not available"; else r="answers"; fi
  printf "eks %-36s : %s\n" "${op%% *}" "$r"
done

echo
echo "== Local tooling =="
for t in kubectl k3d docker python3 jq; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  %-8s : %s\n" "$t" "$(command -v "$t")"
  else
    printf "  %-8s : MISSING\n" "$t"
  fi
done
command -v kubectl >/dev/null && echo "  kubectl client $(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"

echo
echo "== Verdict =="
if [ "$EKS_API" = yes ] && command -v kubectl >/dev/null 2>&1; then
  echo "PATH A  - use aws eks throughout"
elif command -v k3d >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  echo "PATH B  - create the cluster with k3d (Step 8B); IAM steps still apply"
else
  echo "PATH C  - manifests and reasoning only (Section 7.4)"
fi
