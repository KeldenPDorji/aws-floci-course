#!/usr/bin/env bash
# Lab 13 Step 23, path B - "USMS_EVENT lines per faculty" without Logs Insights.
# Floci 2.2.0 has no start-query, so: retrieve with filter-log-events, parse and aggregate
# locally. Correct and portable; every event crosses the network, and it would not scale
# past a few thousand events - which is the case for Insights, not against it. Read-only.
#   ./scripts/utilities/lab-13-faculty-counts.sh [log-group]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

GROUP="${1:-/usms/central/application}"
aws logs filter-log-events --log-group-name "$GROUP" --filter-pattern 'USMS_EVENT' \
  --query 'events[].message' --output json \
  | python3 -c '
import collections, json, sys
counts = collections.Counter()
decoder = json.JSONDecoder()
for msg in json.load(sys.stdin):
    _, _, body = msg.partition("USMS_EVENT ")
    try:
        # raw_decode stops at the end of the object: since Exercise 1 the emitter appends
        # the seconds as a trailing token, which a strict json.loads rejects as "Extra data".
        payload, _ = decoder.raw_decode(body)
    except json.JSONDecodeError:
        continue
    counts[payload.get("faculty", "unknown")] += 1
for faculty, n in counts.most_common():
    print("%-14s %d" % (faculty, n))
'
