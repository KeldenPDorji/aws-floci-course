#!/usr/bin/env bash
# Lab 10 Exercise 3 - edge-readiness report for every usms- Lambda function.
# One JSON document on stdout; diagnostics on stderr. Read-only. Runs from any directory.
#
# edge_eligible is true only when ALL of:
#   runtime is Node.js or Python; no environment variables; no VPC configuration;
#   at least one published version; and
#     memory <= 128 and timeout <= 5      if the name contains "viewer"  (viewer triggers)
#     memory <= 10240 and timeout <= 30   otherwise                      (origin triggers)
# Each object also lists the reasons it is not eligible, so a false is never unexplained.
#
#   ./scripts/utilities/usms-edge-report.sh > outputs/lab-10-edge-report.json
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env" >/dev/null 2>&1 || true

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# No hard-coded list: every usms- function the account has.
if ! aws lambda list-functions \
      --query 'Functions[?starts_with(FunctionName, `usms-`)]' --output json > "$WORK/functions.json"; then
  echo "list-functions failed - is Floci up and course.env sourced?" >&2
  exit 1
fi

# Versions and aliases are not in list-functions; fetch them per function.
python3 -c 'import json,sys; [print(f["FunctionName"]) for f in json.load(open(sys.argv[1]))]' "$WORK/functions.json" \
  > "$WORK/names.txt"
while read -r fn; do
  [ -n "$fn" ] || continue
  aws lambda list-versions-by-function --function-name "$fn" --output json > "$WORK/$fn.versions.json" \
    || echo "warning: could not list versions of $fn" >&2
  aws lambda list-aliases --function-name "$fn" --output json > "$WORK/$fn.aliases.json" \
    || echo "warning: could not list aliases of $fn" >&2
done < "$WORK/names.txt"
echo "inspected $(wc -l < "$WORK/names.txt" | tr -d ' ') usms- function(s)" >&2

python3 - "$WORK" << 'PY'
import json, os, sys

work = sys.argv[1]

def load(name, default):
    path = os.path.join(work, name)
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return default

report = []
for f in sorted(load("functions.json", []), key=lambda f: f["FunctionName"]):
    name = f["FunctionName"]
    runtime = f.get("Runtime") or ""
    memory = f.get("MemorySize") or 0
    timeout = f.get("Timeout") or 0
    # .get(...) or {} : a function with no Environment key is the normal edge case, not an error
    env = (f.get("Environment") or {}).get("Variables") or {}
    subnets = (f.get("VpcConfig") or {}).get("SubnetIds") or []
    versions = [v["Version"] for v in load(name + ".versions.json", {}).get("Versions", [])
                if v.get("Version") != "$LATEST"]
    aliases = load(name + ".aliases.json", {}).get("Aliases", [])

    viewer = "viewer" in name
    mem_cap, time_cap = (128, 5) if viewer else (10240, 30)
    reasons = []
    if not runtime.startswith(("nodejs", "python")):
        reasons.append("runtime %s not supported at the edge" % (runtime or "none"))
    if env:
        reasons.append("%d environment variable(s)" % len(env))
    if subnets:
        reasons.append("VPC configuration (%d subnets)" % len(subnets))
    if not versions:
        reasons.append("no published version")
    if memory > mem_cap:
        reasons.append("memory %d MB over the %s cap %d" % (memory, "viewer" if viewer else "origin", mem_cap))
    if timeout > time_cap:
        reasons.append("timeout %d s over the %s cap %d" % (timeout, "viewer" if viewer else "origin", time_cap))

    report.append({
        "name": name,
        "runtime": runtime,
        "memory": memory,
        "timeout": timeout,
        "versions": len(versions),
        "aliases": len(aliases),
        "env_vars": bool(env),
        "edge_eligible": not reasons,
        "not_eligible_because": reasons,
    })

print(json.dumps(report, indent=2))
PY
