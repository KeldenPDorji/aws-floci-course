#!/usr/bin/env bash
# Lab 12 - a STAND-IN for CodePipeline's ECS deploy action, for Floci 2.2.0 only.
#
# Floci's pipeline stores a Deploy stage with provider ECS, then fails it at run time:
#   "Provider ECS is not available in Floci CodePipeline"
# and it never stores a BuildOutput anyway (Lab 11). This script does what the real action
# does (lab guide Section 5), no more:
#   1. read imagedefinitions.json from a BUILD ARTIFACT (a zip in the artifact store)
#   2. read the service's CURRENT task definition
#   3. replace the image of each container named in the file (by name, never by position)
#   4. register the result as a new revision, then update-service to it
# It never reads a task definition file from the repository - exactly like the real action.
#
#   ./scripts/utilities/usms-ecs-deploy-action.sh [artifact-key]
#   default artifact: the newest usms-enrolment-build-standalone-*.zip (a real CodeBuild build
#   of the same source key the pipeline fetched)
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

BUCKET=usms-pipeline-artifacts
CLUSTER=usms-ecs-cluster
SERVICE=usms-enrolment-svc
KEY="${1:-$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix usms-enrolment-build-standalone- \
              --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

aws s3api get-object --bucket "$BUCKET" --key "$KEY" "$WORK/art.zip" > /dev/null
CURRENT=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
            --query 'services[0].taskDefinition' --output text)
aws ecs describe-task-definition --task-definition "$CURRENT" --query 'taskDefinition' \
  --output json > "$WORK/current.json"

python3 - "$WORK" "$KEY" << 'PY'
import json, sys, zipfile
work, key = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(work + "/art.zip")
if "imagedefinitions.json" not in z.namelist():
    sys.exit("STOP - %s has no imagedefinitions.json at its root (has: %s)" % (key, z.namelist()))
defs = json.loads(z.read("imagedefinitions.json"))
if not isinstance(defs, list):
    sys.exit("STOP - imagedefinitions.json is a %s, not an array" % type(defs).__name__)
td = json.load(open(work + "/current.json"))
for f in ("taskDefinitionArn", "revision", "status", "requiresAttributes", "compatibilities",
          "registeredAt", "registeredBy", "deregisteredAt"):
    td.pop(f, None)
names = {c["name"]: c for c in td["containerDefinitions"]}
for d in defs:
    if d["name"] not in names:
        sys.exit("STOP - imagedefinitions names container %r; the task definition has %s"
                 % (d["name"], sorted(names)))
    print("artifact      : %s" % key)
    print("container     : %s" % d["name"])
    print("image before  : %s" % names[d["name"]]["image"])
    names[d["name"]]["image"] = d["imageUri"]
    print("image after   : %s" % d["imageUri"])
json.dump(td, open(work + "/next.json", "w"))
PY

NEW=$(aws ecs register-task-definition --cli-input-json "file://$WORK/next.json" \
        --query 'taskDefinition.taskDefinitionArn' --output text)
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW" \
  --query 'service.taskDefinition' --output text > /dev/null
printf 'task def before: %s\ntask def after : %s\n' "$CURRENT" "$NEW"
