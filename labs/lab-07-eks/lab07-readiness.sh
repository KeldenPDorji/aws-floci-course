#!/usr/bin/env bash
# Lab 07 Exercise 5 parts 1 and 2.
#   1. CPU use of the usms-enrolment pods, absolute and as a % of the 50m request
#      -> outputs/lab-07-cpu-baseline.txt   (states honestly whether the metrics API exists)
#   2. USMSStudentDataReadWrite: ARN, every role carrying it, the bucket ARN READ from the
#      policy document, and whether that bucket exists -> outputs/lab-07-lab06-readiness.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

# ---- part 1 ---------------------------------------------------------------------------
OUT1=outputs/lab-07-cpu-baseline.txt
{
  echo "generated $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
  if kubectl get --raw /apis/metrics.k8s.io/v1beta1 --request-timeout=10s >/dev/null 2>&1; then
    echo "metrics API: PRESENT (metrics.k8s.io/v1beta1 - k3s ships metrics-server)"
    REQ=$(kubectl get deploy usms-enrolment -n usms -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
    echo "cpu request per pod: $REQ"
    kubectl top pods -n usms -l app=usms-enrolment --no-headers | while read -r pod cpu mem; do
      python3 -c "import sys; c=int(sys.argv[2].rstrip('m')); r=int(sys.argv[3].rstrip('m')); print(f'{sys.argv[1]:<36} cpu={c}m  {100*c/r:.0f}% of {r}m request  mem={sys.argv[4]}')" "$pod" "$cpu" "$REQ" "$mem"
    done
  else
    echo "metrics API: ABSENT - no numbers recorded (Lab 08 Step 7 handles this)"
  fi
} > "$OUT1"
cat "$OUT1"; echo

# ---- part 2 ---------------------------------------------------------------------------
OUT2=outputs/lab-07-lab06-readiness.txt
ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
VER=$(aws iam get-policy --policy-arn "$ARN" --query 'Policy.DefaultVersionId' --output text)
DOC=$(aws iam get-policy-version --policy-arn "$ARN" --version-id "$VER" --query 'PolicyVersion.Document' --output json)
read -r BUCKET OBJECTS <<< "$(echo "$DOC" | python3 -c '
import json,sys
d=json.load(sys.stdin); d=json.loads(d) if isinstance(d,str) else d
rs=[]
for s in d["Statement"]:
    r=s.get("Resource",[]); rs+= r if isinstance(r,list) else [r]
s3=sorted({x for x in rs if x.startswith("arn:aws:s3:::")})
print(next(x for x in s3 if "/" not in x), next(x for x in s3 if "/" in x))')"
{
  echo "policy_arn        $ARN  (default version $VER)"
  echo "carried_by        $(aws iam list-entities-for-policy --policy-arn "$ARN" --query 'PolicyRoles[].RoleName' --output text | tr '\t' ' ')"
  echo "bucket_arn        $BUCKET   (read from the policy document, not typed)"
  echo "object_arn        $OBJECTS  (the s3:*Object actions apply here, ListBucket to the bucket ARN)"
  HB=$(aws s3api head-bucket --bucket "${BUCKET##*:::}" 2>&1); RC=$?
  echo "bucket_exists     $([ $RC -eq 0 ] && echo yes || echo no)  (head-bucket exit $RC: ${HB:-ok})"
} > "$OUT2"
cat "$OUT2"
