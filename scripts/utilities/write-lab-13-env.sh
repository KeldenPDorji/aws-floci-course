#!/usr/bin/env bash
# Generate configs/lab-13.env by LOOKUP (Lab 13 Step 25). Names, ARNs and IDs only.
# The guide's 28 exports. Two values the guide takes from shell variables (NOTIFIER_V2,
# NOTIFIER_V3) are looked up by the description each version was published with, because on
# this repository they are versions 3 and 4 (Lab 10's "Your turn" had already made a 2).
# Stops if a must-succeed lookup returns empty or None.
#   ./scripts/utilities/write-lab-13-env.sh            28 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

FN=usms-transcript-notifier
ver_by_desc() { aws lambda list-versions-by-function --function-name $FN \
                  --query "Versions[?Description=='$1'].Version | [0]" --output text; }
V_INSTR=$(ver_by_desc "Lab 13 - instrumented: custom metrics and trace id")
V_TRACED=$(ver_by_desc "Lab 13 - instrumented + active tracing")
STREAM=$(aws logs describe-log-streams --log-group-name /usms/central/application \
           --order-by LastEventTime --descending --max-items 1 \
           --query 'logStreams[0].logStreamName' --output text | head -1)
OBS_ARN=$(aws iam list-policies --scope Local \
            --query "Policies[?PolicyName=='USMSObservabilityWrite'].Arn | [0]" --output text)
ALIAS_V=$(aws lambda get-alias --function-name $FN --name live --query FunctionVersion --output text)
TRACING=$(aws lambda get-function-configuration --function-name $FN --qualifier live \
            --query 'TracingConfig.Mode' --output text)
XRAY=$(aws xray get-sampling-rules >/dev/null 2>&1 && echo yes || echo no)
LAST_TRACE=$(awk 'END {print $1}' outputs/lab-13-trace-ids.txt 2>/dev/null | grep -E '^1-' || echo none)
# Insights on Floci 2.2.0: start-query exists and completes `fields | limit`, but filter, stats
# and parse fail, and describe-queries is unsupported. "partial" records that honestly.
INSIGHTS=$(aws logs describe-queries --max-results 1 >/dev/null 2>&1 && echo yes || \
           { aws logs start-query --log-group-name /usms/central/application --start-time 0 --end-time 1 \
               --query-string 'fields @message | limit 1' >/dev/null 2>&1 && echo partial || echo no; })
NOW=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

for v in "$V_INSTR" "$V_TRACED" "$STREAM" "$OBS_ARN" "$ALIAS_V" "$TRACING"; do
  case "$v" in ""|None) echo "STOP - a lookup came back empty or None; configs/lab-13.env not written" >&2; exit 1 ;; esac
done

cat > configs/lab-13.env << EOF
# Lab 13 - Centralized logging and monitoring with CloudWatch and X-Ray
# Generated on ${NOW}
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.
#
# Floci 2.2.0: no X-Ray and no composite alarms. usms-transcript-pipeline-down exists as the
# committed document templates/lab-13-composite-alarm.json (scripts/utilities/
# lab-13-composite-eval.sh evaluates its rule locally); a future alerting lab on real AWS creates it.

# --- log layer ------------------------------------------------------------
export USMS_LOG_GROUP_CENTRAL=/usms/central/application
export USMS_LOG_GROUP_ECS=/usms/ecs/enrolment
export USMS_LOG_STREAM_CENTRAL=${STREAM}
export USMS_LOG_RETENTION_APP=30
export USMS_LOG_RETENTION_FN=14

# --- metric layer ---------------------------------------------------------
export USMS_METRIC_NAMESPACE=USMS/Application
export USMS_METRIC_FILTER_NOTIFY=usms-notify-count
export USMS_METRIC_FILTER_ERRORS=usms-central-errors
export USMS_METRIC_NOTIFY_COUNT=NotifyCount
export USMS_METRIC_ERROR_COUNT=CentralErrorCount
export USMS_METRIC_PROCESSED=TranscriptsProcessed
export USMS_METRIC_LAG=TranscriptLagSeconds
export USMS_METRIC_EDGE_DENY=EdgeDenyCount

# --- iam ------------------------------------------------------------------
export USMS_POLICY_OBSERVABILITY=USMSObservabilityWrite
export USMS_POLICY_OBSERVABILITY_ARN=${OBS_ARN}

# --- the instrumented notifier -------------------------------------------
export USMS_NOTIFIER_VERSION_INSTRUMENTED=${V_INSTR}
export USMS_NOTIFIER_VERSION_TRACED=${V_TRACED}
export USMS_NOTIFIER_ALIAS_VERSION=${ALIAS_V}
export USMS_NOTIFIER_TRACING_MODE=${TRACING}

# --- alarms - a future alerting lab attaches SNS actions to these three ----
export USMS_ALARM_LAG_HIGH=usms-transcript-lag-high
export USMS_ALARM_NOTIFY_SILENCE=usms-notify-silence
export USMS_ALARM_COMPOSITE=usms-transcript-pipeline-down

# --- dashboard ------------------------------------------------------------
export USMS_DASHBOARD=usms-overview

# --- x-ray ----------------------------------------------------------------
export USMS_XRAY_SAMPLING_RULE=usms-transcripts-sampling
export USMS_XRAY_SUPPORTED=${XRAY}
export USMS_XRAY_LAST_TRACE_ID=${LAST_TRACE}

# --- capability flags recorded at lab time --------------------------------
export USMS_INSIGHTS_SUPPORTED=${INSIGHTS}
export USMS_TELEMETRY_EMITTER=scripts/utilities/usms-emit-telemetry.sh
EOF

echo "configs/lab-13.env: $(grep -c '^export' configs/lab-13.env) exports"
