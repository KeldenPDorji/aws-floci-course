#!/usr/bin/env bash
# Generate configs/lab-07.env by LOOKUP (Lab 07 Step 23), never from shell variables,
# so a populated value in the file is evidence the resource actually exists.
# The kubeconfig is NOT recorded here - it lives in ~/.kube/config, outside this repo.
#   ./scripts/utilities/write-lab-07-env.sh            21 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

c() { aws eks describe-cluster --name usms-eks-cluster --query "cluster.$1" --output text 2>/dev/null; }
pol() { aws iam list-policies --scope Local --query "Policies[?PolicyName=='$1'].Arn | [0]" --output text 2>/dev/null; }

# Unquoted heredoc: every $(...) runs NOW and its result lands in the file.
cat > configs/lab-07.env << EOF
# Lab 07 - EKS cluster, node group and microservices
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains IDs, ARNs and names only. NO SECRETS. Safe to commit.
# The kubeconfig is NOT recorded here - it lives in ~/.kube/config, outside this repo.

export USMS_EKS_CLUSTER=usms-eks-cluster
export USMS_EKS_NODEGROUP=usms-eks-nodes
export USMS_EKS_NAMESPACE=usms

export USMS_EKS_CLUSTER_ARN=$(c arn)
export USMS_EKS_CLUSTER_STATUS=$(c status)
export USMS_EKS_VERSION=$(c version)
export USMS_EKS_ENDPOINT=$(c endpoint)
export USMS_EKS_LB_PORTS=$(c tags._lb_ports_)

export USMS_EKS_CLUSTER_ROLE_ARN=$(aws iam get-role --role-name usms-eks-cluster-role --query 'Role.Arn' --output text)
export USMS_EKS_NODE_ROLE_ARN=$(aws iam get-role --role-name usms-eks-node-role --query 'Role.Arn' --output text)
export USMS_POLICY_EKS_CLUSTER=$(pol USMSEKSClusterPolicy)
export USMS_POLICY_EKS_NODE=$(pol USMSEKSNodePolicy)

export USMS_EKS_CLUSTER_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=usms-eks-cluster-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_K8S_DEPLOY_GATEWAY=usms-gateway
export USMS_K8S_DEPLOY_ENROLMENT=usms-enrolment
export USMS_K8S_DEPLOY_RESULTS=usms-results
export USMS_K8S_SVC_GATEWAY=usms-gateway
export USMS_K8S_SVC_ENROLMENT=usms-enrolment
export USMS_K8S_SVC_RESULTS=usms-results
export USMS_K8S_CPU_REQUEST=50m
export USMS_K8S_MANIFEST_DIR=manifests/lab-07
EOF

echo "wrote configs/lab-07.env ($(grep -c '^export' configs/lab-07.env) exports)"
