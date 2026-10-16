#!/usr/bin/env bash
# Lab 09 Step 3 - what this Floci build supports for policy evaluation and rule management.
# Read-only. The guide's probe passes $USMS_ROLE_EC2 to --role-name; in this repository that
# variable holds an ARN, so role NAMES are derived with ${VAR##*/} here.
#   ./scripts/utilities/lab-09-probe.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-01 lab-03; do source "configs/$f.env"; done
EC2_ROLE_NAME="${USMS_ROLE_EC2##*/}"

probe() {
  printf '%-52s ' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "SUPPORTED"; else echo "not available"; fi
}

echo "floci: $(docker inspect floci --format '{{.Config.Image}}' 2>/dev/null)"
echo "== IAM: reading what exists =="
probe "iam list-roles"                        "aws iam list-roles --max-items 1"
probe "iam list-policies --scope Local"       "aws iam list-policies --scope Local --max-items 1"
probe "iam get-role"                          "aws iam get-role --role-name $EC2_ROLE_NAME"
probe "iam list-attached-role-policies"       "aws iam list-attached-role-policies --role-name $EC2_ROLE_NAME"
probe "iam get-account-authorization-details" "aws iam get-account-authorization-details --max-items 1"

echo "== IAM: changing what exists =="
probe "iam update-assume-role-policy (skel)"           "aws iam update-assume-role-policy --generate-cli-skeleton"
probe "iam create-role --permissions-boundary (skel)"  "aws iam create-role --generate-cli-skeleton"
probe "iam put-role-permissions-boundary (skel)"       "aws iam put-role-permissions-boundary --generate-cli-skeleton"

echo "== IAM: evaluating what exists =="
probe "iam simulate-principal-policy"             "aws iam simulate-principal-policy --policy-source-arn $USMS_ROLE_EC2 --action-names s3:GetObject"
probe "accessanalyzer list-analyzers"             "aws accessanalyzer list-analyzers"
probe "sts assume-role --policy (session policy)" "aws sts assume-role --generate-cli-skeleton"

echo "== IAM: credentials =="
probe "iam list-access-keys"          "aws iam list-access-keys --user-name $USMS_DEV_USER"
probe "iam get-access-key-last-used"  "aws iam get-access-key-last-used --access-key-id $(aws iam list-access-keys --user-name "$USMS_DEV_USER" --query 'AccessKeyMetadata[0].AccessKeyId' --output text)"
probe "iam get-credential-report"     "aws iam get-credential-report"

echo "== EC2: security group rules =="
probe "ec2 describe-security-group-rules"          "aws ec2 describe-security-group-rules --max-items 1"
probe "ec2 authorize-security-group-egress (skel)" "aws ec2 authorize-security-group-egress --generate-cli-skeleton"
probe "ec2 revoke-security-group-egress (skel)"    "aws ec2 revoke-security-group-egress --generate-cli-skeleton"
probe "ec2 describe-prefix-lists"                  "aws ec2 describe-prefix-lists"
probe "ec2 describe-network-interfaces"            "aws ec2 describe-network-interfaces --max-items 1"

echo "== EC2: instance metadata options =="
probe "ec2 modify-instance-metadata-options (skel)" "aws ec2 modify-instance-metadata-options --generate-cli-skeleton"
probe "ec2 describe-instances MetadataOptions" \
  "aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE --query 'Reservations[0].Instances[0].MetadataOptions'"

echo "== Does the simulator really evaluate? =="
aws iam simulate-principal-policy --policy-source-arn "$USMS_ROLE_DEVELOPER" \
  --action-names ec2:DescribeVpcs iam:CreateUser ecs:ListClusters \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text 2>&1 | sed 's/^/  /'
