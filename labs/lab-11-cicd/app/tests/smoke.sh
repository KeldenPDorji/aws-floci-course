#!/usr/bin/env bash
# Smoke tests for the USMS enrolment service artifact.
# Runs inside the build container, against the built output in ./dist.
set -uo pipefail

FAIL=0
t() {
  if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

echo "== smoke tests =="
t "dist/index.html exists"              "test -f dist/index.html"
t "dist/healthz.html exists"            "test -f dist/healthz.html"
t "release placeholder was replaced"    "! grep -q '__RELEASE__' dist/index.html"
t "build-time placeholder was replaced" "! grep -q '__BUILT_AT__' dist/index.html"
t "health endpoint says ok"             "grep -q '^ok$' dist/healthz.html"
t "build metadata is valid JSON"        "python3 -m json.tool dist/build-metadata.json"
# Exercise 3: parsed, not grepped, so a reformatted service.json cannot fail it.
t "container name matches the task def" "python3 -c 'import json,sys;sys.exit(json.load(open(\"config/service.json\")).get(\"container\")!=\"enrolment-api\")'"
# Exercise 5: one-entry JSON array whose name is the container in config/service.json.
t "imagedefinitions.json is a one-entry array for the container" "python3 -c 'import json,sys;d=json.load(open(\"dist/imagedefinitions.json\"));c=json.load(open(\"config/service.json\"))[\"container\"];sys.exit(not(isinstance(d,list) and len(d)==1 and d[0].get(\"name\")==c and d[0].get(\"imageUri\")))'"

echo "smoke tests failed: $FAIL"
[ "$FAIL" -eq 0 ]
