#!/usr/bin/env bash
# Lab 13 Steps 20-21 - one line per alarm: state, when it last changed, and why.
# Floci 2.2.0 has no DescribeAlarmHistory ("not supported by CloudWatch JSON", and
# "not supported by CloudWatch Query"), so a transition is evidenced by reading the state,
# its StateUpdatedTimestamp and its StateReason before and after. Read-only.
#   ./scripts/utilities/lab-13-alarm-states.sh [alarm ...]     default: this lab's three
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

[ $# -gt 0 ] || set -- usms-transcript-lag-high usms-notify-silence usms-transcript-pipeline-down
for A in "$@"; do
  aws cloudwatch describe-alarms --alarm-names "$A" --alarm-types MetricAlarm CompositeAlarm \
    --query '[MetricAlarms[0], CompositeAlarms[0]][?@] | [0].[AlarmName,StateValue,StateUpdatedTimestamp,StateReason]' \
    --output text
done
