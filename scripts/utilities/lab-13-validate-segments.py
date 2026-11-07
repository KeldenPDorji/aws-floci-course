#!/usr/bin/env python3
"""Lab 13 Step 16 - structural validation of the three X-Ray segment documents.

The guide's fallback for a build where X-Ray cannot be read back. On Floci 2.2.0 there is no
X-Ray at all (put-trace-segments: UnknownOperationException), so these ten checks are the only
evidence the documents are well formed and consistent - which is all that can honestly be
claimed without the service.
  python3 scripts/utilities/lab-13-validate-segments.py | tee outputs/lab-13-trace-summaries.json
"""
import json
import re
import sys

checks, errors = [], []


def check(label, ok):
    checks.append(("ok  " if ok else "FAIL") + "  " + label)
    if not ok:
        errors.append(label)


docs = {name: json.load(open("templates/lab-13-segment-%s.json" % name))
        for name in ("parent", "subsegments", "downstream")}

tid = docs["parent"]["trace_id"]
check("trace id matches 1-<8hex>-<24hex>", bool(re.fullmatch(r"1-[0-9a-f]{8}-[0-9a-f]{24}", tid)))
check("all three documents share one trace id",
      all(d["trace_id"] == tid for d in docs.values()))
check("every id is 16 hex characters",
      all(re.fullmatch(r"[0-9a-f]{16}", d["id"]) for d in docs.values()))
check("parent and subsegment documents share one segment id",
      docs["parent"]["id"] == docs["subsegments"]["id"])
check("downstream names the parent segment",
      docs["downstream"].get("parent_id") == docs["parent"]["id"])
check("every end_time is after its start_time",
      all(d["end_time"] > d["start_time"] for d in docs.values()))
check("three subsegments declared", len(docs["subsegments"]["subsegments"]) == 3)
check("every subsegment fits inside its parent's window",
      all(docs["subsegments"]["start_time"] <= s["start_time"]
          and s["end_time"] <= docs["subsegments"]["end_time"]
          for s in docs["subsegments"]["subsegments"]))
check("annotations hold only string, number or boolean",
      all(isinstance(v, (str, int, float, bool))
          for d in docs.values() for v in d.get("annotations", {}).values()))
check("downstream carries an http status", "status" in docs["downstream"]["http"]["response"])

print(json.dumps({"mode": "structural validation only - X-Ray not available on this build",
                  "trace_id": tid, "checks": checks, "errors": errors}, indent=2))
sys.exit(1 if errors else 0)
