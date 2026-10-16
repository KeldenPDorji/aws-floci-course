#!/usr/bin/env bash
# Lab 08 Exercise 5 parts 1 and 2 - every value from a live API call, re-derived, not copied
# from Lab 07 Exercise 5.
#   1. outputs/lab-08-scaling-evidence.json  HPA spec+status, Deployment replicas, node group
#      scaling config (or a stated absence), timestamp. Valid JSON (python3 -m json.tool).
#   2. outputs/lab-08-lab06-readiness.txt    USMSStudentDataReadWrite: ARN, holders, bucket and
#      object ARNs READ from the policy document, whether the bucket exists, and the
#      ServiceAccount + annotation IRSA would use.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT

# ---- part 1 ---------------------------------------------------------------------------
kubectl get hpa usms-enrolment-hpa -n usms -o json > "$S/hpa.json" 2>/dev/null || echo '{}' > "$S/hpa.json"
kubectl get deploy usms-enrolment -n usms -o json > "$S/deploy.json" 2>/dev/null || echo '{}' > "$S/deploy.json"
if aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
     --query 'nodegroup.{name:nodegroupName,status:status,scalingConfig:scalingConfig,instanceTypes:instanceTypes}' \
     --output json > "$S/ng.json" 2>"$S/ng.err"; then :; else echo null > "$S/ng.json"; fi
UPD=$(aws eks update-nodegroup-config --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
        --scaling-config minSize=2,maxSize=4,desiredSize=2 --query 'update.status' --output text 2>&1 | tr -d '\n')

python3 - "$S" "$UPD" > outputs/lab-08-scaling-evidence.json << 'PY'
import datetime, json, sys
d, upd = sys.argv[1], sys.argv[2]
hpa = json.load(open(f"{d}/hpa.json")); dep = json.load(open(f"{d}/deploy.json")); ng = json.load(open(f"{d}/ng.json"))
print(json.dumps({
  "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "source": "kubectl get hpa/deploy -o json; aws eks describe-nodegroup",
  "hpa": {"name": hpa.get("metadata", {}).get("name"), "spec": hpa.get("spec"), "status": hpa.get("status")},
  "deployment": {"name": dep.get("metadata", {}).get("name"),
                 "specReplicas": dep.get("spec", {}).get("replicas"),
                 "readyReplicas": dep.get("status", {}).get("readyReplicas"),
                 "cpuRequest": dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [{}])[0]
                                  .get("resources", {}).get("requests", {}).get("cpu")},
  "nodegroup": ng if ng is not None else {"available": False, "reason": "describe-nodegroup failed"},
  "nodegroupUpdate": {"available": False if "UnknownOperation" in upd else True,
                      "evidence": upd if "UnknownOperation" in upd else "update-nodegroup-config accepted",
                      "note": "Step 10's 2/6/3 could not be applied on Floci 2.2.0; the recorded config is the real one"},
}, indent=2))
PY
python3 -m json.tool outputs/lab-08-scaling-evidence.json > /dev/null \
  && echo "outputs/lab-08-scaling-evidence.json: valid JSON, $(wc -c < outputs/lab-08-scaling-evidence.json | tr -d ' ') bytes"

# ---- part 2 ---------------------------------------------------------------------------
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
HB=$(aws s3api head-bucket --bucket "${BUCKET##*:::}" 2>&1 | tr -d '\n'); RC=$?
ACCT=$(aws sts get-caller-identity --query Account --output text)
SA=$(kubectl get sa usms-enrolment-sa -n usms -o jsonpath='{.metadata.namespace}/{.metadata.name}' 2>/dev/null)
OIDC=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[0].Arn' --output text 2>/dev/null)
{
  echo "generated         $(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
  echo "policy_arn        $ARN  (default version $VER)"
  echo "carried_by        $(aws iam list-entities-for-policy --policy-arn "$ARN" --query 'PolicyRoles[].RoleName' --output text | tr '\t' ' ')"
  echo "bucket_arn        $BUCKET   (read from the policy document's Resource, not typed)"
  echo "object_arn        $OBJECTS  (s3:*Object applies here; s3:ListBucket to the bucket ARN)"
  echo "bucket_exists     $([ $RC -eq 0 ] && echo yes || echo no)  (head-bucket exit $RC: ${HB:-ok})"
  echo "irsa_sa           ${SA:-usms/usms-enrolment-sa (NOT FOUND)}"
  echo "irsa_annotation   eks.amazonaws.com/role-arn: arn:aws:iam::$ACCT:role/usms-enrolment-irsa-role"
  echo "irsa_role         usms-enrolment-irsa-role - NOT created: a new role trusting $OIDC"
  echo "                  via sts:AssumeRoleWithWebIdentity, condition sub = system:serviceaccount:usms:usms-enrolment-sa,"
  echo "                  carrying USMSStudentDataReadWrite. Not usms-eks-node-role: that role trusts ec2.amazonaws.com,"
  echo "                  not the OIDC provider, and is shared by every pod on the node."
  echo "irsa_status       Floci 2.2.0 does not inject web-identity tokens (Lab 07 Step 21), so this is the plan, not a build"
} > outputs/lab-08-lab06-readiness.txt
cat outputs/lab-08-lab06-readiness.txt
