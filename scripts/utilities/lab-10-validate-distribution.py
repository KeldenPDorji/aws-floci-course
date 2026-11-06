#!/usr/bin/env python3
"""Lab 10 Step 15 - structural validation of the CloudFront distribution config.

The guide's Path B check, kept on Path A too: Floci 2.2.0 creates a distribution even
when an association names $LATEST, so these eleven checks are the only validation the
associations get on this build.
  python3 scripts/utilities/lab-10-validate-distribution.py [config.json]
"""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "templates/lab-10-distribution-config.json"
cfg = json.load(open(path))
errors, checks = [], []


def check(label, ok):
    checks.append(("ok  " if ok else "FAIL") + "  " + label)
    if not ok:
        errors.append(label)


beh = cfg["DefaultCacheBehavior"]
assoc = beh["LambdaFunctionAssociations"]
items = assoc["Items"]
origin = cfg["Origins"]["Items"][0]

check("one origin declared", cfg["Origins"]["Quantity"] == 1)
check("origin id matches the behaviour target", origin["Id"] == beh["TargetOriginId"])
check("origin is the USMS bucket", origin["DomainName"].startswith("usms-student-data"))
check("association quantity matches item count", assoc["Quantity"] == len(items))
check("two trigger points associated", len(items) == 2)
check("trigger points are viewer-request and origin-response",
      sorted(i["EventType"] for i in items) == ["origin-response", "viewer-request"])
check("every ARN is version-qualified",
      all(i["LambdaFunctionARN"].rsplit(":", 1)[-1].isdigit() for i in items))
check("IncludeBody only on a request trigger",
      all("IncludeBody" not in i for i in items if i["EventType"].endswith("response")))
check("viewer protocol policy is not allow-all", beh["ViewerProtocolPolicy"] != "allow-all")
check("cache key forwards no cookies", beh["ForwardedValues"]["Cookies"]["Forward"] == "none")
check("cache key forwards exactly one header", beh["ForwardedValues"]["Headers"]["Quantity"] == 1)

print(json.dumps({"mode": "structural validation of " + path, "checks": checks, "errors": errors}, indent=2))
sys.exit(1 if errors else 0)
