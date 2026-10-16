#!/usr/bin/env bash
# Lab 09 Step 18 - the nine controls that must survive a Floci restart.
# Every identifier is RE-DERIVED from the API (security groups by group name, the web
# instance by its Name tag), so the comparison proves the account remembers, not the shell.
#   ./scripts/utilities/lab-09-restart-facts.sh > outputs/lab-09-pre-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

sg() { aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId' --output text; }
ALB=$(sg usms-alb-sg); ENR=$(sg usms-enrolment-sg); DBSG=$(sg usms-db-sg); APP=$(sg usms-app-sg)
WEB=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text)

f() { printf '%-52s %s\n' "$1" "$2"; }
f "usms-ecs-task-role trust condition keys"       "$(aws iam get-role --role-name usms-ecs-task-role --query 'length(Role.AssumeRolePolicyDocument.Statement[0].Condition)' --output text 2>&1)"
f "usms-deploy-role permissions boundary"         "$(aws iam get-role --role-name usms-deploy-role --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text 2>&1)"
f "usms-transcripts-reader-role"                  "$(aws iam get-role --role-name usms-transcripts-reader-role --query 'Role.RoleName' --output text 2>&1)"
f "  its policy"                                  "$(aws iam list-attached-role-policies --role-name usms-transcripts-reader-role --query 'AttachedPolicies[0].PolicyName' --output text 2>&1)"
f "usms-dev-01 access keys"                       "$(aws iam list-access-keys --user-name usms-dev-01 --query 'length(AccessKeyMetadata)' --output text 2>&1)"
f "usms-alb-sg ($ALB) allow-all egress"           "$(aws ec2 describe-security-groups --group-ids "$ALB" --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`"-1"`])' --output text)"
f "usms-enrolment-sg ($ENR) allow-all egress"     "$(aws ec2 describe-security-groups --group-ids "$ENR" --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`"-1"`])' --output text)"
f "usms-db-sg ($DBSG) allow-all egress"           "$(aws ec2 describe-security-groups --group-ids "$DBSG" --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`"-1"`])' --output text)"
f "usms-app-sg ($APP) CIDR sources on tcp/22"     "$(aws ec2 describe-security-groups --group-ids "$APP" --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[])' --output text)"
f "usms-web-01 ($WEB) HttpTokens"                 "$(aws ec2 describe-instances --instance-ids "$WEB" --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)"
