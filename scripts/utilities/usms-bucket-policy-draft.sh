#!/usr/bin/env bash
# Lab 09 Exercise 5 - draft the RESOURCE policy for the transcripts bucket. Applies nothing.
#  1. reads the bucket ARN out of Lab 01's USMSStudentDataReadWrite document (never typed)
#  2. reads the identity inventory and finds EVERY role whose attached policies Allow any s3:
#     action on that bucket or its objects (including through Resource "*")
#  3. writes outputs/lab-09-bucket-policy-draft.json:
#       one Allow per role, limited to the actions and resources that role already has
#       Deny s3:* to Principal "*" when aws:SecureTransport is false
#       Deny s3:* to everyone NOT in that list (NotPrincipal: the roles + the account root)
#  4. checks it mechanically, and writes outputs/lab-09-lab10-readiness.txt
# Works whether or not the bucket exists. Contains, reads and references no access key.
#   ./scripts/utilities/usms-bucket-policy-draft.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

ACCT=$(aws sts get-caller-identity --query Account --output text)
RW_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]" --output text)
RW_VER=$(aws iam get-policy --policy-arn "$RW_ARN" --query 'Policy.DefaultVersionId' --output text)
BUCKET_ARN=$(aws iam get-policy-version --policy-arn "$RW_ARN" --version-id "$RW_VER" --query 'PolicyVersion.Document' --output json \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);d=json.loads(d) if isinstance(d,str) else d
rs=[x for s in d["Statement"] for x in (s["Resource"] if isinstance(s["Resource"],list) else [s["Resource"]])]
print(next(x for x in rs if x.startswith("arn:aws:s3:::") and "/" not in x))')
# Parameter expansion, not sed: "##*:::" deletes the longest prefix ending in ":::", which
# is exactly "arn:aws:s3:::", leaving the bucket name with no extra process.
BUCKET="${BUCKET_ARN##*:::}"

./scripts/utilities/usms-identity-inventory.sh outputs/lab-09-identity-inventory.json > /dev/null

python3 - "$BUCKET_ARN" "$ACCT" outputs/lab-09-identity-inventory.json outputs/lab-09-bucket-policy-draft.json << 'PY'
import json, sys
bucket_arn, acct, inv_path, out = sys.argv[1:5]
objects_arn = bucket_arn + "/*"

def L(x):
    return x if isinstance(x, list) else [x]

grants = {}   # role arn -> {"actions": set, "resources": set, "via": set}
for r in json.load(open(inv_path)):
    for p in r["attachedPolicies"] + r["inlinePolicies"]:
        d = p.get("document") or {}
        d = json.loads(d) if isinstance(d, str) else d
        for s in L(d.get("Statement")):
            if s.get("Effect") != "Allow":
                continue
            acts = [a for a in L(s.get("Action")) if a == "*" or str(a).lower().startswith("s3:")]
            res = []
            for x in L(s.get("Resource")):
                if x == "*":
                    res += [bucket_arn, objects_arn]
                elif x == bucket_arn or x.startswith(bucket_arn + "/"):
                    res.append(x)
            if acts and res:
                g = grants.setdefault(r["arn"], {"actions": set(), "resources": set(), "via": set()})
                g["actions"].update(acts); g["resources"].update(res); g["via"].add(p["name"])

statements = []
for arn in sorted(grants):
    g = grants[arn]
    statements.append({
        "Sid": "Allow" + "".join(w.capitalize() for w in arn.split("/")[-1].split("-")),
        "Effect": "Allow",
        "Principal": {"AWS": arn},
        "Action": sorted(g["actions"]),
        "Resource": sorted(g["resources"]),
    })
statements.append({
    "Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*", "Action": "s3:*",
    "Resource": [bucket_arn, objects_arn],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
})
statements.append({
    "Sid": "DenyEveryoneElse", "Effect": "Deny",
    "NotPrincipal": {"AWS": sorted(grants) + [f"arn:aws:iam::{acct}:root"]},
    "Action": "s3:*", "Resource": [bucket_arn, objects_arn],
})
policy = {"Version": "2012-10-17", "Id": "UsmsStudentDataBucketPolicyDraft", "Statement": statements}
json.dump(policy, open(out, "w"), indent=2)
json.dump({a: sorted(v["via"]) for a, v in grants.items()}, open(out + ".via", "w"))
PY

DRAFT=outputs/lab-09-bucket-policy-draft.json
python3 -m json.tool "$DRAFT" > /dev/null && echo "$DRAFT: valid JSON"
python3 - "$DRAFT" "$BUCKET_ARN" << 'PY'
import json, sys
d = json.load(open(sys.argv[1])); b = sys.argv[2]
ok = True
for s in d["Statement"]:
    p = s.get("Principal", s.get("NotPrincipal"))
    arns = [p] if isinstance(p, str) else [a for v in p.values() for a in (v if isinstance(v, list) else [v])]
    if s["Sid"] == "DenyInsecureTransport":
        good = p == "*"
    else:
        good = all(a.startswith("arn:aws:iam::") for a in arns)
    ok &= good
    print(f"  {'ok  ' if good else 'FAIL'} {s['Sid']:<36} principal {'*' if p == '*' else str(len(arns)) + ' ARN(s)'}")
text = json.dumps(d)
both = f'"{b}"' in text and f'"{b}/*"' in text
print(f"  {'ok  ' if both else 'FAIL'} bucket ARN appears with and without /*")
sys.exit(0 if ok and both else 1)
PY
CHECK=$?

VIA="$DRAFT.via"
{
  echo "bucket_name        $BUCKET   (read from $(basename "$RW_ARN") $RW_VER's Resource, not typed)"
  echo "granting_policies  $(python3 -c 'import json,sys;print(" ".join(sorted({p for v in json.load(open(sys.argv[1])).values() for p in v})))' "$VIA")"
  echo "role_arns          $(python3 -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$VIA")"
  echo "principal_count    $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$VIA") roles granted an s3: action on the bucket (+ the account root in the NotPrincipal)"
  echo "bucket_exists      $(aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && echo yes || echo no)"
  echo "when_lab10_creates When Lab 10 runs create-bucket, every role above stops being a statement about"
  echo "                   an ARN and starts working at once - the three USMSStudentDataReadWrite roles can"
  echo "                   write and delete transcripts that day - while this draft, unapplied, changes nothing."
} > outputs/lab-09-lab10-readiness.txt
rm -f "$VIA"
cat outputs/lab-09-lab10-readiness.txt
exit $CHECK
