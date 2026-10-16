#!/usr/bin/env bash
# Lab 08 Step 18 - the scaling and exposure facts that must survive a Floci restart.
# Configuration only: replica counts, live CPU and EXTERNAL-IP are left out, because they may
# legitimately move. The node group is re-derived from list-nodegroups, not from a variable.
#   ./scripts/utilities/lab-08-restart-facts.sh > outputs/lab-08-before-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
NS=usms

kubectl get hpa -n "$NS" -o custom-columns='HPA:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,TARGET:.spec.metrics[0].resource.target.averageUtilization,DOWNWINDOW:.spec.behavior.scaleDown.stabilizationWindowSeconds'
kubectl get pdb -n "$NS" -o custom-columns='PDB:.metadata.name,MINAVAIL:.spec.minAvailable,MAXUNAVAIL:.spec.maxUnavailable'
kubectl get svc -n "$NS" -o custom-columns='SERVICE:.metadata.name,TYPE:.spec.type,CLUSTERIP:.spec.clusterIP,NODEPORT:.spec.ports[0].nodePort'
kubectl get ingress -n "$NS" -o custom-columns='INGRESS:.metadata.name,PATHS:.spec.rules[0].http.paths[*].path'
echo "nodeSelector on usms-enrolment: $(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.spec.template.spec.nodeSelector}')"
NG=$(aws eks list-nodegroups --cluster-name usms-eks-cluster --query 'nodegroups[0]' --output text 2>/dev/null)
echo "nodegroup (from list-nodegroups) $NG: $(aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name "$NG" --query 'nodegroup.[status,scalingConfig.minSize,scalingConfig.maxSize,scalingConfig.desiredSize]' --output text 2>/dev/null)"
