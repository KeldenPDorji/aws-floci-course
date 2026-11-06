#!/usr/bin/env bash
# Lab 11 Exercise 5 - write outputs/lab-11-lab08b-readiness.txt, which Lab 12 Step 1 reads
# as the inventory of what it inherits. Re-runnable; reads only (plus git-ignored outputs/).
#
# The guide expects the artifact key under usms-enrolment-pipeline/BuildOutput/. Floci 2.2.0
# never writes one (lab-11-report Section 6.2), so the file records the newest artifact from
# usms-enrolment-build-standalone - a real CodeBuild build of the same source key - and says
# so in a line Lab 12 cannot miss.
#   ./scripts/utilities/lab-11-readiness.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-11.env 2>/dev/null || true

BUCKET="${USMS_PIPELINE_BUCKET:-usms-pipeline-artifacts}"
PIPE="${USMS_PIPELINE_NAME:-usms-enrolment-pipeline}"
OUT=outputs/lab-11-lab08b-readiness.txt
ZIP=outputs/.lab-11-readiness.zip

PIPE_N=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PIPE/BuildOutput/" \
           --query 'length(Contents || `[]`)' --output text)
if [ "$PIPE_N" != 0 ]; then
  KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PIPE/BuildOutput/" \
          --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
  SOURCE_OF_ARTIFACT="pipeline BuildOutput"
else
  KEY=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix usms-enrolment-build-standalone- \
          --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
  SOURCE_OF_ARTIFACT="usms-enrolment-build-standalone (the pipeline stored no BuildOutput on this build)"
fi
aws s3api get-object --bucket "$BUCKET" --key "$KEY" "$ZIP" > /dev/null || { echo "cannot read $KEY" >&2; exit 1; }

EXEC=$(aws codepipeline list-pipeline-executions --pipeline-name "$PIPE" \
         --query 'pipelineExecutionSummaries[0].[pipelineExecutionId,status,sourceRevisions[0].revisionId]' --output text)

{
  echo "# Lab 11 Exercise 5 - what Lab 12 inherits"
  echo "# generated $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))') by scripts/utilities/lab-11-readiness.sh"
  echo
  echo "artifact bucket        $BUCKET"
  echo "artifact key           $KEY"
  echo "artifact produced by   $SOURCE_OF_ARTIFACT"
  python3 - "$ZIP" << 'PY'
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = sorted(z.namelist())
m = json.loads(z.read("build-metadata.json"))
print("artifact root          " + ", ".join(names))
print("imagedefinitions.json  at root: %s" % ("imagedefinitions.json" in names))
if "imagedefinitions.json" in names:
    d = json.loads(z.read("imagedefinitions.json"))
    print("  contents             " + json.dumps(d))
    print("  is a 1-entry array   %s" % (isinstance(d, list) and len(d) == 1))
print("release                %s   (buildId %s)" % (m["release"], m["buildId"]))
PY
  echo "container name         $(python3 -c 'import json;print(json.load(open("labs/lab-11-cicd/app/config/service.json"))["container"])')  (from config/service.json)"
  echo "ECS target             ${USMS_ECS_CLUSTER:-usms-ecs-cluster} / ${USMS_ENROLMENT_SERVICE:-usms-enrolment-svc}"
  echo "newest pipeline run    $EXEC"
  echo "pipeline BuildOutput   $PIPE_N object(s) under $PIPE/BuildOutput/"
  echo
  echo "FOR LAB 12 - Floci 2.2.0:"
  echo "  - a CODEPIPELINE build receives an EMPTY source directory, and no SourceOutput or"
  echo "    BuildOutput is stored, so a Deploy stage will have no imagedefinitions.json to read."
  echo "  - CodeBuild image aws/codebuild/standard:7.0 is a LOCAL stand-in"
  echo "    (labs/lab-11-cicd/codebuild-standin/Dockerfile); it has no docker CLI for 'docker build'."
  echo "  - buildspec 'finally' blocks are not executed."
} > "$OUT"
rm -f "$ZIP"
cat "$OUT"
