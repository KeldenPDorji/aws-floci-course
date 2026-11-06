#!/usr/bin/env bash
# Lab 12 Exercise 4 - what a compromised usms-codepipeline-role could do, in IAM's own words.
# Uses simulate-principal-policy against the LIVE role (its default policy version), so the
# answers follow the policy actually attached, not a file. Read-only.
#
# Arguments are built in an array: an optional "--context-entries X" written as one
# ${4:+...} expansion is a single word under zsh, the CLI then sees no context, and every
# conditioned PassRole wrongly reads implicitDeny (found the hard way, Lab 12).
#   ./scripts/utilities/lab-12-pipeline-role-simulate.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env

ACCT=000000000000
sim() {   # principal action resource [passed-to-service]
  local args=(--policy-source-arn "arn:aws:iam::$ACCT:role/$1" --action-names "$2" --resource-arns "$3")
  [ -n "${4:-}" ] && args+=(--context-entries "ContextKeyName=iam:PassedToService,ContextKeyValues=$4,ContextKeyType=string")
  aws iam simulate-principal-policy "${args[@]}" --query 'EvaluationResults[0].EvalDecision' --output text
}
row() { printf '  %-60s %s\n' "$1" "$2"; }
P=usms-codepipeline-role
SVC="arn:aws:ecs:us-east-1:$ACCT:service/usms-ecs-cluster"

echo "usms-codepipeline-role, default version $(aws iam get-policy --policy-arn arn:aws:iam::$ACCT:policy/USMSCodePipelineBase --query Policy.DefaultVersionId --output text) of USMSCodePipelineBase"
echo "-- the attack path"
row "ecs:RegisterTaskDefinition (any content, any family)" "$(sim $P ecs:RegisterTaskDefinition '*')"
row "iam:PassRole usms-ecs-task-role -> ecs-tasks.amazonaws.com" "$(sim $P iam:PassRole arn:aws:iam::$ACCT:role/usms-ecs-task-role ecs-tasks.amazonaws.com)"
row "ecs:UpdateService usms-enrolment-svc" "$(sim $P ecs:UpdateService "$SVC/usms-enrolment-svc")"
echo "-- the bounds that hold"
row "ecs:UpdateService any other service" "$(sim $P ecs:UpdateService "$SVC/other-svc")"
row "ecs:RunTask (a one-off task)" "$(sim $P ecs:RunTask '*')"
row "iam:PassRole usms-ecs-task-role -> ec2.amazonaws.com" "$(sim $P iam:PassRole arn:aws:iam::$ACCT:role/usms-ecs-task-role ec2.amazonaws.com)"
row "iam:PassRole usms-deploy-role -> ecs-tasks.amazonaws.com" "$(sim $P iam:PassRole arn:aws:iam::$ACCT:role/usms-deploy-role ecs-tasks.amazonaws.com)"
row "s3:GetObject usms-student-data/* (the pipeline role itself)" "$(sim $P s3:GetObject 'arn:aws:s3:::usms-student-data/x')"
echo "-- what the task role it CAN pass may do"
row "usms-ecs-task-role s3:GetObject usms-student-data/*" "$(sim usms-ecs-task-role s3:GetObject 'arn:aws:s3:::usms-student-data/x')"
row "usms-ecs-task-role s3:PutObject usms-student-data/*" "$(sim usms-ecs-task-role s3:PutObject 'arn:aws:s3:::usms-student-data/x')"
row "usms-ecs-task-role s3:DeleteObject usms-student-data/*" "$(sim usms-ecs-task-role s3:DeleteObject 'arn:aws:s3:::usms-student-data/x')"
echo "-- what the execution role may pull"
row "usms-ecs-exec-role ecr:BatchGetImage on ANY repository" "$(sim usms-ecs-exec-role ecr:BatchGetImage "arn:aws:ecr:us-east-1:$ACCT:repository/anything")"
