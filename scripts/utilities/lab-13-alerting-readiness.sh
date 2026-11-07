#!/usr/bin/env bash
# Lab 13 Exercise 5 - leave the three alarms ready for a future alerting lab, WITHOUT applying
# anything. Every file is generated; none is typed. All output stays in outputs/ (git-ignored).
#   draft                  outputs/lab-13-alarm-actions-draft.json (account from configs/lab-01.env)
#   validate [file]        every alarm name exists, every ARN is well formed; mismatches reported
#   emit                   the latency session: emitter runs with mixed faculties and latencies
#   baseline               outputs/lab-13-latency-baseline.json from the session window
#   readiness              outputs/lab-13-alerting-readiness.txt (runs validate itself)
#   all                    draft, validate, emit, baseline, readiness
# The draft is never applied: put-metric-alarm --alarm-actions REPLACES the alarm, and a partial
# definition would silently drop Step 19's Maximum, 2-of-3 and notBreaching.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env
# shellcheck disable=SC1091
source configs/lab-13.env

DRAFT=outputs/lab-13-alarm-actions-draft.json
SESSION=outputs/lab-13-ex5-session.txt
BASELINE=outputs/lab-13-latency-baseline.json
READY=outputs/lab-13-alerting-readiness.txt
ALARMS=("$USMS_ALARM_COMPOSITE" "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE")
utc() { python3 -c 'import datetime as d,sys;print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "${1:-0}"; }

draft() {
  python3 - "$USMS_ACCOUNT_ID" "$AWS_REGION_COURSE" "${ALARMS[@]}" > "$DRAFT" << 'PY'
import json, sys
account, region, composite, lag, silence = sys.argv[1:]
topic = lambda name: "arn:aws:sns:%s:%s:usms-%s" % (region, account, name)
print(json.dumps({
    "status": "DRAFT - not applied by Lab 13; a future alerting lab applies it with describe, merge, put",
    "account_from": "configs/lab-01.env USMS_ACCOUNT_ID",
    "region_from": "configs/course.env AWS_REGION_COURSE",
    "actions": [
        {"alarm": composite, "urgency": "page",
         "meaning": "transcript delivery is impaired: notifications are slow or have stopped",
         "alarm_actions": [topic("oncall-page")], "ok_actions": [topic("oncall-page")],
         "note": "the only alarm that pages - its children are its evidence, not separate pages"},
        {"alarm": lag, "urgency": "ticket",
         "meaning": "notification latency (Maximum) above 2 s in 2 of 3 minutes",
         "alarm_actions": [topic("platform-tickets")], "ok_actions": [],
         "note": "pages only through the composite, so a slow spell is not two pages"},
        {"alarm": silence, "urgency": "ticket",
         "meaning": "no USMS_NOTIFY line for 15 minutes - quiet, or broken",
         "alarm_actions": [topic("platform-tickets")], "ok_actions": [],
         "note": "fires on quiet nights too (TreatMissingData=breaching); needs a business-hours "
                 "condition before it may page, which is why it is a ticket here"},
    ],
}, indent=2))
PY
  echo "wrote $DRAFT ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["actions"]))' "$DRAFT") actions)"
}

# Prints one line per finding, then "validation: N mismatch(es)". Exit 1 on any mismatch.
validate() {
  local file="${1:-$DRAFT}"
  local names; names=$(python3 -c 'import json,sys;print(" ".join(a["alarm"] for a in json.load(open(sys.argv[1]))["actions"]))' "$file")
  # One call for all names (the hint): metric and composite alarms both.
  # shellcheck disable=SC2086
  local found; found=$(aws cloudwatch describe-alarms --alarm-names $names --alarm-types MetricAlarm CompositeAlarm \
                         --query '[MetricAlarms[].AlarmName, CompositeAlarms[].AlarmName][]' --output text 2>/dev/null)
  python3 - "$file" "$found" "$USMS_ACCOUNT_ID" << 'PY'
import json, re, sys
doc, found, account = json.load(open(sys.argv[1])), set(sys.argv[2].split()), sys.argv[3]
ARN = re.compile(r"^arn:aws:sns:[a-z]{2}(-[a-z]+)+-\d:(\d{12}):[A-Za-z0-9_-]{1,256}$")
bad = 0
for a in doc["actions"]:
    if a["alarm"] in found:
        print("  ok        alarm exists          %s" % a["alarm"])
    else:
        bad += 1
        print("  MISMATCH  alarm does not exist  %s" % a["alarm"])
    for arn in a.get("alarm_actions", []) + a.get("ok_actions", []):
        m = ARN.match(arn)
        if not m or len(arn.split(":")) != 6:
            bad += 1
            print("  MISMATCH  malformed ARN         %s" % arn)
        elif m.group(2) != account:
            bad += 1
            print("  MISMATCH  wrong account         %s" % arn)
print("validation: %d mismatch(es)" % bad)
sys.exit(1 if bad else 0)
PY
}

emit() {
  # Mixed faculties and latencies. One value above the 2 s threshold, alone in its minute, so the
  # baseline contains a breach without driving usms-transcript-lag-high (2 of 3) into ALARM.
  local runs=("science 0.38" "engineering 1.12" "business 0.91" "science 2.70" "engineering 1.55" "business 0.67")
  local start; start=$(utc -1)
  for r in "${runs[@]}"; do
    # shellcheck disable=SC2086
    ./scripts/utilities/usms-emit-telemetry.sh $r | grep -E '^  (log|metric)|^trace id' | sed "s/^/[$r] /"
  done
  printf 'start=%s\nend=%s\nruns=%s\n' "$start" "$(utc 2)" "${runs[*]}" > "$SESSION"
  echo "session recorded in $SESSION"
}

baseline() {
  [ -f "$SESSION" ] || { echo "no $SESSION - run: $0 emit" >&2; return 1; }
  local start end; start=$(sed -n 's/^start=//p' "$SESSION"); end=$(sed -n 's/^end=//p' "$SESSION")
  sleep 5
  aws cloudwatch get-metric-statistics --namespace "$USMS_METRIC_NAMESPACE" --metric-name TranscriptLagSeconds \
      --dimensions Name=Stage,Value=notify --start-time "$start" --end-time "$end" --period 60 \
      --statistics SampleCount Minimum Maximum Average --output json \
    | python3 -c '
import json, sys
d = json.load(sys.stdin); pts = sorted(d.get("Datapoints") or [], key=lambda p: p["Timestamp"])
n = sum(p["SampleCount"] for p in pts)
print(json.dumps({
  "metric": "USMS/Application TranscriptLagSeconds Stage=notify", "period": 60,
  "window": {"start": sys.argv[1], "end": sys.argv[2]}, "emitted": sys.argv[3],
  "datapoints": pts,
  "summary": None if not n else {"samples": int(n), "min": min(p["Minimum"] for p in pts),
              "max": max(p["Maximum"] for p in pts),
              "avg": round(sum(p["Average"] * p["SampleCount"] for p in pts) / n, 4)},
  "caveat": "six synthetic emitter runs on Floci: a baseline for the shape of the argument, not a production distribution"},
  indent=2, default=str))' "$start" "$end" "$(sed -n 's/^runs=//p' "$SESSION")" > "$BASELINE"
  echo "wrote $BASELINE: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"])' "$BASELINE")"
}

