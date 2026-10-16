#!/usr/bin/env bash
# END OF COURSE ONLY. Reverses Lab 09, dependencies first.
# Order: detach and delete roles -> delete policies -> restore the rules this lab changed.
# Run FIRST of the teardown scripts (before lab-08-cleanup.sh and lab-06-cleanup.sh).
# Revokes use --ip-permissions: on Floci 2.2.0 a revoke by --security-group-rule-ids returns
# True and removes nothing.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-09.env"

cat <<'WARN'
============================================================
  This DELETES the Lab 09 roles and policies, and RESTORES
  the allow-all egress rule on three security groups plus
  the 10.0.0.0/16 SSH rule on usms-app-sg.

  It does NOT undo the access key rotation (the old key is
  gone and cannot come back) and it does NOT undo the IMDSv2
  requirement, because neither of those should ever be undone.
  It does NOT revert usms-ecs-task-role's scoped trust policy.

  Run this FIRST, before lab-08-cleanup.sh and lab-06-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: UNDO USMS SECURITY REVIEW  > ' answer
[ "$answer" = "UNDO USMS SECURITY REVIEW" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "detach policies from the Lab 09 roles"
for r in usms-deploy-role usms-transcripts-reader-role; do
  for p in $(aws iam list-attached-role-policies --role-name "$r" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p" || true
  done
done

say "remove the permissions boundary before deleting the role that wears it"
aws iam delete-role-permissions-boundary --role-name usms-deploy-role || true

say "delete the Lab 09 roles"
aws iam delete-role --role-name usms-deploy-role || true
aws iam delete-role --role-name usms-transcripts-reader-role || true

say "delete the Lab 09 policies (a policy with attachments refuses to be deleted)"
for p in USMSStudentDataReadOnly USMSDeployBase USMSPermissionsBoundary; do
  arn=$(aws iam list-policies --scope Local \
          --query "Policies[?PolicyName=='$p'].Arn | [0]" --output text 2>/dev/null || echo None)
  [ "$arn" = "None" ] && continue
  for v in $(aws iam list-policy-versions --policy-arn "$arn" \
               --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" || true
  done
  aws iam delete-policy --policy-arn "$arn" || true
done

say "restore allow-all egress, so a later teardown is not debugged blind"
for g in "${USMS_ALB_SG:-None}" "${USMS_ENROLMENT_SG:-None}" "${USMS_DB_SG:-None}"; do
  [ "$g" = "None" ] && continue
  aws ec2 authorize-security-group-egress \
    --group-id "$g" \
    --ip-permissions file://policies/usms-egress-allow-all.json >/dev/null 2>&1 || true
done

say "restore the Lab 02 SSH rule on usms-app-sg, then drop the rule naming the bastion group"
aws ec2 authorize-security-group-ingress \
  --group-id "$USMS_APP_SG" --protocol tcp --port 22 --cidr 10.0.0.0/16 >/dev/null 2>&1 || true
aws ec2 revoke-security-group-ingress \
  --group-id "$USMS_APP_SG" --ip-permissions file://policies/usms-app-sg-ssh-bastion.json >/dev/null 2>&1 || true

say "usms-bastion-sg is KEPT: it came from Lab 02 Exercise 2, so lab-02-cleanup.sh owns it"

echo
echo "Lab 09 teardown complete. The next cleanup script in the order may now run."
