#!/usr/bin/env bash
# Emit one of each USMS telemetry signal - a log event, a metric data point and
# a trace - describing the same fictional transcript, so that the three can be
# joined afterwards by trace id.
#
# Usage:  usms-emit-telemetry.sh [faculty] [seconds]
# Writes: appends to outputs/lab-13-trace-ids.txt
#
# One change from the guide's script: the log event is passed to put-log-events as JSON
# (file://), not as "timestamp=...,message=USMS_EVENT {...}" shorthand. The shorthand cannot
# carry a message containing quotes and commas - every structured USMS_EVENT line - and the
# AWS CLI rejects it with ParamValidation before anything is sent (found in Lab 13 Step 7).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

FACULTY="${1:-science}"
SECONDS_TAKEN="${2:-0.42}"
GROUP="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
NAMESPACE="${USMS_METRIC_NAMESPACE:-USMS/Application}"
STREAM="emitter-$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d"))')"
EVENTS=$(mktemp); trap 'rm -f "$EVENTS"' EXIT

IDS=$(python3 -c "
import os, time
now = time.time()
print('1-%08x-%s' % (int(now), os.urandom(12).hex()), os.urandom(8).hex(), int(now*1000), now)
")
TRACE_ID=$(printf '%s' "$IDS" | awk '{print $1}')
SEG_ID=$(printf '%s'  "$IDS" | awk '{print $2}')
NOW_MS=$(printf '%s' "$IDS" | awk '{print $3}')
NOW_S=$(printf '%s'  "$IDS" | awk '{print $4}')

aws logs create-log-stream --log-group-name "$GROUP" --log-stream-name "$STREAM" 2>/dev/null || true

# Lab 13 Exercise 1: the seconds are repeated as a third, space-delimited token after the JSON,
#   USMS_EVENT {"event":"transcript.processed",...,"seconds":0.63,...} 0.63
# so the text-dialect filter usms-transcript-seconds can extract them as $seconds. The
# "USMS_EVENT " prefix rules out the JSON dialect, and a compact JSON body is one token.
# Cost: the value is written twice, and every reader that parsed the body with a strict
# json.loads must now stop at the end of the object (lab-13-faculty-counts.sh uses raw_decode).
python3 - "$NOW_MS" "$FACULTY" "$SECONDS_TAKEN" "$TRACE_ID" > "$EVENTS" << 'PY'
import json, sys
ms, faculty, secs_text, tid = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
secs = float(secs_text)          # refuses a non-number before anything is sent
payload = {"event": "transcript.processed", "faculty": faculty, "seconds": secs, "trace_id": tid}
message = "USMS_EVENT " + json.dumps(payload, separators=(",", ":")) + " " + secs_text
print(json.dumps([{"timestamp": ms, "message": message}]))
PY
[ -s "$EVENTS" ] || { echo "  log     FAILED seconds must be a number: $SECONDS_TAKEN" >&2; exit 1; }

REJECTED=$(aws logs put-log-events --log-group-name "$GROUP" --log-stream-name "$STREAM" \
  --log-events "file://$EVENTS" --query 'rejectedLogEventsInfo' --output json 2>&1)
if [ "$REJECTED" = "null" ]; then echo "  log     ok   $GROUP"
else echo "  log     FAILED $REJECTED"; fi

aws cloudwatch put-metric-data \
  --namespace "$NAMESPACE" \
  --metric-data "MetricName=TranscriptsProcessed,Unit=Count,Value=1,Dimensions=[{Name=Faculty,Value=$FACULTY},{Name=Stage,Value=notify}]" \
                "MetricName=TranscriptLagSeconds,Unit=Seconds,Value=$SECONDS_TAKEN,Dimensions=[{Name=Stage,Value=notify}]" \
  && echo "  metric  ok   $NAMESPACE"

SEGMENT=$(python3 - "$TRACE_ID" "$SEG_ID" "$NOW_S" "$FACULTY" "$SECONDS_TAKEN" << 'PY'
import json, sys
trace_id, seg_id, now, faculty, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], float(sys.argv[5])
print(json.dumps({
    "name": "usms-transcript-notifier",
    "id": seg_id,
    "trace_id": trace_id,
    "start_time": round(now - secs, 3),
    "end_time": round(now, 3),
    "origin": "AWS::Lambda::Function",
    "annotations": {"faculty": faculty, "stage": "notify", "emitted_by": "usms-emit-telemetry"},
}))
PY
)

if aws xray put-trace-segments --trace-segment-documents "$SEGMENT" \
     --query 'UnprocessedTraceSegments' --output text >/dev/null 2>&1; then
  echo "  trace   ok   $TRACE_ID"
else
  echo "  trace   SKIPPED (X-Ray unavailable on this build) $TRACE_ID"
fi

printf '%s %s emitter/%s\n' "$TRACE_ID" "$SEG_ID" "$FACULTY" >> outputs/lab-13-trace-ids.txt
echo
echo "trace id: $TRACE_ID"
