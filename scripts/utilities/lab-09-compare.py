#!/usr/bin/env python3
"""Lab 09 before/after comparisons, so the verdict is computed rather than eyeballed.

  python3 scripts/utilities/lab-09-compare.py trust BEFORE.json AFTER.json   Step 7 Part 6
      -> SAME PRINCIPAL, NEW CONDITION   when only the Condition changed
  python3 scripts/utilities/lab-09-compare.py imds BEFORE.json AFTER.json    Step 11 Part 3
      -> IMDSv2 REQUIRED, HOP LIMIT 1
"""
import json
import sys


def statements(doc):
    sts = doc.get("Statement")
    return sts if isinstance(sts, list) else [sts]


def trust(before, after):
    b = [(json.dumps(s.get("Principal"), sort_keys=True), bool(s.get("Condition"))) for s in statements(before)]
    a = [(json.dumps(s.get("Principal"), sort_keys=True), bool(s.get("Condition"))) for s in statements(after)]
    print("before:", b)
    print("after :", a)
    same_principal = [p for p, _ in b] == [p for p, _ in a]
    gained = all(c for _, c in a) and not all(c for _, c in b)
    print()
    print("SAME PRINCIPAL, NEW CONDITION" if (same_principal and gained)
          else "CHECK THIS BY HAND - the principal changed, or no condition was added")


def imds(before, after):
    before, after = before or {}, after or {}
    print(f"HttpTokens   : {before.get('HttpTokens', '?')}  ->  {after.get('HttpTokens', '?')}")
    print(f"HopLimit     : {before.get('HttpPutResponseHopLimit', '?')}  ->  {after.get('HttpPutResponseHopLimit', '?')}")
    print(f"HttpEndpoint : {before.get('HttpEndpoint', '?')}  ->  {after.get('HttpEndpoint', '?')}")
    ok = after.get("HttpTokens") == "required" and after.get("HttpPutResponseHopLimit") == 1
    print()
    print("IMDSv2 REQUIRED, HOP LIMIT 1" if ok else
          "NOT APPLIED - record this as a Floci limitation and say what real AWS would have done")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("trust", "imds"):
        sys.exit(__doc__)
    {"trust": trust, "imds": imds}[sys.argv[1]](json.load(open(sys.argv[2])), json.load(open(sys.argv[3])))
