#!/usr/bin/env bash
# Generate configs/lab-08.env by LOOKUP (Lab 08 Step 19). Names, ports and numbers only.
# One deliberate change from the guide: USMS_INGRESS_CLASS falls back to the literal "none"
# when no ingress controller has claimed the Ingress, so the file states the absence
# instead of leaving an empty value that looks like a failed lookup.
#   ./scripts/utilities/write-lab-08-env.sh            19 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

k()  { kubectl get "$1" "$2" -n usms -o jsonpath="$3" 2>/dev/null; }
ng() { aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
         --query "nodegroup.scalingConfig.$1" --output text 2>/dev/null; }
ICLASS=$(k ingress usms-portal-ingress '{.spec.ingressClassName}')

# Unquoted heredoc: every $(...) runs NOW and its result lands in the file.
cat > configs/lab-08.env << EOF
# Lab 08 - EKS scaling and service exposure
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, ports and numbers only. NO SECRETS. Safe to commit.

export USMS_HPA_NAME=usms-enrolment-hpa
export USMS_HPA_MIN=$(k hpa usms-enrolment-hpa '{.spec.minReplicas}')
export USMS_HPA_MAX=$(k hpa usms-enrolment-hpa '{.spec.maxReplicas}')
export USMS_HPA_CPU_TARGET=$(k hpa usms-enrolment-hpa '{.spec.metrics[0].resource.target.averageUtilization}')
export USMS_HPA_SCALEDOWN_WINDOW=$(k hpa usms-enrolment-hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')

export USMS_PDB_GATEWAY=usms-gateway-pdb
export USMS_PDB_ENROLMENT=usms-enrolment-pdb

export USMS_SVC_NODEPORT_NAME=usms-results-np
export USMS_SVC_NODEPORT=$(k svc usms-results-np '{.spec.ports[0].nodePort}')
export USMS_SVC_GATEWAY_TYPE=$(k svc usms-gateway '{.spec.type}')
export USMS_SVC_GATEWAY_NODEPORT=$(k svc usms-gateway '{.spec.ports[0].nodePort}')

export USMS_INGRESS_NAME=usms-portal-ingress
# "none": no IngressClass exists - Floci starts k3s with --disable=traefik
export USMS_INGRESS_CLASS=${ICLASS:-none}

export USMS_NODEGROUP_MIN=$(ng minSize)
export USMS_NODEGROUP_MAX=$(ng maxSize)
export USMS_NODEGROUP_DESIRED=$(ng desiredSize)

export USMS_NODE_LABEL_SELECTOR=workload=usms
export USMS_LOADGEN_DEPLOY=usms-loadgen
export USMS_K8S_MANIFEST_DIR_05B=manifests/lab-08
EOF

echo "configs/lab-08.env: $(grep -c '^export' configs/lab-08.env) exports"
