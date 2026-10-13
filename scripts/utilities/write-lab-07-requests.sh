#!/usr/bin/env bash
# Lab 07 Steps 8 and 10 - write the two --cli-input-json request bodies BY LOOKUP:
#   templates/lab-07-create-cluster.json      templates/lab-07-create-nodegroup.json
# Unquoted heredocs on purpose: every $VAR and $(...) must become a real ID now.
#   ./scripts/utilities/write-lab-07-requests.sh
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-02.env

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name usms-eks-cluster-role --query 'Role.Arn' --output text)
NODE_ROLE_ARN=$(aws iam get-role --role-name usms-eks-node-role --query 'Role.Arn' --output text)
EKS_CLUSTER_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=usms-eks-cluster-sg" "Name=vpc-id,Values=$USMS_VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)

# Refuse to write a body with a hole in it. An SG created without --vpc-id lands in
# vpc-default, the lookup above returns None, and create-cluster would accept "None".
for V in CLUSTER_ROLE_ARN NODE_ROLE_ARN EKS_CLUSTER_SG USMS_VPC_ID USMS_PRIVATE_SUBNET_A USMS_PRIVATE_SUBNET_B USMS_PUBLIC_SUBNET_A USMS_PUBLIC_SUBNET_B; do
  case "${!V:-}" in ""|None) echo "STOP - $V is empty or None (is usms-eks-cluster-sg in $USMS_VPC_ID?)" >&2; exit 1 ;; esac
done

# accessConfig is NOT in the guide's body. On Floci 2.2.0 the default mode is CONFIG_MAP,
# which ignores aws-auth and refuses access entries, and update-cluster-config is not
# implemented - so the mode must be chosen here, at creation. API_AND_CONFIG_MAP is also
# the real-AWS default for new clusters.
cat > templates/lab-07-create-cluster.json << EOF
{
  "name": "usms-eks-cluster",
  "version": "1.30",
  "roleArn": "$CLUSTER_ROLE_ARN",
  "resourcesVpcConfig": {
    "subnetIds": [
      "$USMS_PRIVATE_SUBNET_A",
      "$USMS_PRIVATE_SUBNET_B",
      "$USMS_PUBLIC_SUBNET_A",
      "$USMS_PUBLIC_SUBNET_B"
    ],
    "securityGroupIds": [ "$EKS_CLUSTER_SG" ],
    "endpointPublicAccess": true,
    "endpointPrivateAccess": true
  },
  "accessConfig": {
    "authenticationMode": "API_AND_CONFIG_MAP",
    "bootstrapClusterCreatorAdminPermissions": true
  },
  "tags": {
    "Name": "usms-eks-cluster",
    "Project": "USMS",
    "Tier": "app",
    "Lab": "07",
    "_lb_ports_": "8081,8082"
  }
}
EOF

cat > templates/lab-07-create-nodegroup.json << EOF
{
  "clusterName": "usms-eks-cluster",
  "nodegroupName": "usms-eks-nodes",
  "scalingConfig": { "minSize": 2, "maxSize": 4, "desiredSize": 2 },
  "subnets": [ "$USMS_PRIVATE_SUBNET_A", "$USMS_PRIVATE_SUBNET_B" ],
  "instanceTypes": [ "t3.small" ],
  "amiType": "AL2023_x86_64_STANDARD",
  "nodeRole": "$NODE_ROLE_ARN",
  "labels": { "workload": "usms", "tier": "app" },
  "tags": { "Name": "usms-eks-nodes", "Project": "USMS", "Tier": "app", "Lab": "07" }
}
EOF

for f in templates/lab-07-create-cluster.json templates/lab-07-create-nodegroup.json; do
  python3 -m json.tool "$f" >/dev/null && echo "$f : valid JSON, $(grep -c '\$' "$f") unexpanded \$"
done
