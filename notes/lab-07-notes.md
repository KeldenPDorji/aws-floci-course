# Lab 07 - EKS microservices - my notes

**Support path (Step 2): A, on Floci 2.2.0.** `eks-support-probe.sh` found
`list-clusters`, `list-access-entries` and `describe-addon-versions` all
answering, so `aws eks` is used throughout. `k3d` is not installed, and Path A
does not need it. The probe output is in `outputs/lab-07-support-probe.txt`.

What Path A means on this build:

- **The control plane is real Kubernetes.** `create-cluster` starts a k3s
  `v1.30.10+k3s1` container (`floci-aws-floci-course-eks-usms-eks-cluster`)
  and publishes its API server on `https://localhost:6500`. CoreDNS and
  metrics-server come with it.
- **The node group is a record, not machines.** `usms-eks-nodes` is `ACTIVE`
  with min 2 / max 4 / desired 2, but `kubectl get nodes` shows **one** node,
  the k3s server (`control-plane,master`), and every pod runs on it. Lab 08
  Step 10 can still call `update-nodegroup-config`; the node count will not
  move.
- **Authentication had to be designed in.** Section 3 of the report has the
  detail: the cluster was created with `accessConfig.authenticationMode =
  API_AND_CONFIG_MAP`, an access entry maps `usms-developer-role` to
  `system:masters`, and the kubeconfig uses `--role-arn`.

## Step 3 "Your turn" - is EKS just ECS with different names?

It is false because of the right-hand column of the split. With EKS I own a
data plane that ECS on Fargate hid from me: a node group with its own IAM
role, its own subnets, its own sizing and its own upgrade
(`update-nodegroup-version` after `update-cluster-version`). On top of that,
the API I talk to after Step 11 is not AWS at all. Deployments, ReplicaSets
and Services belong to Kubernetes, and `aws` cannot see inside them.

It is nearly true at the level of intent. A task definition and a pod
template both say "this image, these ports, this much CPU". An ECS service
and a Deployment both say "keep N of them alive and replace them one batch at
a time". The nouns map almost one to one. What differs is who runs the loop
and which API holds the state.

## Step 9 - the `_lb_ports_` tag, and the OIDC issuer

`describe-cluster --query 'cluster.tags._lb_ports_'` printed `8081,8082`
first time, so the `tag-resource` fallback was not needed.

"Your turn", one command: `aws eks describe-cluster --name usms-eks-cluster
--query '[cluster.version,cluster.identity.oidc.issuer]' --output text`
printed `1.30` and
`https://oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843`.

**What the issuer is for:** it is the URL where the cluster publishes the
public keys that sign its ServiceAccount tokens. IAM trusts tokens signed by
those keys, which is what lets a single pod assume a role (IRSA, Step 21).

## Step 10 - the node group

`usms-eks-nodes` exists as an AWS object: two private subnets
(`subnet-cbeebb5f` in us-east-1a and `subnet-2b5f6829` in us-east-1b),
`t3.small`, `AL2023_x86_64_STANDARD`, labels `workload=usms` and `tier=app`,
and the node role. Floci stores all of it, but none of it makes a machine.

