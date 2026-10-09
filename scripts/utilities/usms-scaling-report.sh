#!/usr/bin/env bash
# Lab 06 Exercise 3 - the complete scaling decision table of every usms-* ECS scalable target,
# with a COMPUTED verdict. No arguments; everything is discovered.
#   ./scripts/utilities/usms-scaling-report.sh        (from any directory)
# Also writes outputs/lab-06-scaling-report.json.
#
# -e is deliberately OFF: an unimplemented call (scheduled actions on Floci 2.2.0) or a
# target with no policies must print a row saying so, not abort and drop every target after it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Shell does the discovery, one call per level; python3 joins and formats.
aws application-autoscaling describe-scalable-targets --service-namespace ecs \
  --query "ScalableTargets[?starts_with(ResourceId,'service/usms-')]" --output json > "$TMP/targets.json" 2>/dev/null \
  || echo '[]' > "$TMP/targets.json"

i=0
for rid in $(jq -r '.[].ResourceId' "$TMP/targets.json"); do
  aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "$rid" \
    --output json > "$TMP/pol-$i.json" 2>/dev/null || echo '{"ScalingPolicies":[]}' > "$TMP/pol-$i.json"
  aws application-autoscaling describe-scheduled-actions --service-namespace ecs --resource-id "$rid" \
    --output json > "$TMP/sch-$i.json" 2>/dev/null || echo '{"unavailable":true}' > "$TMP/sch-$i.json"
  aws application-autoscaling describe-scaling-activities --service-namespace ecs --resource-id "$rid" \
    --max-items 1 --output json > "$TMP/act-$i.json" 2>/dev/null || echo '{"unavailable":true}' > "$TMP/act-$i.json"
  cluster=$(echo "$rid" | cut -d/ -f2); service=$(echo "$rid" | cut -d/ -f3)
  aws ecs describe-services --cluster "$cluster" --services "$service" \
    --query 'services[0].{d:desiredCount,r:runningCount}' --output json > "$TMP/svc-$i.json" 2>/dev/null \
    || echo '{"d":null,"r":null}' > "$TMP/svc-$i.json"
  # Every alarm involved, in ONE batched call (describe-alarms takes several names): the ones
  # the policies name, PLUS any alarm whose AlarmActions name a policy ARN. The second half
  # is needed because Floci 2.2.0 returns an empty Alarms list for step policies even when an
  # alarm invokes them; real AWS lists it. Asking from the alarm's side works on both.
  aws cloudwatch describe-alarms --query 'MetricAlarms[].{n:AlarmName,a:AlarmActions}' --output json \
    > "$TMP/allalarms.json" 2>/dev/null || echo '[]' > "$TMP/allalarms.json"
  names=($( { jq -r '.ScalingPolicies[].Alarms[]?.AlarmName' "$TMP/pol-$i.json";
              jq -r --slurpfile p "$TMP/pol-$i.json" \
                '.[] | select(any(.a[]?; . as $x | ($p[0].ScalingPolicies | map(.PolicyARN) | index($x)))) | .n' \
                "$TMP/allalarms.json"; } | sort -u))
  jq --slurpfile a "$TMP/allalarms.json" \
    '.ScalingPolicies |= map(. as $pol | .Alarms = ((.Alarms // []) + [$a[0][] | select(any(.a[]?; . == $pol.PolicyARN)) | {AlarmName: .n}] | unique_by(.AlarmName)))' \
    "$TMP/pol-$i.json" > "$TMP/pol-$i.tmp" && mv "$TMP/pol-$i.tmp" "$TMP/pol-$i.json"
  if [ "${#names[@]}" -gt 0 ]; then
    aws cloudwatch describe-alarms --alarm-names "${names[@]}" \
      --query 'MetricAlarms[].{n:AlarmName,s:StateValue,ns:Namespace,m:MetricName,op:ComparisonOperator,t:Threshold}' \
      --output json > "$TMP/alm-$i.json" 2>/dev/null || echo '[]' > "$TMP/alm-$i.json"
  else
    echo '[]' > "$TMP/alm-$i.json"
  fi
  i=$((i+1))
done

python3 - "$TMP" "$REPO_ROOT/outputs/lab-06-scaling-report.json" <<'PY'
import json, os, sys
tmp, out = sys.argv[1], sys.argv[2]
L = lambda n, d: json.load(open(os.path.join(tmp, n))) if os.path.exists(os.path.join(tmp, n)) else d
OPS = {"GreaterThanOrEqualToThreshold": ">=", "GreaterThanThreshold": ">", "LessThanThreshold": "<",
       "LessThanOrEqualToThreshold": "<="}
SHORT = {"ECSServiceAverageCPUUtilization": "CPU", "ECSServiceAverageMemoryUtilization": "Memory",
         "ALBRequestCountPerTarget": "ALBReq"}

