#!/usr/bin/env bash
# Lab 12 Exercise 5 - trace a release from the source byte to the running service, using only
# command output. Each link is printed as the command, then its output, in Markdown.
#   ./scripts/utilities/lab-12-release-evidence.sh <release> <pipeline-execution-id> <heading>
# Appends to outputs/lab-12-release-evidence.md (git-ignored). Read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

REL="${1:?release, e.g. r7}"; EXEC="${2:?pipeline execution id}"; HEAD="${3:?section heading}"
OUT=outputs/lab-12-release-evidence.md
PIPE=usms-enrolment-pipeline; BUCKET=usms-pipeline-artifacts; KEY=source/usms-enrolment-src.zip
CLUSTER=usms-ecs-cluster; SERVICE=usms-enrolment-svc

link() {   # title, then the command as words
  local title="$1"; shift
  printf '\n**%s**\n\n```text\n$ %s\n' "$title" "$*" >> "$OUT"
  "$@" >> "$OUT" 2>&1
  printf '```\n' >> "$OUT"
}

printf '\n## %s\n\nRecorded %s.\n' "$HEAD" "$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')" >> "$OUT"

SRCV=$(aws codepipeline get-pipeline-execution --pipeline-name "$PIPE" --pipeline-execution-id "$EXEC" \
         --query 'pipelineExecution.artifactRevisions[0].revisionId' --output text)
link "1. The pipeline execution, and the S3 version ID of the source archive it fetched" \
  aws codepipeline get-pipeline-execution --pipeline-name "$PIPE" --pipeline-execution-id "$EXEC" \
  --query 'pipelineExecution.[pipelineExecutionId,status,artifactRevisions[0].revisionId,artifactRevisions[0].revisionSummary]' --output text
aws s3api get-object --bucket "$BUCKET" --key "$KEY" --version-id "$SRCV" outputs/.evidence-src.zip > /dev/null
link "2. That exact source version contains this release" \
  unzip -p outputs/.evidence-src.zip VERSION
link "3. What each stage did in that execution (Floci 2.2.0: Deploy has no ECS provider)" \
  aws codepipeline list-action-executions --pipeline-name "$PIPE" --filter "pipelineExecutionId=$EXEC" \
  --query 'actionExecutionDetails[].[stageName,status,output.executionResult.externalExecutionId]' --output text
ART=$(sed -n 's/^artifact *: \([^ ]*\).*/\1/p' outputs/lab-12-deploy-evidence.txt)
aws s3api get-object --bucket "$BUCKET" --key "$ART" outputs/.evidence-art.zip > /dev/null
link "4. The build that produced the deployable artifact ($ART), and what it says" \
  unzip -p outputs/.evidence-art.zip build-metadata.json imagedefinitions.json
link "5. The image digest the tag $REL resolves to in the registry NOW" \
  aws ecr describe-images --repository-name usms-enrolment --image-ids "imageTag=$REL" \
  --query 'imageDetails[0].[imageTags[0],imageDigest,imagePushedAt]' --output text
TD=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].taskDefinition' --output text)
link "6. The service's current task definition, and the image reference it names" \
  aws ecs describe-task-definition --task-definition "$TD" \
  --query 'taskDefinition.[taskDefinitionArn,containerDefinitions[0].image]' --output text
TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns' --output text)
# shellcheck disable=SC2086
link "7. The digest each RUNNING task actually pulled (recorded by ECS at task start)" \
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
  --query 'tasks[].[taskArn,containers[0].imageDigest,lastStatus]' --output text
rm -f outputs/.evidence-src.zip outputs/.evidence-art.zip
echo "appended '$HEAD' to $OUT"