One behaviour the guide does not mention: **creating the node group makes
Floci replace the k3s container** ("Replaced EKS cluster usms-eks-cluster to
apply current node capacity limits" in the Floci log). The cluster goes back
to `CREATING` for a few seconds. `aws eks wait nodegroup-active` returns
before that finishes, so a second `aws eks wait cluster-active` is needed
before `update-kubeconfig`, which refuses a cluster that is not `ACTIVE`.

## Step 13 - readiness versus liveness, in my words

Readiness answers "should this pod get traffic right now?". When it fails,
the pod stays alive, but its address moves out of the Service's endpoints.
Liveness answers "is this container stuck beyond saving?". When it fails,
the kubelet kills the container and restarts it. On `usms-enrolment` both
point at `/healthz`, but readiness runs every 5 s from 3 s and liveness only
every 20 s from 15 s. One unready moment should cost traffic, not a restart.
Exercise 3 showed the readiness half: two pods `Running`, `READY 0/1`, and no
endpoints.

## Step 16 "Your turn" - who replaced the pod

I deleted `usms-enrolment-5cf94ff846-m2p49`. Then `usms-enrolment-5cf94ff846-kffqb`
appeared, and the next 12-request tally was 6 / 6 across `kffqb` and `wz5tn`,
with no failed request and no gateway restart.

**The replacement was created by the ReplicaSet `usms-enrolment-5cf94ff846`**.
The event says so: `replicaset/usms-enrolment-5cf94ff846  Created pod:
usms-enrolment-5cf94ff846-kffqb` (`outputs/lab-07-pod-replace.txt`). The
Deployment only manages ReplicaSets, and I only deleted.

## Step 18 - rollouts

What I saw (`outputs/lab-07-rollout.txt`):

1. **Changing the ConfigMap did not change the running pods.** After
   `APP_VERSION` went to `1.1.0` and was applied, a request still answered
   `1.0.0`. The value enters as an environment variable at container start.
2. **An annotation on the Deployment's own metadata does nothing.** The
   revision stayed at 2. Revision 2 came from Step 17's `kubectl set env`,
   which did change the template. Only a change under `spec.template` makes a
   new ReplicaSet.
3. **`rollout restart` created revision 3.** It writes
   `kubectl.kubernetes.io/restartedAt` into the template. The answer became
   `1.1.0`, and three ReplicaSets were listed (revisions 1, 2, 3).
4. **`rollout undo` went back to revision 2's ReplicaSet**
   (`usms-enrolment-ff96cc87d`), **and the pod still said `1.1.0`.** Undo
   restores the pod template. The ConfigMap is a separate object, and it
   still held `1.1.0`. This is Review Question 4.

"Your turn" for `usms-results`: `kubectl set image ... results=nginx:1.27`,
then `rollout undo`. **`rollout history` showed two revisions (2 and 3)**
afterwards: the undo re-labels revision 1 as 3. The image was back to
`nginx:1.27-alpine`.

**How the roll differed:** at two replicas it barely did. `kubectl get pods
-w` peaked at **three pods**. The new `5f57b6496b-ggr9t` became `1/1` before
the first old pod started `Terminating`, the same surge-one, lose-none shape
as enrolment. The default 25% / 25% rounds to `maxSurge` 1 (rounded up) and
`maxUnavailable` 0 (rounded down) when there are only two replicas. The
difference only appears at four replicas or more, where 25% of capacity may
be down during the roll.

## Step 20 - ECS and Kubernetes, compared with both running

Both were up when I wrote this (`outputs/lab-07-ecs-vs-eks.txt`). ECS had
`usms-enrolment-svc` 2 / 2 on `usms-enrolment:2`, with 1 load balancer and
1 deployment. EKS had three Deployments and three ClusterIP Services in
`usms`.

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | The task definition revision (`usms-enrolment:2`), immutable and numbered | The pod template inside the Deployment, `spec.template`. Revisions are recorded on ReplicaSets |
| What keeps N copies alive? | The ECS service scheduler, against `desiredCount` | The ReplicaSet controller, against `replicas`. The Deployment manages the ReplicaSets |
| What gives it a stable name? | The service name, plus the ALB DNS name from Lab 05 | A Service: one ClusterIP (`10.100.215.3`) and a DNS name, `usms-enrolment.usms.svc.cluster.local` |
| How does another service find it? | Through the load balancer's DNS name, or Cloud Map if configured | Cluster DNS (CoreDNS) resolves the Service name; kube-proxy spreads connections over the endpoints |
| What does a rolling update create? | A new ECS *deployment* with tasks from the new revision; `minimumHealthyPercent` / `maximumPercent` shape it | A new ReplicaSet, scaled up while the old one scales down; `maxSurge` / `maxUnavailable` shape it |
| Where does rollback state live? | In the old task definition revisions; you point the service back at one | In the old ReplicaSets, scaled to 0 and kept up to `revisionHistoryLimit` (5 here) |
| Which IAM role does the app code use? | The task role (`usms-ecs-task-role`), per task | The node role (`usms-eks-node-role`), shared by every pod on the node, unless IRSA or Pod Identity is set up |
| What would I have to change to move to another cloud? | Almost all of it: task definitions, services and target groups are AWS-only | The manifests move largely unchanged. The IAM roles, VPC, node group, security group and any load balancer annotations do not |

**For USMS I would choose ECS on Fargate.** The team is small and the
workload is three stateless HTTP services. ECS gave me per-task IAM roles,
no nodes to patch and one API, and this lab cost more effort to reach the
same "two copies behind a stable name".

## Step 21 - IRSA: which of the six steps this build completed

| # | Step | On Floci 2.2.0 |
|---|---|---|
| 1 | The cluster publishes an OIDC issuer | **Partly.** `cluster.identity.oidc.issuer` is filled in. It names the real AWS host `oidc.eks.us-east-1.amazonaws.com`, which has no document for this cluster, so nothing outside can fetch the keys |
| 2 | Register it in IAM | **Done.** `create-open-id-connect-provider` returned `arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843` |
| 3 | A role trusting that provider for `system:serviceaccount:usms:usms-enrolment-sa` | Not done. The guide does not ask for it, and step 5 makes it moot |
| 4 | A ServiceAccount, annotated with the role | **ServiceAccount created** (`manifests/lab-07/60-serviceaccount.yaml`), not annotated, since there is no role to name |
| 5 | The webhook injects a token and env vars | **No.** Floci logs "EKS Pod Identity injection is off for cluster usms-eks-cluster: Kubernetes only accepts an https admission webhook URL, and Floci serves HTTP". A pod run with `usms-enrolment-sa` had no `AWS_*` variables and no `/var/run/secrets/eks.amazonaws.com` |
| 6 | The SDK calls `AssumeRoleWithWebIdentity` | No. Nothing was injected for it to use |

Evidence is in `outputs/lab-07-irsa.txt`. So "I configured IRSA" would be
false. What is true is that steps 1, 2 and 4 completed, and step 5 stops it.
Until then the pods' AWS permissions are the node role's. Every pod on the
node, including a compromised one, would get `USMSStudentDataReadWrite`.

## Step 22 - persistence

`PERSISTENCE PROVEN` (screenshot 04). The facts were taken before and after a
`floci-down` / `floci-up`. The cluster and node group names came from
`list-clusters` and `list-nodegroups` with a JMESPath filter, not from shell
variables. Everything matched: cluster status, version, endpoint, subnet
count, auth mode, `_lb_ports_`, node group sizing, the access entry, the
namespace, three Deployments with their images, three Services *with the
same ClusterIPs*, four ConfigMaps and the Secret.

## Step 23 - the env file

`configs/lab-07.env`: 21 exports, none empty or `None` (Path A, so any gap
would have been a real one).

## Review questions (Section 14)

### 1. ACTIVE cluster, every pod Pending

`ACTIVE` is a statement about the control plane only: the API server and etcd
are up and answering. `Pending` means the scheduler, also control plane, has
found no data-plane node that can take the pod. Both are true at once,
because the two halves are created, sized and paid for separately (Step 3).
The cluster can be perfect while there is nothing for it to run on.

Configurations that produce it:

- **No worker nodes at all.** For example, a node group was never created,
  or its nodes could not join because the node role lacks
  `AmazonEKSWorkerNodePolicy`. The only node is a tainted control-plane node
  (Troubleshooting, "untolerated taint").
- **Nodes exist, but nothing fits.** I produced this one in Step 19:
  `usms-toobig` asked for 64 CPUs and 256 Gi, and the scheduler said
  `0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory`.
  Requests are what the scheduler packs against, not actual usage.
- Nodes that are cordoned, as in my Exercise 4 drain, or a `nodeSelector`
  that matches no node's labels, give the same symptom.

### 2. Swapping the two trust policies

The cluster role would then trust `ec2.amazonaws.com` and the node role
`eks.amazonaws.com`. Floci never evaluates trust, so on Floci nothing breaks
and you would not notice at all. On real AWS it would show up at:

- **Step 8, `create-cluster`.** EKS has to assume the cluster role to create
  the cross-account network interfaces in my subnets. If the role does not
  trust `eks.amazonaws.com`, the call is refused at once, with an error that
  says the role cannot be assumed.
- **Step 10, the node group,** if the cluster role were fixed first. The
  instances' instance profile needs a role that EC2 can assume. With
  `eks.amazonaws.com` in the trust, the instances would boot with no
  credentials. The kubelet could not get a token, the nodes would never
  register, and the node group would end in `CREATE_FAILED` with
  `NodeCreationFailure` after its long timeout. `kubectl get nodes` at
  Step 11 would be empty.

The first failure is fast and readable, the second slow and indirect.

### 3. Readiness versus liveness, and getting it backwards

The two probes are defined in Step 13 above. **The failure from getting it
backwards:** suppose a check that depends on load or on a downstream database
is wired to liveness. On a busy enrolment morning, the database slows down
and `/healthz` times out on every pod. Every pod is then killed and
restarted at about the same time. Restarting does not make the database
faster, so the restarts continue, capacity drops to zero, and a slow service
has become a down service. As a readiness probe, the same check would have
taken pods out of rotation and brought them back without a restart.

The opposite mistake does its damage too. Exercise 3's readiness probe
pointed at a path that returns 404, so two healthy `Running` pods never got
any traffic.

### 4. "Rollback is not really a rollback"

After `rollout undo` the pod still said `1.1.0`. Undo restores the
**Deployment's pod template**, the revision held by the old ReplicaSet. The
version came from the ConfigMap `usms-app-config`, a separate object that the
Deployment only refers to by name. Nothing in the rollback touched it, and it
still held `1.1.0`.

I would argue the statement is half right. `rollout undo` is a real,
reliable rollback **of the template**: image, command, env wiring, probes
and resources. It is not a rollback of the application's whole
configuration, because Kubernetes does not version referenced objects
together with the Deployment. If an operator believes otherwise, they will
roll back during an incident and keep the bad configuration.

The practice that fixes it is to **make configuration part of the
template's identity**. Either give the ConfigMap a name that includes its
content hash or version (Kustomize's `configMapGenerator` does this), or put
a checksum of the ConfigMap into a pod template annotation. Then a config
change *is* a new revision, and undo brings the old name back. Better still,
keep the manifests in Git and roll back with `git revert` plus `apply`.

### 5. `maxUnavailable: 0` versus the default, with two replicas

- **`usms-enrolment` (`maxUnavailable 0`, `maxSurge 1`):** start one new pod
  first (3 total), wait for it to be ready, remove one old pod, repeat. Two
  ready pods at every moment. It costs one extra pod's worth of capacity and
  a slower roll. Suited to enrolment itself, where losing half the capacity
  in the busiest week means failed registrations.
- **`usms-results` (default 25% / 25%):** at two replicas this rounds to
  `maxSurge` 1 and `maxUnavailable` 0, so my roll had the **same** three-pod
  peak (Step 18). With eight replicas it allows two down and two extra
  together: faster, with less spare capacity needed, and up to a quarter of
  capacity missing during the roll. Suited to a read-mostly service with
  spare headroom, like results outside results week, or a batch worker.

**Closer to Lab 04's ECS configuration:** `usms-enrolment`. ECS's default
`minimumHealthyPercent 100` / `maximumPercent 200` never drops below desired
and starts new tasks first, which is `maxUnavailable 0` with a large surge.

### 6. "A Secret is encrypted, so it's fine to commit the manifest"

That is not right, and Step 17 showed it. `kubectl get secret ... -o
jsonpath='{.data.ENROLMENT_API_TOKEN}'` printed
`ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=`, and `base64 -d` turned
it straight back into `floci-dummy-token-not-a-real-secret` with no key.
Base64 is an encoding, not encryption. Anyone with the manifest, or with
`get secret` permission, has the value.

**What a Secret does provide:**
- it is a separate object type, so RBAC can let people read ConfigMaps but
  not Secrets
- it can be mounted as a tmpfs file instead of sitting in an image
- it can be **encrypted at rest in etcd** if the cluster is configured for it

**What it does not provide:** any protection in the YAML, in Git, in
`kubectl` output, or from anyone who can create a pod in the namespace and
mount it.

That is why my Secret manifest went to `outputs/lab-07-secret.yaml`
(git-ignored, mode 600) and not into `manifests/`.

On real EKS I would:
- turn on **KMS envelope encryption** of Secrets at cluster creation
- keep the real value in **AWS Secrets Manager**, and bring it in with the
  Secrets Store CSI driver or External Secrets Operator, through a pod-level
  IAM role (IRSA or Pod Identity), so nothing secret is in Git at all
- if a manifest must live in Git, commit a **SealedSecret** or a SOPS-encrypted file

### 7. ECS or Kubernetes for USMS

**ECS on Fargate.** USMS is a small team in one region, idle for eight
months and very busy for two. That pattern rewards the platform with the
least standing work. I would not pay to run a control plane for eight quiet
months, or patch and upgrade nodes every quarter.

Things this lab made harder than Lab 04:

- **Two IAM roles and two lifecycles (cluster and nodes)** instead of a task
  execution role. On Floci the node group did not even become machines.
- **A second API and a second identity system.** Getting `kubectl` to talk
  to the cluster took the `accessConfig` mode, an access entry and
  `--role-arn`. Debugging it cost more time than anything in Lab 04.
- **Per-pod AWS permissions are not the default.** ECS gave every task its
  own role from day one. Here every pod shares the node role, and the proper
  fix (IRSA) could not complete on this build.

One thing Kubernetes gave me that ECS could not: **name-based service
discovery and versioned rollouts inside the platform itself.** The gateway
reached three backends through `usms-*.usms.svc.cluster.local` with no load
balancer, no addresses and no AWS call. `rollout history` and `rollout undo`
are built in, and a PodDisruptionBudget held one enrolment pod up during a
drain (Exercise 4). With ECS, discovery needed an ALB or Cloud Map, and
nothing like a disruption budget exists. The same manifests would also run
on any other conformant cluster.

## Observed, recorded only, and conceptual (Section 11)

- **Observed:**
  - the Kubernetes object model (Deployments, ReplicaSets, Services,
    endpoints)
  - CoreDNS service discovery and kube-proxy load spreading
  - rolling updates, `rollout history` and `rollout undo`
  - readiness gating Service membership
  - all three failure modes
  - a PodDisruptionBudget blocking an eviction
  - metrics-server CPU figures
  - persistence across a restart
  - EKS access entries **really being enforced**: without one, `kubectl`
    was `Unauthorized`
- **Recorded only (stored, never evaluated):**
  - the four IAM policies and both trust relationships
  - the node group's sizing, subnets, instance type and AMI
  - `usms-eks-cluster-sg`
  - `USMSStudentDataReadWrite` on the node role
- **Conceptual:**
  - IRSA end to end (steps 3, 5 and 6 above)
  - KMS encryption of Secrets
  - control plane logging
  - cluster upgrades
  - pod IPs from the VPC CNI (pods got `10.42.0.x`, unrelated to `10.0.0.0/16`)
  - cost

## Exercise 5 Part 3 - what Lab 08 needs from `configs/lab-07.env`

My reading of Section 16, one line each:

- `USMS_EKS_CLUSTER`: every `aws eks` call in Lab 08, and the name
  `update-kubeconfig` needs if the context is lost.
- `USMS_EKS_NAMESPACE`: every `kubectl` call. The HPA, NodePort,
  LoadBalancer and Ingress all live in `usms`.
- `USMS_EKS_NODEGROUP`: `update-nodegroup-config` for node-level scaling. On
  this build it changes a number and no nodes appear, which I should expect.
- `USMS_EKS_LB_PORTS`: the most important one. `8081,8082` are the only host
  ports Floci publishes, so a LoadBalancer Service must use one of them or it
  is unreachable. The tag cannot be added after creation without recreating
  the cluster.
- `USMS_K8S_DEPLOY_ENROLMENT`: the HPA's `scaleTargetRef`.
- `USMS_K8S_CPU_REQUEST`: `50m`, the denominator of the HPA's percentage.
  My baseline was 8m and 16m, so 16% and 32% (`outputs/lab-07-cpu-baseline.txt`),
  which tells me what "idle" looks like before load is applied.
- `USMS_K8S_DEPLOY_GATEWAY` and `USMS_K8S_SVC_GATEWAY`: the gateway is the
  service that gets exposed, first as a NodePort and then as a LoadBalancer.
- `USMS_EKS_ENDPOINT`: checking `kubectl config view --minify` still points
  at `https://localhost:6500` after a restart, before trusting any output.
- `USMS_EKS_CLUSTER_STATUS`: a guard before starting. Lab 08 should stop if
  it is not `ACTIVE` (for example in the seconds after a node group change).
- `USMS_EKS_NODE_ROLE_ARN`: the role every pod currently acts as. Lab 08
  does not change it, but any AWS call from a pod runs as this role.

Not needed by Lab 08:
- `USMS_EKS_CLUSTER_ARN`, `USMS_EKS_VERSION`
- the cluster role and both policy ARNs
- the SG
- `USMS_K8S_DEPLOY_RESULTS` and the other two Service names
- `USMS_K8S_MANIFEST_DIR`

They are there for cleanup and for Lab 09's IAM review.
