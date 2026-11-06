#!/usr/bin/env bash
# Lab 10 Step 14 - is a function eligible for a Lambda@Edge association?
# The guide's edge_eligibility() function, moved into a script so Step 14, Exercise 3 and
# the verification can share it. Read-only. Six questions per function:
#   no environment variables, memory within the trigger cap, timeout within the viewer cap,
#   Node.js or Python runtime, no VPC configuration, at least one published version.
#   ./scripts/utilities/lab-10-edge-eligibility.sh [function cap]...
#   default: usms-edge-viewer-request 128 usms-edge-origin-response 128
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

edge_eligibility() {   # $1 = function name, $2 = max memory for its trigger point
  local fn="$1" cap="$2" cfg envcount mem timeout runtime vpc versions
  cfg=$(aws lambda get-function-configuration --function-name "$fn" --output json)
  envcount=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Environment",{}).get("Variables",{}) or {}))')
  mem=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["MemorySize"])')
  timeout=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Timeout"])')
  runtime=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Runtime"])')
  vpc=$(printf '%s' "$cfg" | python3 -c 'import json,sys; print(len((json.load(sys.stdin).get("VpcConfig") or {}).get("SubnetIds",[]) or []))')
  # \$LATEST is escaped so the shell leaves it for JMESPath; unescaped, the count is off by one.
  versions=$(aws lambda list-versions-by-function --function-name "$fn" \
               --query "length(Versions[?Version!='\$LATEST'])" --output text)

  printf '\n%s\n' "$fn"
  [ "$envcount" -eq 0 ] && printf '  ok   no environment variables\n'      || printf '  NO   %s environment variables set\n' "$envcount"
  [ "$mem" -le "$cap" ] && printf '  ok   memory %s MB (cap %s)\n' "$mem" "$cap" || printf '  NO   memory %s MB exceeds cap %s\n' "$mem" "$cap"
  [ "$timeout" -le 5 ]  && printf '  ok   timeout %s s\n' "$timeout"        || printf '  NO   timeout %s s exceeds viewer cap 5\n' "$timeout"
  case "$runtime" in nodejs*|python*) printf '  ok   runtime %s\n' "$runtime" ;; *) printf '  NO   runtime %s not supported at the edge\n' "$runtime" ;; esac
  [ "$vpc" -eq 0 ]      && printf '  ok   no VPC configuration\n'           || printf '  NO   attached to %s subnets\n' "$vpc"
  [ "$versions" -ge 1 ] && printf '  ok   %s published version(s)\n' "$versions" || printf '  NO   no published version to associate\n'
}

echo "Lambda@Edge eligibility - $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
if [ $# -eq 0 ]; then set -- usms-edge-viewer-request 128 usms-edge-origin-response 128; fi
while [ $# -ge 2 ]; do edge_eligibility "$1" "$2"; shift 2; done
