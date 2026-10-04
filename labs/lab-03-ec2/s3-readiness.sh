#!/usr/bin/env bash
# Lab 03 Exercise 5 - record the EC2 side of the S3 permission chain for Lab 04,
# and write it to outputs/lab-03-s3-readiness.txt.
#
# No -e on purpose: head-bucket is EXPECTED to fail today, and its error code is
# the evidence. It is captured, not hidden.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env

OUT=outputs/lab-03-s3-readiness.txt
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

profile_arn=$(aws ec2 describe-instances --instance-ids "$USMS_WEB_INSTANCE" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
role=$(aws iam get-instance-profile --instance-profile-name "${profile_arn##*/}" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
policy_arn=$(aws iam list-attached-role-policies --role-name "$role" \
  --query 'AttachedPolicies[?PolicyName==`USMSStudentDataReadWrite`].PolicyArn | [0]' --output text)
version=$(aws iam get-policy --policy-arn "$policy_arn" \
  --query 'Policy.DefaultVersionId' --output text)
bucket_arns=$(aws iam get-policy-version --policy-arn "$policy_arn" --version-id "$version" \
  --query 'PolicyVersion.Document' --output json \
  | jq -r 'if type == "string" then fromjson else . end
           | [.Statement[] | .Resource] | flatten | unique | .[]')
egress=$(aws ec2 describe-security-groups --group-ids "$USMS_APP_SG" \
  --query 'SecurityGroups[0].IpPermissionsEgress[].[IpProtocol, IpRanges[0].CidrIp]' --output text)

head_out=$(aws s3api head-bucket --bucket "$BUCKET" 2>&1)
head_rc=$?

{
  echo "# Lab 03 -> Lab 04 S3 readiness"
  echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "instance            : $USMS_WEB_INSTANCE (usms-web-01)"
  echo "instance profile    : $profile_arn"
  echo "role                : $role"
  echo "attached policy     : ${policy_arn##*/} ($policy_arn, default $version)"
  echo "resources in policy :"
  printf '                      %s\n' $bucket_arns
  echo "usms-app-sg egress  : $(echo "$egress" | tr '\t\n' ' ;')"
  echo
  echo "head-bucket --bucket $BUCKET"
  echo "  exit code : $head_rc"
  echo "  output    : ${head_out:-<none>}"
  echo
  echo "# Prediction for Lab 04"
  echo "# The chain instance -> profile -> role -> policy is complete; only the object"
  echo "# at arn:aws:s3:::$BUCKET is missing. When Lab 04 runs create-bucket, the same"
  echo "# head-bucket call returns exit 0, and usms-web-01 can Get/Put/List under it with"
  echo "# no change to IAM, to the instance, or to this file's first six lines."
} > "$OUT"

cat "$OUT"
