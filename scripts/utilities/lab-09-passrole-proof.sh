#!/usr/bin/env bash
# Lab 09 Step 8 - prove the PassRole scope and the boundary with IAM's own evaluator.
# Reads the LIVE default versions of USMSDeployBase and USMSPermissionsBoundary (not the files
# in policies/) and asks simulate-custom-policy for a decision: identity = USMSDeployBase,
# permissions boundary = USMSPermissionsBoundary, plus iam:PassedToService as context.
# Floci 2.2.0 evaluates conditions and boundaries in the simulator, although it enforces
# neither on real calls. Read-only.
#   ./scripts/utilities/lab-09-passrole-proof.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
ACCT=$(aws sts get-caller-identity --query Account --output text)

doc() {   # live default-version document of a customer managed policy, as a JSON string
  local arn ver
  arn=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text)
  ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json
}
DEPLOY="$(doc USMSDeployBase)"; BOUNDARY="$(doc USMSPermissionsBoundary)"

sim() {   # $1 label, $2 action, $3 resource, $4 passed-to service (optional)
  local extra=()
  [ -n "${4:-}" ] && extra=(--context-entries "ContextKeyName=iam:PassedToService,ContextKeyValues=$4,ContextKeyType=string")
  printf '  %-58s %s\n' "$1" "$(aws iam simulate-custom-policy --policy-input-list "$DEPLOY" \
      --permissions-boundary-policy-input-list "$BOUNDARY" --action-names "$2" --resource-arns "$3" ${extra[@]+"${extra[@]}"} \
      --query 'EvaluationResults[0].EvalDecision' --output text 2>&1)"
}

echo "simulate-custom-policy: identity USMSDeployBase, boundary USMSPermissionsBoundary"
sim "PassRole usms-ecs-task-role       -> ecs-tasks" iam:PassRole "arn:aws:iam::$ACCT:role/usms-ecs-task-role" ecs-tasks.amazonaws.com
sim "PassRole usms-ecs-task-role       -> ec2"       iam:PassRole "arn:aws:iam::$ACCT:role/usms-ecs-task-role" ec2.amazonaws.com
sim "PassRole usms-ec2-app-role (unlisted) -> ecs-tasks" iam:PassRole "arn:aws:iam::$ACCT:role/usms-ec2-app-role" ecs-tasks.amazonaws.com
sim "ecs:UpdateService (in both)"                  ecs:UpdateService "*"
sim "iam:AttachRolePolicy (boundary Deny)"         iam:AttachRolePolicy "*"
sim "ec2:RunInstances (in neither)"                ec2:RunInstances "*"
