#!/usr/bin/env bash
# Rebuild the account-wide IAM snapshot that Step 26C asks for.
#
# WHY THIS EXISTS
#   The lab uses a single call:
#       aws iam get-account-authorization-details > outputs/lab-01-iam-snapshot.json
#   Floci 1.5.34 answers that with:
#       UnsupportedOperation: Operation GetAccountAuthorizationDetails is not supported.
#   That is an emulator gap, not a mistake in the lab. This script assembles an
#   equivalent document from the list-* calls Floci DOES support, keeping the
#   same top-level key names, so the Step 26D jq query still works unchanged:
#       jq '.UserDetailList[] | {UserName, Groups: .GroupList}' <snapshot>
#
# Read-only. Writes one file. Contains ARNs only, no secrets.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

OUT="$REPO_ROOT/outputs/lab-01-iam-snapshot.json"

# Each user is enriched with GroupList and its inline policy names, which is
# what get-account-authorization-details would have returned inline.
users="$(aws iam list-users | jq -c '.Users[]' | while read -r u; do
  name="$(printf '%s' "$u" | jq -r '.UserName')"
  groups="$(aws iam list-groups-for-user --user-name "$name" --query 'Groups[].GroupName' --output json)"
  inline="$(aws iam list-user-policies --user-name "$name" --query 'PolicyNames' --output json)"
  attached="$(aws iam list-attached-user-policies --user-name "$name" --query 'AttachedPolicies[].PolicyName' --output json)"
  printf '%s' "$u" | jq --argjson g "$groups" --argjson i "$inline" --argjson a "$attached" \
    '. + {GroupList: $g, UserPolicyList: $i, AttachedManagedPolicies: $a}'
done | jq -s '.')"

groups="$(aws iam list-groups | jq -c '.Groups[]' | while read -r g; do
  name="$(printf '%s' "$g" | jq -r '.GroupName')"
  attached="$(aws iam list-attached-group-policies --group-name "$name" --query 'AttachedPolicies[].PolicyName' --output json)"
  printf '%s' "$g" | jq --argjson a "$attached" '. + {AttachedManagedPolicies: $a}'
done | jq -s '.')"

roles="$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `usms-`)]' | jq -c '.[]' | while read -r r; do
  name="$(printf '%s' "$r" | jq -r '.RoleName')"
  attached="$(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyName' --output json)"
  printf '%s' "$r" | jq --argjson a "$attached" '. + {AttachedManagedPolicies: $a}'
done | jq -s '.')"

policies="$(aws iam list-policies --scope Local | jq '.Policies')"

jq -n \
  --argjson users "$users" \
  --argjson groups "$groups" \
  --argjson roles "$roles" \
  --argjson policies "$policies" \
  '{
     GeneratedBy: "scripts/utilities/iam-snapshot.sh",
     Note: "Equivalent of iam:GetAccountAuthorizationDetails, which Floci does not implement.",
     UserDetailList: $users,
     GroupDetailList: $groups,
     RoleDetailList: $roles,
     Policies: $policies
   }' > "$OUT"

printf '\033[1;32m[ok]\033[0m wrote %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')"
