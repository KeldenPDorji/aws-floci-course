#!/usr/bin/env bash
# Lab 10 Step 22 - the guide's inventory() function, moved into a script so the
# pre- and post-restart readings run the same queries from any terminal.
# Every value is read from the API; nothing comes from shell variables.
#   ./scripts/utilities/lab-10-restart-facts.sh > outputs/lab-10-pre-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env 2>/dev/null || true
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

aws lambda list-functions \
  --query 'sort_by(Functions[?starts_with(FunctionName, `usms-`)], &FunctionName)[].[FunctionName,Runtime,MemorySize]' \
  --output text
# \$LATEST is escaped so the shell leaves it for JMESPath.
aws lambda list-versions-by-function --function-name usms-edge-viewer-request \
  --query "sort_by(Versions[?Version!='\$LATEST'], &Version)[].Version" --output text
aws lambda list-aliases --function-name usms-transcript-notifier \
  --query 'Aliases[].[Name,FunctionVersion]' --output text
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --query 'sort_by(Contents, &Key)[].Key' --output text | tr '\t' '\n'
aws s3api get-bucket-notification-configuration --bucket "$BUCKET" \
  --query 'LambdaFunctionConfigurations[].Id' --output text
aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(Comment, 'usms-transcript-cdn')].[Id,Status]" --output text
