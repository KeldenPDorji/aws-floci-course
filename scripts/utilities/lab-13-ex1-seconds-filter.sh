#!/usr/bin/env bash
# Lab 13 Exercise 1 - a metric filter that publishes a value EXTRACTED from the log line.
#   usms-transcript-seconds on /usms/central/application -> USMS/Application TranscriptSecondsFromLogs
# Text dialect, space-delimited: [marker="USMS_EVENT", payload, seconds>=0], metricValue $seconds.
# Needs the Exercise 1 emitter (the seconds as a trailing token). Does not touch usms-central-errors.
#   ./scripts/utilities/lab-13-ex1-seconds-filter.sh | tee outputs/lab-13-ex1.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-13.env

GROUP="${USMS_LOG_GROUP_CENTRAL}"
NS="${USMS_METRIC_NAMESPACE}"
PATTERN='[marker="USMS_EVENT", payload, seconds>=0]'
VALUES=(0.63 1.37 1.84)    # under the 2 s lag threshold, so this exercise fires no alarm

echo "== 1. test-metric-filter first: six message shapes"
# 1-3: Step 7's lines as written (two tokens); 4: the Exercise 1 emitter line;
# 5: an ERROR line; 6: the health-check line; plus a non-numeric third token.
aws logs test-metric-filter --filter-pattern "$PATTERN" --log-event-messages \
  'USMS_EVENT {"event":"transcript.requested","student":"stu-00417","faculty":"science"}' \
  'USMS_EVENT {"event":"transcript.processed","student":"stu-00417","faculty":"science","seconds":0.42}' \
  'ERROR USMS_EVENT {"event":"transcript.failed","student":"stu-01044","faculty":"science","reason":"render timeout"}' \
  'USMS_EVENT {"event":"transcript.processed","faculty":"science","seconds":0.63,"trace_id":"1-x"} 0.63' \
  'health check ok: usms-transcript-notifier reachable' \
  'USMS_EVENT {"event":"transcript.processed"} slow' \
  --query 'matches[].[eventNumber, extractedValues."$seconds"]' --output text
echo "(only event 4 may match, extracting 0.63)"

echo
echo "== 2. deploy (no defaultValue: a 0 for every non-matching line would drag the average down)"
aws logs put-metric-filter --log-group-name "$GROUP" --filter-name usms-transcript-seconds \
  --filter-pattern "$PATTERN" \
  --metric-transformations 'metricName=TranscriptSecondsFromLogs,metricNamespace=USMS/Application,metricValue=$seconds,unit=Seconds' \
  && echo "usms-transcript-seconds put"
aws logs describe-metric-filters --log-group-name "$GROUP" \
  --query 'metricFilters[].[filterName,filterPattern,metricTransformations[0].metricValue]' --output text

echo
echo "== 3. emit known values: ${VALUES[*]}"
read -r START < <(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
for v in "${VALUES[@]}"; do
  ./scripts/utilities/usms-emit-telemetry.sh science "$v" | grep -E '^  log|^trace id'
done
read -r END < <(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"))')

echo
echo "== 4. read back TranscriptSecondsFromLogs, ${START} .. ${END}"
for _ in 1 2 3 4 5 6; do
  N=$(aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name TranscriptSecondsFromLogs \
        --start-time "$START" --end-time "$END" --period 600 --statistics SampleCount \
        --query 'sum(Datapoints[].SampleCount)' --output text 2>/dev/null)
  [ "${N%.*}" = "${#VALUES[@]}" ] && break
  sleep 10
done
aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name TranscriptSecondsFromLogs \
  --start-time "$START" --end-time "$END" --period 600 \
  --statistics SampleCount Minimum Maximum Sum Average --output json \
  --query 'Datapoints[].{n:SampleCount,min:Minimum,max:Maximum,sum:Sum,avg:Average,unit:Unit}'
python3 -c 'import sys; v=[float(x) for x in sys.argv[1:]]; print("expected: n=%d min=%s max=%s sum=%.2f" % (len(v), min(v), max(v), sum(v)))' "${VALUES[@]}"

echo
echo "== 5. the same transcripts by the direct route (TranscriptLagSeconds, Stage=notify)"
aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name TranscriptLagSeconds \
  --dimensions Name=Stage,Value=notify --start-time "$START" --end-time "$END" --period 600 \
  --statistics SampleCount Minimum Maximum Sum --output json \
  --query 'Datapoints[].{n:SampleCount,min:Minimum,max:Maximum,sum:Sum}'

echo
echo "== 6. usms-central-errors untouched"
aws logs describe-metric-filters --log-group-name "$GROUP" --filter-name-prefix usms-central-errors \
  --query 'metricFilters[].[filterName,filterPattern,metricTransformations[0].metricName,metricTransformations[0].metricValue]' --output text
