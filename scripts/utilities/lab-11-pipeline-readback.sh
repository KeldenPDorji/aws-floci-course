#!/usr/bin/env bash
# Lab 11 Step 19 - "prove the pipeline consumed your source", on Floci 2.2.0.
#
# The guide reads the release out of the newest object under
# usms-enrolment-pipeline/BuildOutput/. Floci 2.2.0 never writes one: its pipeline runs the
# Source and Build actions, but hands CodeBuild an EMPTY source directory and stores no
# SourceOutput or BuildOutput (lab-11-report Section 6.2). So the chain is rebuilt from what
# Floci does record, one link per line:
#   1. the execution's status, and the S3 version ID its Source action fetched
#   2. that EXACT object version, downloaded by version ID, and the release inside it
#   3. whether any pipeline artifact exists in the store (none, on this build)
#   4. the newest artifact from usms-enrolment-build-standalone - a real CodeBuild build of
#      the same key - with its release and CodeBuild build ID
# Read-only, apart from git-ignored files in outputs/.
#   ./scripts/utilities/lab-11-pipeline-readback.sh [execution-id]    default: the newest
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

PIPE=usms-enrolment-pipeline
BUCKET=usms-pipeline-artifacts
KEY=source/usms-enrolment-src.zip

EXEC="${1:-$(aws codepipeline list-pipeline-executions --pipeline-name "$PIPE" \
         --query 'pipelineExecutionSummaries[0].pipelineExecutionId' --output text)}"
STATUS=$(aws codepipeline get-pipeline-execution --pipeline-name "$PIPE" \
           --pipeline-execution-id "$EXEC" --query 'pipelineExecution.status' --output text)
aws codepipeline list-action-executions --pipeline-name "$PIPE" \
  --filter "pipelineExecutionId=$EXEC" --output json > outputs/.lab-11-actions.json
read -r SRC_VID BUILD_ID < <(python3 -c '
import json
d = {a["actionName"]: a for a in json.load(open("outputs/.lab-11-actions.json"))["actionExecutionDetails"]}
ext = lambda n: ((d.get(n) or {}).get("output") or {}).get("executionResult", {}).get("externalExecutionId", "-")
print(ext("FetchSource"), ext("BuildArtifact"))')
rm -f outputs/.lab-11-actions.json

printf '1 execution   %s  %s\n' "$EXEC" "$STATUS"
printf '  Source      fetched S3 version %s\n' "$SRC_VID"
printf '  Build       ran %s\n' "$BUILD_ID"

if aws s3api get-object --bucket "$BUCKET" --key "$KEY" --version-id "$SRC_VID" \
     outputs/lab-11-consumed-source.zip > /dev/null 2>&1; then
  REL=$(python3 -c 'import zipfile;print(zipfile.ZipFile("outputs/lab-11-consumed-source.zip").read("VERSION").decode().strip())')
  printf '2 that version contains VERSION=%s\n' "$REL"
else
  printf '2 could not download %s version %s\n' "$KEY" "$SRC_VID"
fi

N=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PIPE/" --query 'length(Contents || `[]`)' --output text)
printf '3 objects under %s/ in the artifact store: %s\n' "$PIPE" "$N"

ART=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix usms-enrolment-build-standalone- \
        --query 'sort_by(Contents, &LastModified)[-1].Key' --output text 2>/dev/null)
if [ -n "$ART" ] && [ "$ART" != None ] && \
   aws s3api get-object --bucket "$BUCKET" --key "$ART" outputs/lab-11-buildoutput.zip > /dev/null 2>&1; then
  python3 - "$ART" << 'PY'
import json, sys, zipfile
z = zipfile.ZipFile("outputs/lab-11-buildoutput.zip")
m = json.loads(z.read("build-metadata.json"))
print("4 standalone artifact %s: %s" % (sys.argv[1], ", ".join(sorted(z.namelist()))))
print("  release=%s  buildId=%s  builtAt=%s" % (m["release"], m["buildId"], m["builtAt"]))
PY
else
  printf '4 no usms-enrolment-build-standalone artifact yet\n'
fi
