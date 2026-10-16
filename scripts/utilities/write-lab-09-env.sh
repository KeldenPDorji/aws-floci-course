#!/usr/bin/env bash
# Generate configs/lab-09.env by LOOKUP (Lab 09 Step 19). Names, IDs and ARNs only.
# The guide's heredoc embeds a small loop with escaped \$ and backticks; here the one computed
# value (allow-all egress remaining) is worked out first, as the guide's "readable alternative"
# suggests, and then written in.
#   ./scripts/utilities/write-lab-09-env.sh            16 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

pol()  { aws iam list-policies --scope Local --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text; }
role() { aws iam get-role --role-name "$1" --query 'Role.Arn' --output text; }
sg()   { aws ec2 describe-security-groups --filters "Name=group-name,Values=$1" --query 'SecurityGroups[0].GroupId' --output text; }

REMAINING=0
for g in usms-alb-sg usms-enrolment-sg usms-db-sg; do
  n=$(aws ec2 describe-security-groups --group-ids "$(sg "$g")" \
        --query 'length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol==`"-1"`])' --output text)
  REMAINING=$((REMAINING + n))
done
PL=$(aws ec2 describe-prefix-lists --filters "Name=prefix-list-name,Values=com.amazonaws.${AWS_REGION_COURSE:-us-east-1}.s3" \
       --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null)
TODAY=$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')
NOW=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

# Unquoted heredoc: every $(...) runs NOW and its result lands in the file.
cat > configs/lab-09.env << EOF
# Lab 09 - security review outputs
# Generated on ${NOW}
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# DELIBERATELY ABSENT: the access key ID for usms-dev-01. An access key ID is not a
# secret, but recording one in a committed file is how a habit becomes a leak. The
# rotation DATE is here instead; the ID lives only in outputs/, which is git-ignored.
#
# Sourced alongside lab-01/02/03/04/05/06.

export USMS_POLICY_S3_RO=USMSStudentDataReadOnly
export USMS_POLICY_S3_RO_ARN=$(pol USMSStudentDataReadOnly)
export USMS_POLICY_DEPLOY=USMSDeployBase
export USMS_POLICY_DEPLOY_ARN=$(pol USMSDeployBase)
export USMS_POLICY_BOUNDARY=USMSPermissionsBoundary
export USMS_POLICY_BOUNDARY_ARN=$(pol USMSPermissionsBoundary)

export USMS_ROLE_TRANSCRIPTS_READER=usms-transcripts-reader-role
export USMS_ROLE_TRANSCRIPTS_READER_ARN=$(role usms-transcripts-reader-role)
export USMS_ROLE_DEPLOY=usms-deploy-role
export USMS_ROLE_DEPLOY_ARN=$(role usms-deploy-role)

export USMS_BASTION_SG=$(sg usms-bastion-sg)

export USMS_S3_PREFIX_LIST=${PL:-none}

export USMS_IMDS_TOKENS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text)

export USMS_DEV_KEY_ROTATED=$(aws iam list-access-keys --user-name usms-dev-01 \
  --query 'AccessKeyMetadata[0].CreateDate' --output text)

export USMS_EGRESS_ALLOW_ALL_REMAINING=${REMAINING}

export USMS_SEC_REVIEW_DATE=${TODAY}
EOF

# Exercise 5 Part 4: the draft bucket policy's path, once it has been generated.
DRAFT=outputs/lab-09-bucket-policy-draft.json
if [ -s "$DRAFT" ] && python3 -m json.tool "$DRAFT" >/dev/null 2>&1; then
  printf '\n# Exercise 5 - a git-ignored draft; Lab 10 validates it, the S3 configuration lab applies it\nexport USMS_BUCKET_POLICY_DRAFT=%s\n' "$DRAFT" >> configs/lab-09.env
fi

echo "configs/lab-09.env: $(grep -c '^export' configs/lab-09.env) exports"
