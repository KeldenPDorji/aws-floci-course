#!/usr/bin/env bash
# Lab 10 Exercise 5 - hand the S3 configuration lab a bucket it can start from.
# Re-runnable and read-only (it applies nothing; the bucket policy draft stays a draft).
#   1. uses outputs/lab-09-bucket-policy-draft.json, or generates one with Lab 09's script
#   2. validates it: every bucket ARN must be this bucket, every principal an existing role
#      (or this account's root). Mismatches are REPORTED, never fixed.
#   3. writes outputs/lab-10-s3-readiness.txt (git-ignored)
#   ./scripts/utilities/lab-10-s3-readiness.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env 2>/dev/null || true
source configs/lab-10.env 2>/dev/null || true

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
DRAFT="${USMS_DRAFT:-outputs/lab-09-bucket-policy-draft.json}"   # override only to test the validator
OUT=outputs/lab-10-s3-readiness.txt
ACCT=$(aws sts get-caller-identity --query Account --output text)

# --- 1. the draft: use it if present, otherwise generate the equivalent -----------
for candidate in "$DRAFT"; do [ -s "$candidate" ] && { DRAFT_SOURCE="existing (Lab 09 Exercise 5)"; break; }; done
if [ -z "${DRAFT_SOURCE:-}" ]; then
  ./scripts/utilities/usms-bucket-policy-draft.sh > /dev/null 2>&1
  DRAFT_SOURCE="generated now by usms-bucket-policy-draft.sh"
fi
[ -s "$DRAFT" ] || { echo "no draft at $DRAFT and generation failed" >&2; exit 1; }

# --- 2. validate --------------------------------------------------------------------
aws iam list-roles --query 'Roles[].Arn' --output text | tr '\t' '\n' > outputs/.lab-10-roles.txt
VALIDATION=$(python3 - "$DRAFT" "$BUCKET" "$ACCT" outputs/.lab-10-roles.txt << 'PY'
import json, sys
draft, bucket, acct, roles_file = sys.argv[1:]
roles = set(open(roles_file).read().split())
doc = json.load(open(draft))
as_list = lambda x: x if isinstance(x, list) else [x]
bucket_arn = "arn:aws:s3:::" + bucket
problems, principals, resources = [], set(), set()
for st in doc["Statement"]:
    for r in as_list(st.get("Resource", [])):
        resources.add(r)
        if not (r == bucket_arn or r.startswith(bucket_arn + "/")):
            problems.append("%s: resource %s is not this bucket" % (st.get("Sid"), r))
    for key in ("Principal", "NotPrincipal"):
        p = st.get(key)
        if p is None or p == "*":
            continue
        for a in as_list(p.get("AWS", [])):
            principals.add(a)
            if a == "*" or a == "arn:aws:iam::%s:root" % acct:
                continue
            if a not in roles:
                problems.append("%s: %s %s does not exist" % (st.get("Sid"), key, a))
print("statements=%d  principals=%d  resources=%d" % (len(doc["Statement"]), len(principals), len(resources)))
print("MISMATCHES: none" if not problems else "MISMATCHES: %d" % len(problems))
for p in problems:
    print("  " + p)
PY
)
rm -f outputs/.lab-10-roles.txt

POLICY_STATE=$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>&1 \
  && echo "APPLIED - unexpected, the S3 configuration lab is meant to apply it" \
  || echo "no bucket policy - correct, the S3 configuration lab applies it")
POLICY_STATE=$(printf '%s\n' "$POLICY_STATE" | tail -1)

# --- 3. the readiness file ----------------------------------------------------------
{
  echo "# Lab 10 Exercise 5 - S3 configuration lab readiness"
  echo "# generated $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))') by scripts/utilities/lab-10-s3-readiness.sh"
  echo
  echo "bucket                 $BUCKET"
  echo "bucket ARN             arn:aws:s3:::$BUCKET"
  echo "objects in transcripts/ $(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ --query 'length(Contents)' --output text)"
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix transcripts/ --query 'Contents[].Key' --output text | tr '\t' '\n' | sed 's/^/    /'
  echo
  echo "notification"
  aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output json | python3 -c '
import json, sys
for c in json.load(sys.stdin).get("LambdaFunctionConfigurations", []):
    rules = ", ".join(r["Name"] + "=" + r["Value"] for r in c.get("Filter", {}).get("Key", {}).get("FilterRules", []))
    print("    id      " + c["Id"]); print("    target  " + c["LambdaFunctionArn"])
    print("    events  " + ",".join(c["Events"])); print("    filter  " + rules)'
  echo
  echo "functions (published versions)"
  for fn in $(aws lambda list-functions --query 'Functions[?starts_with(FunctionName, `usms-`)].FunctionName' --output text); do
    printf '    %-28s %s\n' "$fn" "$(aws lambda list-versions-by-function --function-name "$fn" \
      --query "Versions[?Version!='\$LATEST'].Version" --output text | tr '\t' '\n' | sort -n | paste -sd, -)"
  done
  echo
  echo "cloudfront supported   ${USMS_CLOUDFRONT_SUPPORTED:-unknown}  (distribution ${USMS_CLOUDFRONT_DIST_ID:-not-created})"
  echo
  echo "bucket policy draft    $DRAFT  [$DRAFT_SOURCE]"
  printf '%s\n' "$VALIDATION" | sed 's/^/    /'
  echo "    state: $POLICY_STATE"
} > "$OUT"

cat "$OUT"