def verdict(t, desired, npol):
    # Ordered: the first true rule wins.
    #  PINNED first - if min == max nothing can move, so every other statement is moot.
    #  FROZEN outranks AT-CEILING: a suspended target sitting at its ceiling is FROZEN first.
    #    If someone suspends scale-in during an incident, "at ceiling" reads as "working as
    #    designed" and hides the switch that will stop it ever coming down; the switch is the
    #    actionable fact, so it must be what the report says.
    #  AT-CEILING before AT-FLOOR: being unable to grow is the outage risk; at the floor is cost.
    s = t.get("SuspendedState", {})
    if t["MinCapacity"] == t["MaxCapacity"]: return "PINNED"
    if any(s.values()): return "FROZEN"
    if desired is not None and desired == t["MaxCapacity"]: return "AT-CEILING"
    if desired is not None and desired == t["MinCapacity"] and npol > 1: return "AT-FLOOR"
    return "ELASTIC"

report = []
targets = L("targets.json", [])
if not targets:
    print("no usms-* ECS scalable targets found")
for i, t in enumerate(targets):
    pols = L(f"pol-{i}.json", {"ScalingPolicies": []})["ScalingPolicies"]
    sch = L(f"sch-{i}.json", {})
    act = L(f"act-{i}.json", {})
    svc = L(f"svc-{i}.json", {})
    alarms = {a["n"]: a for a in L(f"alm-{i}.json", [])}
    d, r = svc.get("d"), svc.get("r")
    v = verdict(t, d, len(pols))
    susp = [k.replace("Suspended", "") for k, val in t.get("SuspendedState", {}).items() if val]
    print(f"{t['ResourceId']}   {t['ScalableDimension']}")
    print(f"  bounds       min={t['MinCapacity']}  max={t['MaxCapacity']}   desired={d}   running={r}   {v}")
    print(f"  suspended    {', '.join(susp) if susp else 'none'}")
    rows = []
    if not pols:
        print("  policies     none")
    for p in sorted(pols, key=lambda p: (p["PolicyType"] != "TargetTrackingScaling", p["PolicyName"])):
        if p["PolicyType"] == "TargetTrackingScaling":
            c = p["TargetTrackingScalingPolicyConfiguration"]
            m = c.get("PredefinedMetricSpecification", {}).get("PredefinedMetricType", "custom")
            print(f"  target-track {p['PolicyName']:<40} {SHORT.get(m, m)}/{c['TargetValue']:<9} "
                  f"out={c.get('ScaleOutCooldown')}  in={c.get('ScaleInCooldown')}"
                  + ("  scale-in DISABLED" if c.get("DisableScaleIn") else ""))
            names = [a["AlarmName"] for a in p.get("Alarms", [])]
            if names:
                parts = []
                for n in names:
                    kind = "AlarmHigh" if "AlarmHigh" in n else "AlarmLow" if "AlarmLow" in n else n
                    parts.append(f"{kind}={alarms.get(n, {}).get('s', 'missing')}")
                print(f"                 alarms  {'  '.join(parts)}")
            else:
                print("                 alarms  none listed by the policy")
        else:
            c = p["StepScalingPolicyConfiguration"]
            steps = " / ".join(f"{s['ScalingAdjustment']:+d}" for s in c["StepAdjustments"])
            print(f"  step         {p['PolicyName']:<40} {steps:<15} cooldown={c.get('Cooldown')}")
            names = [a["AlarmName"] for a in p.get("Alarms", [])]
            if not names:
                print("                 alarm   none attached - this policy can never fire")
            for n in names:
                a = alarms.get(n, {})
                print(f"                 alarm   {n} = {a.get('s', 'missing')}  "
                      f"({a.get('ns')} {a.get('m')} {OPS.get(a.get('op'), a.get('op'))} {a.get('t')})")
        rows.append({"name": p["PolicyName"], "type": p["PolicyType"]})
    if sch.get("unavailable"):
        print("  scheduled    not available on this build")
    elif not sch.get("ScheduledActions"):
        print("  scheduled    none")
    else:
        for s in sch["ScheduledActions"]:
            print(f"  scheduled    {s['ScheduledActionName']}  {s['Schedule']}  {s.get('Timezone', 'UTC')}  "
                  f"min={s.get('ScalableTargetAction', {}).get('MinCapacity')}")
    acts = act.get("ScalingActivities", [])
    if act.get("unavailable"):
        print("  last activity  not available on this build")
    elif not acts:
        print("  last activity  none recorded")
    else:
        a = acts[0]
        print(f"  last activity  {a['StartTime'][:19]}  {a['StatusCode']}  {a.get('Description', '')}")
    report.append({"resourceId": t["ResourceId"], "min": t["MinCapacity"], "max": t["MaxCapacity"],
                   "desired": d, "running": r, "verdict": v, "suspended": susp, "policies": rows})

json.dump(report, open(out, "w"), indent=2)
PY