readiness() {
  {
    printf 'USMS alerting readiness (Lab 13 Exercise 5) - generated %s by %s\n' "$(utc)" "$0"
    printf '\n-- alarms and missing-data policies\n'
    aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE" \
      --query 'MetricAlarms[].[AlarmName,TreatMissingData,StateValue]' --output text
    printf '%s\t(composite: no missing-data policy)\tnot deployed - Floci 2.2.0 has no composite alarms\n' "$USMS_ALARM_COMPOSITE"
    printf '\n-- composite rule (templates/lab-13-composite-alarm.json)\n'
    python3 -c 'import json;print(json.load(open("templates/lab-13-composite-alarm.json"))["AlarmRule"])'
    printf '\n-- namespace and metrics\n%s\n' "$USMS_METRIC_NAMESPACE"
    aws cloudwatch list-metrics --namespace "$USMS_METRIC_NAMESPACE" --query 'Metrics[].MetricName' --output text \
      | tr '\t' '\n' | sort -u | sed 's/^/  /'
    printf '  (the five the lab defines: %s %s %s %s %s)\n' "$USMS_METRIC_NOTIFY_COUNT" "$USMS_METRIC_ERROR_COUNT" \
      "$USMS_METRIC_PROCESSED" "$USMS_METRIC_LAG" "$USMS_METRIC_EDGE_DENY"
    printf '\n-- notifier\n'
    aws lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live \
      --query '[`alias live -> version`, Version, `tracing`, TracingConfig.Mode]' --output text
    printf '\n-- capability flags (configs/lab-13.env)\nX-Ray: %s\nLogs Insights: %s\n' "$USMS_XRAY_SUPPORTED" "$USMS_INSIGHTS_SUPPORTED"
    printf '\n-- the draft, validated (%s)\n' "$DRAFT"
    validate "$DRAFT"
    printf '\n-- AlarmActions today (must be empty: the draft is not applied)\n'
    aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE" \
      --query 'MetricAlarms[].[AlarmName, length(AlarmActions)]' --output text
    printf '\n-- observed latency (%s)\n' "$BASELINE"
    python3 -c 'import json,sys;s=json.load(open(sys.argv[1]))["summary"];print("max %s s, avg %s s, over %s samples" % (s["max"], s["avg"], s["samples"]))' "$BASELINE"
  } > "$READY" 2>&1
  echo "wrote $READY ($(wc -l < "$READY" | tr -d ' ') lines)"
}

case "${1:-}" in
  draft) draft ;;
  validate) validate "${2:-$DRAFT}" ;;
  emit) emit ;;
  baseline) baseline ;;
  readiness) readiness ;;
  all) draft; validate; emit; baseline; readiness ;;
  *) echo "usage: $0 draft|validate [file]|emit|baseline|readiness|all" >&2; exit 2 ;;
esac
