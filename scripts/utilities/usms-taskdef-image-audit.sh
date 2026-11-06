#!/usr/bin/env bash
# Lab 12 Step 18 "Your turn" - how somebody notices, six months from now, a task definition
# revision that names an image which does not exist. Read-only.
#
# For every ACTIVE revision of a family, resolve each container image:
#   - in the account's ECR repository: is the tag (or digest) actually in the registry?
#   - anywhere else (Docker Hub, public ECR): reported as EXTERNAL, not checked
# Exit 1 if any ACTIVE revision names a missing image, so it can gate a deploy or a cron job.
#   ./scripts/utilities/usms-taskdef-image-audit.sh [family]      default usms-enrolment
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

FAMILY="${1:-usms-enrolment}"
REGISTRY=$(aws ecr describe-repositories --repository-names usms-enrolment \
             --query 'repositories[0].repositoryUri' --output text 2>/dev/null)
REGISTRY="${REGISTRY%%/*}"
MISSING=0

for ARN in $(aws ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE \
               --query 'taskDefinitionArns' --output text); do
  for IMG in $(aws ecs describe-task-definition --task-definition "$ARN" \
                 --query 'taskDefinition.containerDefinitions[].image' --output text); do
    REV="${ARN##*:}"
    case "$IMG" in
      "$REGISTRY"/*)
        REPO_AND_REF="${IMG#"$REGISTRY"/}"
        if [ "${REPO_AND_REF#*@}" != "$REPO_AND_REF" ]; then
          REPO="${REPO_AND_REF%%@*}"; ID="imageDigest=${REPO_AND_REF#*@}"
        else
          REPO="${REPO_AND_REF%%:*}"; ID="imageTag=${REPO_AND_REF##*:}"
        fi
        if aws ecr describe-images --repository-name "$REPO" --image-ids "$ID" >/dev/null 2>&1; then
          printf '  ok       %s:%-3s %s\n' "$FAMILY" "$REV" "$IMG"
        else
          printf '  MISSING  %s:%-3s %s\n' "$FAMILY" "$REV" "$IMG"; MISSING=$((MISSING+1))
        fi ;;
      *) printf '  EXTERNAL %s:%-3s %s\n' "$FAMILY" "$REV" "$IMG" ;;
    esac
  done
done
echo "ACTIVE revisions naming a missing image: $MISSING"
[ "$MISSING" -eq 0 ]
