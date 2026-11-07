#!/usr/bin/env bash
# Lab 13 Exercise 2 - generate templates/lab-13-dashboard.json instead of hand-editing it.
# Account and region come from configs/lab-01.env (USMS_ACCOUNT_ID) and configs/course.env
# (AWS_REGION_COURSE); this script contains no account id and no region. Six widgets: Step 22's
# five, plus CentralErrorCount over the last three hours with a threshold line.
#   ./scripts/utilities/write-lab-13-dashboard.sh              write the template
#   ./scripts/utilities/write-lab-13-dashboard.sh --put        write it, put-dashboard, check it
#   ./scripts/utilities/write-lab-13-dashboard.sh --stdout     print the document only
# The environment wins over the config files, so setting USMS_ACCOUNT_ID (and AWS_REGION_COURSE)
# in front of --stdout shows that every ARN follows the variable.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
ACCOUNT_OVERRIDE="${USMS_ACCOUNT_ID:-}"
REGION_OVERRIDE="${AWS_REGION_COURSE:-}"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-01.env
# shellcheck disable=SC1091
source configs/lab-13.env
ACCOUNT="${ACCOUNT_OVERRIDE:-${USMS_ACCOUNT_ID:?configs/lab-01.env has no USMS_ACCOUNT_ID}}"
REGION="${REGION_OVERRIDE:-${AWS_REGION_COURSE:?configs/course.env has no AWS_REGION_COURSE}}"
MODE="${1:-write}"
OUT=templates/lab-13-dashboard.json

# The sixth widget's line. There is no CentralErrorCount alarm yet, so this is the threshold
# PROPOSED for one (Exercise 4): any failure in five minutes. Labelled as proposed, not as an
# alarm, so nobody reads a line on a graph as a promise that something pages.
ERROR_THRESHOLD=1

DOC=$(python3 - "$ACCOUNT" "$REGION" "$USMS_METRIC_NAMESPACE" "$ERROR_THRESHOLD" \
        "$USMS_ALARM_COMPOSITE" "$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE" << 'PY'
import json, sys
account, region, ns, err_threshold, *alarms = sys.argv[1:]
arn = lambda name: "arn:aws:cloudwatch:%s:%s:alarm:%s" % (region, account, name)

widgets = [
    {"type": "text", "x": 0, "y": 0, "width": 24, "height": 2,
     "properties": {"markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."}},
    {"type": "metric", "x": 0, "y": 2, "width": 12, "height": 6,
     "properties": {"title": "Transcripts processed, by faculty", "region": region, "stat": "Sum",
                    "period": 300, "view": "timeSeries", "stacked": False,
                    "metrics": [[ns, "TranscriptsProcessed", "Faculty", f, "Stage", "notify"]
                                for f in ("science", "engineering")]}},
    {"type": "metric", "x": 12, "y": 2, "width": 12, "height": 6,
     "properties": {"title": "Notification latency - max and average", "region": region,
                    "period": 60, "view": "timeSeries",
                    "metrics": [[ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Maximum", "label": "max"}],
                                [ns, "TranscriptLagSeconds", "Stage", "notify", {"stat": "Average", "label": "avg"}]],
                    "annotations": {"horizontal": [{"label": "alarm threshold", "value": 2}]}}},
    {"type": "metric", "x": 0, "y": 8, "width": 8, "height": 4,
     "properties": {"title": "Notifications in the last 5 minutes", "region": region, "stat": "Sum",
                    "period": 300, "view": "singleValue",
                    "metrics": [[ns, "NotifyCount"], [ns, "CentralErrorCount"]]}},
    {"type": "alarm", "x": 8, "y": 8, "width": 16, "height": 4,
     "properties": {"title": "Pipeline alarms", "alarms": [arn(a) for a in alarms]}},
    # Exercise 2: the sixth widget, below everything else (the five end at y=12).
    {"type": "metric", "x": 0, "y": 12, "width": 24, "height": 6,
     "properties": {"title": "Central errors - last 3 hours", "region": region, "stat": "Sum",
                    "period": 300, "view": "timeSeries", "start": "-PT3H", "end": "P0D",
                    "metrics": [[ns, "CentralErrorCount", {"label": "errors per 5 min"}]],
                    "annotations": {"horizontal": [{"label": "proposed alarm threshold (no alarm yet)",
                                                    "value": int(err_threshold)}]}}},
]
print(json.dumps({"widgets": widgets}, indent=2, ensure_ascii=False))
PY
)

case "$MODE" in
  --stdout) printf '%s\n' "$DOC"; exit 0 ;;
  write|--put) printf '%s\n' "$DOC" > "$OUT"; echo "wrote $OUT ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["widgets"]))' "$OUT") widgets, account ${ACCOUNT}, region ${REGION})" ;;
  *) echo "usage: $0 [--put|--stdout]" >&2; exit 2 ;;
esac
[ "$MODE" = "--put" ] || exit 0

echo "put-dashboard ${USMS_DASHBOARD}, DashboardValidationMessages:"
aws cloudwatch put-dashboard --dashboard-name "$USMS_DASHBOARD" --dashboard-body "file://$OUT" \
  --query 'DashboardValidationMessages' --output json
aws cloudwatch get-dashboard --dashboard-name "$USMS_DASHBOARD" --query DashboardBody --output text \
  | python3 -c '
import json, sys
w = json.load(sys.stdin)["widgets"]
boxes = [(x["x"], x["y"], x["x"] + x["width"], x["y"] + x["height"]) for x in w]
overlap = any(a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]
              for i, a in enumerate(boxes) for b in boxes[i + 1:])
print("deployed widgets :", len(w))
print("max right edge   :", max(b[2] for b in boxes), "(grid is 24)")
print("overlapping      :", overlap)'
