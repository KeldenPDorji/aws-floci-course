#!/usr/bin/env bash
# END OF COURSE ONLY. Removes every Lab 08 object. Run BEFORE lab-07-cleanup.sh.
# Order: Ingress -> LoadBalancer Service -> controllers -> workloads -> AWS side.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
NS=usms

cat <<'WARN'
This removes:
  - Ingresses usms-portal-ingress and usms-results-ingress (Exercise 4)
  - Service usms-results-np (NodePort)
  - usms-gateway reverts from LoadBalancer to ClusterIP
  - HorizontalPodAutoscaler usms-enrolment-hpa (and usms-results-hpa, Exercise 1)
  - PodDisruptionBudgets usms-gateway-pdb and usms-enrolment-pdb
  - Deployment usms-loadgen
  - node group scaling config returns to min 2 / max 4 / desired 2
It does NOT remove the cluster, the namespace, or the microservices.
WARN

printf 'Type exactly DELETE-LAB-08 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-08" ] || { echo "aborted"; exit 1; }

# 1. Ingress first: it references Services, and an orphaned ALB is worse than an orphaned rule.
kubectl delete ingress usms-results-ingress usms-portal-ingress -n "$NS" --ignore-not-found

# 2. The LoadBalancer Service next, so any cloud load balancer (here: the k3s ServiceLB
#    pod) is released before anything else is torn down.
kubectl patch svc usms-gateway -n "$NS" --type=merge -p '{"spec":{"type":"ClusterIP"}}' 2>/dev/null
kubectl delete svc usms-results-np -n "$NS" --ignore-not-found

# 3. Controllers that write to Deployments, before the Deployments themselves.
kubectl delete hpa usms-enrolment-hpa usms-results-hpa -n "$NS" --ignore-not-found
kubectl delete pdb usms-gateway-pdb usms-enrolment-pdb -n "$NS" --ignore-not-found

# 4. The load generator.
kubectl delete deployment usms-loadgen -n "$NS" --ignore-not-found

# 5. AWS side last: nothing in Kubernetes depends on it. Floci 2.2.0 does not implement
#    UpdateNodegroupConfig, so on this build the call fails and the group was never changed.
aws eks update-nodegroup-config \
  --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 >/dev/null 2>&1 \
  || echo "node group unchanged (UpdateNodegroupConfig unavailable on this build, or Path B)"

echo "Lab 08 objects removed. The Lab 07 cluster and application are untouched."
