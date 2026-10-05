#!/usr/bin/env bash
# Lab 05 Exercise 3 - the complete decision table of every usms-* Application Load Balancer.
# Takes no arguments; discovers every load balancer, listener, rule and target group.
#   ./scripts/utilities/usms-lb-report.sh        (from any directory)
# Also writes outputs/lab-05-lb-report.json.
#
# -e is deliberately OFF. A load balancer with no listeners, or a listener whose rules
# cannot be read, must print a row saying so rather than abort the whole report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Shell does the four levels of discovery (one AWS call per object); python3 does the
# joining and formatting, because that is where JSON stops being pleasant in bash.
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'usms-') && Type=='application']" \
  --output json > "$TMP/lbs.json" || echo '[]' > "$TMP/lbs.json"

for lb in $(jq -r '.[].LoadBalancerArn' "$TMP/lbs.json"); do
  id="${lb##*/}"
  aws elbv2 describe-listeners --load-balancer-arn "$lb" --output json > "$TMP/listeners-$id.json" \
    || echo '{"Listeners":[]}' > "$TMP/listeners-$id.json"
  for l in $(jq -r '.Listeners[].ListenerArn' "$TMP/listeners-$id.json"); do
    aws elbv2 describe-rules --listener-arn "$l" --output json > "$TMP/rules-${l##*/}.json" \
      || echo '{"Rules":[]}' > "$TMP/rules-${l##*/}.json"
  done
done

aws elbv2 describe-target-groups --output json > "$TMP/tgs.json" || echo '{"TargetGroups":[]}' > "$TMP/tgs.json"
for tg in $(jq -r '.TargetGroups[].TargetGroupArn' "$TMP/tgs.json"); do
  aws elbv2 describe-target-health --target-group-arn "$tg" --output json > "$TMP/health-${tg##*/}.json" \
    || echo '{"TargetHealthDescriptions":[]}' > "$TMP/health-${tg##*/}.json"
done

python3 - "$TMP" "$REPO_ROOT/outputs/lab-05-lb-report.json" <<'PY'
import json, os, sys

tmp, out_path = sys.argv[1], sys.argv[2]
load = lambda name, default: json.load(open(os.path.join(tmp, name))) if os.path.exists(os.path.join(tmp, name)) else default

lbs = load("lbs.json", [])
tgs = {t["TargetGroupArn"]: t for t in load("tgs.json", {"TargetGroups": []})["TargetGroups"]}

def tg_summary(arn):
    name = tgs.get(arn, {}).get("TargetGroupName", arn.split("/")[-2] if "/" in arn else arn)
    th = load(f"health-{arn.split('/')[-1]}.json", {"TargetHealthDescriptions": []})["TargetHealthDescriptions"]
    healthy = sum(1 for t in th if t["TargetHealth"]["State"] == "healthy")
    return name, len(th), healthy, f"-> {name:<18} ({len(th)} targets, {healthy} healthy)"

def action_summary(a):
    t = a.get("Type")
    if t == "forward":
        arn = a.get("TargetGroupArn") or a["ForwardConfig"]["TargetGroups"][0]["TargetGroupArn"]
        return tg_summary(arn)[3]
    if t == "fixed-response":
        return f"-> fixed-response {a['FixedResponseConfig']['StatusCode']}"
    if t == "redirect":
        r = a["RedirectConfig"]
        return f"-> redirect {r.get('StatusCode','')} {r.get('Protocol','#{protocol}')}:{r.get('Port','#{port}')}"
    return f"-> {t}"

def cond_summary(conds):
    if not conds:
        return "-", "-"
    c = conds[0]
    field = c["Field"]
    vals = c.get("Values") or next((v["Values"] for k, v in c.items() if k.endswith("Config") and isinstance(v, dict) and "Values" in v), [])
    return field, ",".join(vals)

# Priority is a STRING, and the default rule's priority is the literal word "default".
# Sorting the strings would put "10" before "5" and "default" anywhere; so sort on a
# tuple: (0, int) for numbered rules, (1, 0) for the default, which always runs last.
def prio_key(r):
    p = r["Priority"]
    return (1, 0) if p == "default" else (0, int(p))

report = []
if not lbs:
    print("no usms-* application load balancers found")
for lb in lbs:
    lid = lb["LoadBalancerArn"].split("/")[-1]
    print(f"{lb['LoadBalancerName']:<20} {lb['Scheme']:<16} {lb['Type']:<12} {lb['State']['Code']:<7} "
          f"AZs={len(lb.get('AvailabilityZones', []))}  SGs={len(lb.get('SecurityGroups', []))}")
    entry = {"name": lb["LoadBalancerName"], "scheme": lb["Scheme"], "state": lb["State"]["Code"], "listeners": []}
    listeners = sorted(load(f"listeners-{lid}.json", {"Listeners": []})["Listeners"], key=lambda l: l["Port"])
    if not listeners:
        print("  (no listeners - this load balancer answers nothing)")
    for l in listeners:
        print(f"  {l['Protocol']}:{l['Port']}")
        rules = sorted(load(f"rules-{l['ListenerArn'].split('/')[-1]}.json", {"Rules": []})["Rules"], key=prio_key)
        lrows = []
        for r in rules:
            field, vals = cond_summary(r.get("Conditions", []))
            act = action_summary(r["Actions"][0]) if r.get("Actions") else "-> (no action)"
            print(f"    prio  {r['Priority']:<8} {field:<13} {vals:<29} {act}")
            lrows.append({"priority": r["Priority"], "condition": field, "values": vals, "action": act})
        if not rules:
            print("    (no rules returned)")
        entry["listeners"].append({"port": l["Port"], "protocol": l["Protocol"], "rules": lrows})
    report.append(entry)

with open(out_path, "w") as f:
    json.dump(report, f, indent=2)
PY
