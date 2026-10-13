#!/usr/bin/env bash
# Lab 07 Step 22 - the facts compared across a Floci restart. The cluster and node group
# are RE-DERIVED from list-clusters / list-nodegroups (not from the names we already know),
# the access entry from list-access-entries, and the Kubernetes side from the API server.
# Pod names, pod IPs, restart counts and ages are deliberately absent: they may move.
#   ./scripts/utilities/lab-07-restart-facts.sh > outputs/lab-07-before-restart.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

CL=$(aws eks list-clusters --query 'clusters[?@==`usms-eks-cluster`] | [0]' --output text 2>/dev/null)
echo "cluster   (from list-clusters)   ${CL:-MISSING}"
aws eks describe-cluster --name "$CL" \
  --query 'cluster.[name,status,version,endpoint,length(resourcesVpcConfig.subnetIds),accessConfig.authenticationMode,tags._lb_ports_]' --output text 2>/dev/null
NG=$(aws eks list-nodegroups --cluster-name "$CL" --query 'nodegroups | [0]' --output text 2>/dev/null)
echo "nodegroup (from list-nodegroups) ${NG:-MISSING}"
aws eks describe-nodegroup --cluster-name "$CL" --nodegroup-name "$NG" \
  --query 'nodegroup.[status,scalingConfig.minSize,scalingConfig.maxSize,scalingConfig.desiredSize,length(subnets)]' --output text 2>/dev/null
echo "access entries: $(aws eks list-access-entries --cluster-name "$CL" --query 'accessEntries' --output text 2>/dev/null)"
echo "--- kubernetes ---"
kubectl get ns usms --no-headers 2>/dev/null | awk '{print "namespace", $1, $2}'
kubectl get deploy -n usms -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' --no-headers 2>/dev/null | sort
kubectl get svc -n usms -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,IP:.spec.clusterIP' --no-headers 2>/dev/null | sort
kubectl get cm,secret,sa -n usms --no-headers -o name 2>/dev/null | grep -v -E 'kube-root-ca|default$' | sort
