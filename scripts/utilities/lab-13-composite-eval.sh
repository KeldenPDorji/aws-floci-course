#!/usr/bin/env bash
# Lab 13 Step 21 - the composite alarm usms-transcript-pipeline-down, on Floci 2.2.0.
#
# Floci has no composite alarms: PutCompositeAlarm is "not supported by CloudWatch JSON" and
# "not supported by CloudWatch Query". So the composite exists as a committed request document,
# templates/lab-13-composite-alarm.json, and this script does two things with it:
#   1. validates it against the AWS CLI's own CloudWatch request model, offline - the request
#      is sent to an unreachable endpoint, so nothing is created anywhere
#   2. evaluates its AlarmRule LOCALLY against the children's LIVE states (a STAND-IN for
#      CloudWatch's evaluation). Handles the rule language this lab uses: ALARM("x"), OK("x"),
#      INSUFFICIENT_DATA("x"), TRUE, FALSE, AND, OR, NOT and parentheses.
# Read-only.
#   ./scripts/utilities/lab-13-composite-eval.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

DOC=templates/lab-13-composite-alarm.json
OUT=$(aws cloudwatch put-composite-alarm --cli-input-json "file://$DOC" \
        --endpoint-url http://127.0.0.1:9 --cli-connect-timeout 2 2>&1)
case "$OUT" in
  *"Parameter validation failed"*) echo "request model : REJECTED"; echo "$OUT" | head -4; exit 1 ;;
  *"Could not connect"*)           echo "request model : accepted (failed only at connection, nothing created)" ;;
  *)                               echo "request model : unexpected: $(echo "$OUT" | head -1)" ;;
esac

RULE=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["AlarmRule"])' "$DOC")
echo "rule          : $RULE"
# Every alarm the rule names, with its live state.
STATES=$(python3 -c 'import json,re,sys;print(" ".join(sorted(set(re.findall(r"\"([^\"]+)\"", json.load(open(sys.argv[1]))["AlarmRule"])))))' "$DOC")
ARGS=()
for A in $STATES; do
  S=$(aws cloudwatch describe-alarms --alarm-names "$A" --query 'MetricAlarms[0].StateValue' --output text)
  printf 'child         : %-26s %s\n' "$A" "$S"
  ARGS+=("$A=$S")
done

python3 - "$RULE" "${ARGS[@]}" << 'PY'
import re, sys
rule, states = sys.argv[1], dict(a.split("=", 1) for a in sys.argv[2:])
tokens = re.findall(r'(ALARM|OK|INSUFFICIENT_DATA)\("([^"]+)"\)|(AND|OR|NOT|TRUE|FALSE|\(|\))', rule)
expr = []
for fn, name, word in tokens:
    if fn:
        if name not in states or states[name] in ("", "None"):
            sys.exit("rule names %r, which does not exist" % name)
        expr.append(str(states[name] == fn))
    else:
        expr.append({"AND": "and", "OR": "or", "NOT": "not", "TRUE": "True", "FALSE": "False"}.get(word, word))
result = eval(" ".join(expr), {"__builtins__": {}})   # only True/False/and/or/not/() reach here
print("composite     : %s   (evaluated locally - Floci 2.2.0 has no composite alarms)" % ("ALARM" if result else "OK"))
PY
