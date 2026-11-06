#!/usr/bin/env bash
# Lab 12 Step 10 - describe, strip, register: derive a task definition revision that
# differs from the family's latest in ONE field, the enrolment-api container's image.
# The guide's inline Python, in a script, with the image taken from ECR by tag (never typed).
#   ./scripts/utilities/lab-12-derive-taskdef.sh <tag> [--register]
# Writes templates/lab-12-taskdef-base.json (live snapshot, git-ignored by intent - see the
# report) and templates/lab-12-taskdef-v3.json; registers it only with --register.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

TAG="${1:?usage: $0 <tag> [--register]}"
ECR_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
            --query 'repositories[0].repositoryUri' --output text)
aws ecr describe-images --repository-name usms-enrolment --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' --output text | grep -q '^sha256:' \
  || { echo "STOP - tag $TAG is not in usms-enrolment" >&2; exit 1; }

aws ecs describe-task-definition --task-definition usms-enrolment \
  --query 'taskDefinition' --output json > templates/lab-12-taskdef-base.json

python3 - "$ECR_URI:$TAG" << 'PY'
import json, sys

new_image = sys.argv[1]
READ_ONLY = ("taskDefinitionArn", "revision", "status", "requiresAttributes",
             "compatibilities", "registeredAt", "registeredBy", "deregisteredAt")

td = json.load(open("templates/lab-12-taskdef-base.json"))
for field in READ_ONLY:
    td.pop(field, None)

found = False
for c in td["containerDefinitions"]:
    if c["name"] == "enrolment-api":
        print("old image:", c["image"])
        c["image"] = new_image
        print("new image:", c["image"])
        found = True
if not found:
    sys.exit("no container named enrolment-api in this task definition - stop and check Lab 04")

json.dump(td, open("templates/lab-12-taskdef-v3.json", "w"), indent=2)
print("wrote templates/lab-12-taskdef-v3.json")
PY

python3 -m json.tool templates/lab-12-taskdef-v3.json > /dev/null && echo "valid JSON, $(grep -c '\$' templates/lab-12-taskdef-v3.json) unexpanded \$"

if [ "${2:-}" = "--register" ]; then
  aws ecs register-task-definition --cli-input-json file://templates/lab-12-taskdef-v3.json \
    --query 'taskDefinition.taskDefinitionArn' --output text
fi
