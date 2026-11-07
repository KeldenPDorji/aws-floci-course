#!/usr/bin/env bash
# Lab 13 Exercise 3 - are the usms-* alarm thresholds defensible?
# For every alarm whose name begins usms- (no list and no metric name is hard-coded): its
# configuration, what its metric actually did over the last 24 hours, and whether the threshold
# was ever crossed. JSON on stdout and nothing else; diagnostics on stderr. Read-only.
#   ./scripts/utilities/usms-threshold-report.sh > outputs/lab-13-threshold-report.json
#   ./scripts/utilities/usms-threshold-report.sh --hours 6
#
# Fields beyond the exercise's list, because the list alone misleads on two alarms:
#   observed           - raw samples over the window (min, avg, max, samples), at any period
#   alarm_view         - the metric as the ALARM sees it: its statistic, at its period
#   threshold_ever_breached - true if any alarm_view datapoint crossed the threshold
#   empty_periods      - periods in the window with no datapoint at all; with
#                        TreatMissingData=breaching each one counts as breaching (usms-notify-silence)
# Composite alarms have no metric: every metric field is null. Floci 2.2.0 has no composite alarms,
# so a composite that exists only as a committed document (templates/*composite-alarm*.json) is
# reported with "deployed": false rather than left out.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

HOURS=24
[ "${1:-}" = "--hours" ] && HOURS="${2:?--hours needs a number}"

ALARMS_JSON=$(aws cloudwatch describe-alarms --alarm-name-prefix usms- \
                --alarm-types MetricAlarm CompositeAlarm --output json) \
  || { echo "describe-alarms failed - is Floci running?" >&2; exit 1; }

printf '%s' "$ALARMS_JSON" | python3 -c '
import datetime, glob, json, operator, subprocess, sys

hours = int(sys.argv[1])
data = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
start = now - datetime.timedelta(hours=hours)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
log = lambda *a: print(*a, file=sys.stderr)

OPS = {"GreaterThanThreshold": operator.gt, "GreaterThanOrEqualToThreshold": operator.ge,
       "LessThanThreshold": operator.lt, "LessThanOrEqualToThreshold": operator.le}

def stats(alarm, period, statistics):
    # get-metric-statistics returns at most 1,440 datapoints per call (Floci does not enforce
    # it; AWS does), so a long window at a short period is asked for in chunks.
    dims = alarm.get("Dimensions") or []          # an alarm with no dimensions passes none
    points, t0, step = [], start, datetime.timedelta(seconds=period * 1440)
    while t0 < now:
        t1 = min(t0 + step, now)
        cmd = ["aws", "cloudwatch", "get-metric-statistics",
               "--namespace", alarm["Namespace"], "--metric-name", alarm["MetricName"],
               "--start-time", iso(t0), "--end-time", iso(t1), "--period", str(period),
               "--statistics", *statistics, "--output", "json"]
        if dims:
            cmd += ["--dimensions", *["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in dims]]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            log("get-metric-statistics failed for %s: %s" % (alarm["AlarmName"], r.stderr.strip()))
            return []
        points += json.loads(r.stdout).get("Datapoints") or []
        t0 = t1
    return points

def metric_alarm(a):
    out = {"alarm": a["AlarmName"], "type": "metric", "deployed": True,
           "namespace": a.get("Namespace"), "metric": a.get("MetricName"),
           "dimensions": {d["Name"]: d["Value"] for d in a.get("Dimensions") or []},
           "statistic": a.get("Statistic") or a.get("ExtendedStatistic"),
           "period": a.get("Period"), "evaluation_periods": a.get("EvaluationPeriods"),
           "datapoints_to_alarm": a.get("DatapointsToAlarm"), "threshold": a.get("Threshold"),
           "operator": a.get("ComparisonOperator"), "missing_data": a.get("TreatMissingData"),
           "state": a.get("StateValue")}
    if not a.get("MetricName"):       # a metric-math alarm: no single metric to read
        log("%s uses metric math; not evaluated" % a["AlarmName"])
        out.update(observed=None, alarm_view=None, threshold_ever_breached=None, empty_periods=None)
        return out

    raw = stats(a, 3600, ["Minimum", "Maximum", "Sum", "SampleCount"])
    n = sum(p["SampleCount"] for p in raw)
    out["observed"] = None if not n else {
        "min": min(p["Minimum"] for p in raw), "avg": round(sum(p["Sum"] for p in raw) / n, 4),
        "max": max(p["Maximum"] for p in raw), "samples": int(n)}

    period, stat = a["Period"], a.get("Statistic")
    view = stats(a, period, [stat]) if stat else []
    values = [p[stat] for p in view if stat in p]
    cross = OPS.get(a.get("ComparisonOperator"))
    out["alarm_view"] = None if not values else {
        "statistic": stat, "period": period, "datapoints": len(values),
        "min": min(values), "max": max(values)}
    out["threshold_ever_breached"] = bool(cross and any(cross(v, a["Threshold"]) for v in values))
    out["empty_periods"] = hours * 3600 // period - len(values)
    if not n:
        log("%s: no data for %s in the last %d h" % (a["AlarmName"], a["MetricName"], hours))
    return out

def composite(c, deployed):
    out = {"alarm": c["AlarmName"], "type": "composite", "deployed": deployed,
           "rule": c.get("AlarmRule"), "state": c.get("StateValue")}
    for k in ("namespace", "metric", "dimensions", "statistic", "period", "evaluation_periods",
              "datapoints_to_alarm", "threshold", "operator", "missing_data", "observed",
              "alarm_view", "threshold_ever_breached", "empty_periods"):
        out[k] = None
    return out

report = [metric_alarm(a) for a in data.get("MetricAlarms") or []]
deployed = {c["AlarmName"] for c in data.get("CompositeAlarms") or []}
report += [composite(c, True) for c in data.get("CompositeAlarms") or []]
for path in sorted(glob.glob("templates/*composite-alarm*.json")):
    doc = json.load(open(path))
    if doc.get("AlarmName", "").startswith("usms-") and doc["AlarmName"] not in deployed:
        log("%s: not deployed on this endpoint; reported from %s" % (doc["AlarmName"], path))
        report.append(composite(doc, False))

report.sort(key=lambda r: (r["type"] != "metric", r["alarm"]))
print(json.dumps(report, indent=2))
' "$HOURS"
