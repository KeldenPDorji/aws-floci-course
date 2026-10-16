#!/usr/bin/env bash
# Lab 09 Step 4 part 2 - every role, its trust policy, boundary, and every attached and inline
# policy document, as one JSON file for usms-iam-audit.sh. Read-only.
# The guide's inline Python, moved into a script so it can be re-run after each change.
#   ./scripts/utilities/usms-identity-inventory.sh [out.json]   default outputs/lab-09-identity-inventory.json
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
OUT="${1:-outputs/lab-09-identity-inventory.json}"

python3 - > "$OUT" << 'PY'
import json, subprocess

def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return None
    return json.loads(out.stdout)

inventory = []
for r in (aws("iam", "list-roles") or {}).get("Roles", []):
    name = r["RoleName"]
    role = (aws("iam", "get-role", "--role-name", name) or {}).get("Role", r)   # list-roles omits the boundary
    detail = {
        "role": name,
        "arn": role.get("Arn"),
        "maxSessionDuration": role.get("MaxSessionDuration"),
        "permissionsBoundary": (role.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn"),
        "trustPolicy": role.get("AssumeRolePolicyDocument"),
        "attachedPolicies": [],
        "inlinePolicies": [],
    }
    for p in (aws("iam", "list-attached-role-policies", "--role-name", name) or {}).get("AttachedPolicies", []):
        ver = ((aws("iam", "get-policy", "--policy-arn", p["PolicyArn"]) or {}).get("Policy") or {}).get("DefaultVersionId")
        doc = None
        if ver:
            doc = ((aws("iam", "get-policy-version", "--policy-arn", p["PolicyArn"], "--version-id", ver) or {})
                   .get("PolicyVersion") or {}).get("Document")
        detail["attachedPolicies"].append({"name": p["PolicyName"], "arn": p["PolicyArn"], "version": ver, "document": doc})
    for pn in (aws("iam", "list-role-policies", "--role-name", name) or {}).get("PolicyNames", []):
        d = aws("iam", "get-role-policy", "--role-name", name, "--policy-name", pn) or {}
        detail["inlinePolicies"].append({"name": pn, "document": d.get("PolicyDocument")})
    inventory.append(detail)

inventory.sort(key=lambda x: x["role"])
print(json.dumps(inventory, indent=2, default=str))
PY

python3 -m json.tool "$OUT" > /dev/null && echo "valid JSON"
python3 - "$OUT" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"{len(d)} roles inventoried")
for r in d:
    print(f"  {r['role']:<44} policies={len(r['attachedPolicies'])+len(r['inlinePolicies'])} boundary={(r['permissionsBoundary'] or '-').split('/')[-1]}")
PY
