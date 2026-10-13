# Lab 07 - Deploying a microservices application on Amazon EKS

## 1. Summary

This lab built USMS a second container platform next to the ECS service from
Labs 04-06. It is an EKS cluster with a managed node group, and three
microservices in their own namespace. The microservices find each other by
DNS name only.

It created:

- **IAM:**
  - `usms-eks-cluster-role`, trusting `eks.amazonaws.com`, with
    `USMSEKSClusterPolicy`
  - `usms-eks-node-role`, trusting `ec2.amazonaws.com`, with
    `USMSEKSNodePolicy` **and Lab 01's `USMSStudentDataReadWrite`**, which
    now has three holders
- **Network:** `usms-eks-cluster-sg` in `usms-vpc`, admitting tcp/443 from
  `10.0.0.0/16` only
- **The cluster:** `usms-eks-cluster`, Kubernetes 1.30, created by the
  assumed `usms-developer-role` across all four Lab 02 subnets.
  Authentication mode `API_AND_CONFIG_MAP`, one access entry, tag
  `_lb_ports_=8081,8082`
- **The node group:** `usms-eks-nodes`, in the two private subnets only, min
  2 / max 4 / desired 2
- **In namespace `usms`:**
  - `usms-gateway` (1 replica), proxying `/enrolment/`, `/results/` and,
    after Exercise 2, `/timetable/` by Service name
  - `usms-enrolment` (2 replicas, `maxUnavailable 0`, CPU request `50m`)
  - `usms-results` (2 replicas, default strategy)
  - `usms-timetable` (Exercise 1)
  - four ClusterIP Services, five ConfigMaps, one Secret, one ServiceAccount
    and one PodDisruptionBudget

**Support path A, on Floci 2.2.0.** `aws eks create-cluster` started a real
k3s `v1.30.10+k3s1` cluster, so everything on the Kubernetes side of this
report was **observed**, not simulated:
- DNS discovery, load spreading, rollouts, rollback
- three failure modes
- a disruption budget blocking a drain
- persistence

What Floci only **records** is the AWS side around it: IAM policies, node
group sizing and the security group.

Getting `kubectl` to authenticate needed a design change the guide does not
have (Section 3.3). The guide's fallback for that case uses `k3d`, which is
not installed here.

**Verification:** `verify-lab-07.sh` reports **`PASS=30  FAIL=0`**, before
and after the exercises.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| IAM | `usms-eks-cluster-role` -> `USMSEKSClusterPolicy`; `usms-eks-node-role` -> `USMSEKSNodePolicy`, `USMSStudentDataReadWrite`; OIDC provider `oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843` (Step 21) |
| Network | `usms-eks-cluster-sg` `sg-28e66ad5386b8b1d2` in `vpc-1441470d`, tcp/443 from `10.0.0.0/16` |
| EKS | `usms-eks-cluster` `ACTIVE` 1.30, endpoint `https://localhost:6500`, 4 subnets, `API_AND_CONFIG_MAP`, `_lb_ports_` `8081,8082`; access entry `usms-developer-role` -> `system:masters`; `usms-eks-nodes` `ACTIVE` 2/4/2 in `subnet-cbeebb5f` and `subnet-2b5f6829` |
| Kubernetes | namespace `usms`; Deployments `usms-gateway` 1/1, `usms-enrolment` 2/2, `usms-results` 2/2, `usms-timetable` 1/1; matching ClusterIP Services; ConfigMaps `usms-app-config`, `usms-{enrolment,results,gateway,timetable}-conf`; Secret `usms-enrolment-secret`; ServiceAccount `usms-enrolment-sa`; PDB `usms-enrolment-pdb` |
| Unchanged | Lab 04-06's `usms-enrolment-svc`, still 2/2 on `usms-enrolment:2` behind the Lab 05 ALB |
| Files | `manifests/lab-07/` (00, 10, 20, 21, 30, 40, 60, 70); `policies/trust-eks-{cluster,node}.json`, `policies/usms-eks-{cluster,node}-policy.json`; `templates/lab-07-create-{cluster,nodegroup}.json`; `configs/lab-07.env` (21 exports); scripts listed in Section 3.10; `scripts/cleanup/lab-07-cleanup.sh` (never run) |

---

## 2. Evidence index

Section 9 has nine checkpoints. Five screenshots cover them without
repeating each other:
- Checkpoints 3, 5, 7 and 8 have their own screenshot
- Checkpoint 9 and the verification result share the fifth

Checkpoints 1, 2, 4 and 6 are proved by read-backs saved under `outputs/`
(git-ignored), quoted where used. Each screenshot was cleared before
capture.

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoint 3: cluster `ACTIVE`, 1.30, in `vpc-1441470d` with 4 subnets, the cluster SG, `API_AND_CONFIG_MAP` and `_lb_ports_`; node group `ACTIVE` 2/4/2 in the two private subnets with the node role; the access entry; `kubectl auth whoami` in `system:masters`; `can-i` = `yes`; one `Ready` node; CoreDNS and metrics-server running | [3.4](#34-checkpoint-3---cluster-node-group-and-access) |
| 02 | Checkpoint 5: three Deployments ready, three ClusterIP Services with their endpoints, three Service names resolved **from inside a pod**, three JSON answers through the gateway, a 6 / 6 tally across two pods | [3.6](#36-checkpoint-5---service-discovery-from-inside-the-cluster) |
| 03 | Checkpoint 7: `ImagePullBackOff` / `ErrImagePull`, `Pending` with `FailedScheduling` and `CrashLoopBackOff`, each with the line that diagnoses it | [3.9](#39-checkpoint-7---three-failures-on-purpose) |
| 04 | Checkpoint 8: the facts after a Floci restart, the cluster and node group re-derived from `list-clusters` / `list-nodegroups`, `diff` empty, `PERSISTENCE PROVEN` | [3.11](#311-checkpoint-8---persistence) |
| 05 | Section 8 and Checkpoint 9: `PASS=30 FAIL=0`; `lab-07.env` 21 exports, none empty; smoke test passed; nothing under `outputs/`, no root `.env`, no `.bak`, no secret in `git status`; `ls-files outputs/` only `.gitkeep` | [3.12](#312-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-24)

### 3.1 Starting point and the support probe (Steps 1-2)

The six env files from Labs 01-06 were sourced behind a guard that prints
`READY` only if the VPC, the four subnets, the developer role and the VPC
CIDR are all set. Section 6.1 explains why the guard matters.

| Check | Result |
|---|---|
| `verify-lab-02.sh` | `PASS=32 FAIL=1`: the known Floci group-reference limitation from Lab 02, unchanged |
| `verify-lab-04.sh` | `PASS=38 FAIL=1`: the same limitation, on `usms-enrolment-sg` |
| Subnets (`outputs/lab-07-subnets.txt`) | public a `subnet-5048cd0c` (1a, 10.0.1.0/24), public b `subnet-c34fe540` (1b, 10.0.2.0/24), private a `subnet-cbeebb5f` (1a, 10.0.3.0/24), private b `subnet-2b5f6829` (1b, 10.0.4.0/24). Two AZs, which EKS requires |
| `kubectl version --client` | `v1.36.1`. The server is 1.30, a skew of six minors, more than the supported one. Nothing used in this lab misbehaved |

`scripts/utilities/eks-support-probe.sh` classifies the build by error
text, as in Labs 04-06 (`outputs/lab-07-support-probe.txt`):

```text
running=true image=floci/floci:2.2.0
eks list-clusters      : OK
eks list-access-entries                  : answers
eks describe-addon-versions              : answers
  k3d      : MISSING
  kubectl client v1.36.1
PATH A  - use aws eks throughout
```

Before the real build, I ran the whole chain on throwaway clusters
(`usms-probe-eks`, `usms-probe2-eks`, `usms-probe3-eks`, all deleted). That
is where the authentication problem in 3.3 was found and solved.

### 3.2 IAM and the cluster security group (Steps 3-7)

The four policy documents in `policies/` are the guide's, written as files
and validated with `python3 -m json.tool`. Both roles carry the
`Project` / `Tier` / `Lab` tags. The read-back is
`outputs/lab-07-iam.txt`:

```text
usms-eks-cluster-role trusts eks.amazonaws.com carries USMSEKSClusterPolicy
usms-eks-node-role trusts ec2.amazonaws.com carries USMSEKSNodePolicy USMSStudentDataReadWrite
usms-eks-cluster-sg	vpc-1441470d	443	10.0.0.0/16
```

`USMSStudentDataReadWrite` now has three holders
(`outputs/lab-07-s3-policy-holders.txt`): `usms-ec2-app-role`,
`usms-ecs-task-role` and `usms-eks-node-role`. The managed-policy names are
local stand-ins, because Floci has no AWS managed policies. On Floci they
are stored and never evaluated (Section 7).

**Checkpoint 2** holds, as the three lines above show.

### 3.3 Creating the cluster, and making `kubectl` able to log in (Steps 8-11)

**The request bodies.** `scripts/utilities/write-lab-07-requests.sh` writes
`templates/lab-07-create-cluster.json` and `lab-07-create-nodegroup.json` by
lookup:
- role ARNs from `get-role`
- the SG from a filter on its name *and* `usms-vpc`
- subnets from `lab-02.env`

Since the incident in 6.1, it refuses to write a body if any of those is
empty or `None`.

**The cluster body differs from the guide in one block:**

```json
"accessConfig": {
  "authenticationMode": "API_AND_CONFIG_MAP",
  "bootstrapClusterCreatorAdminPermissions": true
}
```

On the probe clusters, the guide's body produced a cluster whose mode was
`CONFIG_MAP`, and every `kubectl` call failed with `You must be logged in to
the server (the server has asked for the client to provide credentials)`.
Floci's token webhook was rejecting the `aws eks get-token` token, because
in `CONFIG_MAP` mode no identity is mapped:
- Floci ignores the `aws-auth` ConfigMap
- it refuses access entries in that mode
- it does not implement `update-cluster-config`, so the mode cannot be
  changed after creation

The guide's two fallbacks do not help here. Troubleshooting says "this does
not arise locally", and Step 11's certificate kubeconfig depends on `k3d`.

So the mode is chosen at creation. `API_AND_CONFIG_MAP` is also the real-AWS
default for new clusters. The rest of the chain:

1. **The cluster was created as the assumed `usms-developer-role`**, as the
   guide asks. `sts get-caller-identity` returned
   `assumed-role/usms-developer-role/lab07-eks-build` before
   `create-cluster`. The variables were then unset, and `whoami.sh` was back
   to the course identity.
2. **`create-cluster --cli-read-timeout 300`.** Floci holds the HTTP request
   open while k3s starts. With the CLI's default 60 s read timeout, the CLI
   retried, and the retry failed with `ResourceInUseException` against the
   cluster the first attempt had made.
3. **`aws eks wait cluster-active`**, then **`create-access-entry
   --principal-arn $USMS_ROLE_DEVELOPER --type STANDARD --kubernetes-groups
   system:masters`.** `describe-access-entry` shows the username Floci
   assigned: `arn:aws:sts::000000000000:assumed-role/usms-developer-role/{{SessionName}}`.
4. **`create-nodegroup`, `wait nodegroup-active`, and a second `wait
   cluster-active`.** Creating the node group makes Floci *replace* the k3s
   container ("Replaced EKS cluster usms-eks-cluster to apply current node
   capacity limits"). The cluster goes back to `CREATING` for a few seconds,
   and `update-kubeconfig` refuses a cluster in that state. This explains
   why CoreDNS shows `RESTARTS 1` in screenshot 01.
5. **`update-kubeconfig --name usms-eks-cluster --alias usms-eks --role-arn
   $USMS_ROLE_DEVELOPER`.** The exec plugin assumes the role for every
   `kubectl` call, so the token's identity matches the access entry.
   `kubectl get --raw /readyz` returned `ok`.

**Step 9 reads** (`outputs/lab-07-version-issuer.txt`): `_lb_ports_` was
`8081,8082` first time, so no `tag-resource` was needed. Version and issuer
side by side came out as `1.30` and
`https://oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843`.
This build fills in the issuer, which most do not (3.10).

### 3.4 Checkpoint 3 - cluster, node group and access

![Checkpoint 3: usms-eks-cluster ACTIVE 1.30 https://localhost:6500 vpc-1441470d 4 sg-28e66ad5386b8b1d2 API_AND_CONFIG_MAP 8081,8082; usms-eks-nodes ACTIVE 2 4 2 subnet-cbeebb5f,subnet-2b5f6829 usms-eks-node-role; ACCESSENTRIES usms-developer-role; kubectl auth whoami floci:aws-iam groups system:masters system:authenticated; can-i create deployments --all-namespaces yes; one node i-acfd2de022a9365b8.ec2.internal Ready control-plane,master v1.30.10+k3s1; coredns and metrics-server Running](../../screenshots/lab07-01-checkpoint3-cluster-and-access.png)

- **The cluster is in the right place.** `ACTIVE`, `1.30`, in
  `vpc-1441470d` (`usms-vpc`), on **4** subnets, behind
  `sg-28e66ad5386b8b1d2`. A real group ID, not the `None` the first attempt
  produced (6.1).
- **The tag and the mode.** `8081,8082` is the tag Lab 08 Step 15 depends
  on. `API_AND_CONFIG_MAP` is the mode that made the access entry possible.
- **The node group is in the private pair only:** `subnet-cbeebb5f`,
  `subnet-2b5f6829`, min 2 / max 4 / desired 2, `usms-eks-node-role`. That
  is Checkpoint 3's "private subnets only" requirement.
- **Access is through IAM, end to end.** One access entry, for
  `usms-developer-role`. `kubectl auth whoami` reports the identity Floci's
  webhook mapped, `floci:aws-iam`, in `system:masters`, and `can-i create
  deployments --all-namespaces` says `yes`.
- **What the node group really is: one node.** `i-acfd2de022a9365b8.ec2.internal`,
  `Ready`, roles `control-plane,master`, `K3s v1.30.10+k3s1`, internal IP
  `172.17.0.3`. Desired 2 is recorded, and it does not make two nodes.
  Every pod in this lab ran on this one node. That shaped Exercise 4, and it
  is the Section 11 "Floci Limitation" seen directly.
- **The add-ons are running:** `coredns` (Step 16) and `metrics-server`
  (Exercise 5).

### 3.5 Three microservices (Steps 12-15)

The manifests are the guide's, applied one file at a time, each with
`rollout status` as its wait:
- `00-namespace.yaml` was applied, then `set-context --current
  --namespace=usms` made it the default
- `10-configmap-app.yaml`, `20-enrolment.yaml`, `30-results.yaml` and
  `40-gateway.yaml` followed, in that order, so the gateway's
  `proxy_pass` names existed before nginx resolved them

`outputs/lab-07-deployments.txt`:

```text
NAME             READY   DESIRED   STRATEGY        MAXUNAVAIL
usms-enrolment   2       2         RollingUpdate   0
usms-gateway     1       1         RollingUpdate   25%
usms-results     2       2         RollingUpdate   25%
10.42.0.1 - - [13/Oct/2026:18:20:50 +0000] "GET /healthz HTTP/1.1" 200 3 "-" "kube-probe/1.30" "-"
```

**Checkpoint 4** (`usms-enrolment`):
- 2/2 ready, with a ClusterIP Service and two endpoints (screenshot 02)
- CPU request `50m` (verify checks it, and `lab-07.env` records it)
- readiness every 5 s from 3 s, and liveness every 20 s from 15 s, both on
  `/healthz`, so a short unready period removes the pod from rotation long
  before liveness would restart it

The gateway log's `kube-probe/1.30` lines are the kubelet's readiness checks
arriving. The first request (`outputs/lab-07-enrolment-first.txt`) returned
JSON naming the pod and, through the downward API, its node.

### 3.6 Checkpoint 5 - service discovery from inside the cluster

![Checkpoint 5: three Deployments 2/2 1/1 2/2; three ClusterIP Services 10.100.215.3, 10.100.21.200, 10.100.80.2; endpoints enrolment 10.42.0.5:80,10.42.0.8:80, gateway 10.42.0.2:80, results 10.42.0.6:80,10.42.0.7:80; nslookup from a busybox pod resolving usms-enrolment, usms-results, usms-gateway .usms.svc.cluster.local to those ClusterIPs; gateway root, /enrolment/ and /results/ JSON; 12-request tally 6 usms-enrolment-84f6dcc497-lvxrz, 6 usms-enrolment-84f6dcc497-v487m](../../screenshots/lab07-02-checkpoint5-service-discovery.png)

- **Services and endpoints.** Each Service has one stable ClusterIP, and its
  endpoints are pod IPs in `10.42.0.0/16`. That is k3s's pod network,
  unrelated to the VPC's `10.0.0.0/16`, because there is no VPC CNI here.
- **DNS from inside a pod.** All three names resolve to exactly the
  ClusterIPs listed above. No address appears in any manifest. The gateway
  reaches its backends by these names alone.
- **One command, three services.** The gateway's own root answer, then
  `usms-enrolment` and `usms-results` through it.
- **Load spreading.** Twelve requests split **6 / 6** across two distinct
  pods. nginx holds one ClusterIP, and kube-proxy spreads connections
  beneath it.

This screenshot was retaken after the restart in 3.11, which is why the
ages read 20 m. The first capture's `nslookup | tail -2` printed blank lines
for one of the names.

**"Your turn"** (`outputs/lab-07-pod-replace.txt`): I deleted
`usms-enrolment-5cf94ff846-m2p49`. `rollout status` returned within
seconds, and the next tally was 6 / 6 across `wz5tn` and the new `kffqb`,
with no failures. The events name the creator: `replicaset/usms-enrolment-5cf94ff846
Created pod: usms-enrolment-5cf94ff846-kffqb`. It was the **ReplicaSet**,
not the Deployment, and not me.

### 3.7 ConfigMaps and Secrets (Step 17)

The Secret was generated with `kubectl create secret generic
--dry-run=client -o yaml` **into `outputs/lab-07-secret.yaml`** (mode 600).
The guide puts it in `manifests/lab-07/50-secret.yaml`. Its values are
dummies, but a credential-shaped file in a committed directory is the habit
this step warns against. `git check-ignore -v` named `.gitignore:8:outputs/*`
before it was applied.

`outputs/lab-07-secret-decoded.txt` is what a Secret is not:

```text
ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=
floci-dummy-token-not-a-real-secret
```

`base64 -d` needs no key. `kubectl set env --from=secret/usms-enrolment-secret`
wired both keys into the pods, and `printenv` inside the pod shows
`ENROLMENT_API_TOKEN` and `ENROLMENT_DB_PASSWORD` next to the four
`APP_*` values from the ConfigMap (`outputs/lab-07-secret-env.txt`).

**One consequence to record:** `kubectl set env` writes `env` entries into
the live Deployment that `20-enrolment.yaml` does not contain. `kubectl
apply` keeps them, because of its three-way merge, and Exercise 4's
re-apply left both variables in place. A cluster built fresh from
`manifests/lab-07/` would not have them. Lab 08 should either add the
`secretRef` to the manifest or accept the drift knowingly.

### 3.8 Rollouts and rollback (Step 18)

`outputs/lab-07-rollout.txt`, in order:

| Action | Revision | A pod answers | Why |
|---|---|---|---|
| ConfigMap `APP_VERSION` -> `1.1.0`, applied | 2 | `1.0.0` | Env vars are read at container start; nothing restarted |
| `kubectl annotate deployment/...` | **still 2** | | The annotation is on the Deployment's metadata, not `spec.template`. Revision 2 itself came from Step 17's `set env` |
| `kubectl rollout restart` | 3 | `1.1.0` | `restartedAt` in the template, so a new ReplicaSet |
| `kubectl rollout undo` | back to revision 2's ReplicaSet `ff96cc87d` | **`1.1.0`** | Undo restores the template, and the ConfigMap is a separate object still holding `1.1.0` |
| ConfigMap -> `1.0.0`, apply, restart | new revision | `1.0.0` | The restore the guide asks for; back at 2/2 |

`rollout history` listed revisions 1-3, and `get rs` showed three
ReplicaSets with 0 / 2 / 0 desired. That is where Kubernetes keeps rollback
state: in scaled-down ReplicaSets, up to `revisionHistoryLimit` 5. What
`rollout undo` did **not** revert, and why that matters, is Review Question
4 in the notes.

**"Your turn"** (`outputs/lab-07-results-image-roll.txt`):
`set image ... results=nginx:1.27`, watched with `kubectl get pods -w
--request-timeout=30s`, then `rollout undo`.
- `rollout history` showed **two revisions (2, 3)**, and the image was back
  to `nginx:1.27-alpine`.
- The watch peaked at **three pods**. New pod `ggr9t` reached `1/1` before
  old pod `6dd6c` began terminating.
- At two replicas the default 25% / 25% rounds to surge 1 / unavailable 0,
  so the roll had the same shape as enrolment's explicit `0 / 1`. The
  strategies only diverge at four or more replicas.

**Checkpoint 6** holds, from these two files.

### 3.9 Checkpoint 7 - three failures on purpose (Step 19)

Each failure was produced, then waited for with
`scripts/utilities/wait-pod-state.sh`, which polls until a pod reaches a
waiting reason or phase. `kubectl wait -l` does not work here, because it
also matches the old, healthy pods.
- a broken tag: `set image ... results=nginx:this-tag-does-not-exist`
- `labs/lab-07-eks/failure-toobig.yaml`: 64 CPU, 256 Gi
- `labs/lab-07-eks/failure-crasher.yaml`: busybox printing two lines and
  exiting 1

![Checkpoint 7: get pods showing usms-crasher Error with 2 restarts, usms-results-6cbd65f4d7-6gsh9 ErrImagePull while the two old results pods keep Running, usms-toobig Pending; events reason=Failed: Failed to pull image "nginx:this-tag-does-not-exist": rpc error: code = NotFound, Error: ErrImagePull, Error: ImagePullBackOff; FailedScheduling 0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory; logs --previous: fatal: no database configured, usms-crasher starting](../../screenshots/lab07-03-checkpoint7-failure-modes.png)

| Symptom | Diagnosed by | What it says | Layer |
|---|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | Events, `reason=Failed` | `NotFound`: the tag does not exist in `docker.io/library/nginx` | The kubelet, on the node, cannot get the image |
| `Pending` | `describe pod`, `FailedScheduling` | `0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory`, and no preemption victims | The scheduler: no node fits the *requests* |
| `Error` / `CrashLoopBackOff` | `logs --previous` | `fatal: no database configured` | The application: it started and exited 1 |

**`describe` comes before `logs`.** For the first two failures there are no
logs at all, because no container ever ran. Only the events can say why.
For the third, `--previous` is essential: the current container is already
a fresh restart.

The `get pods` line is the rolling update protecting the service.
`usms-results` stayed at two `Running` pods, because the new ReplicaSet's
pod never became ready.

The three event lines name `n6r82`, the first attempt's pod in the **same**
ReplicaSet `6cbd65f4d7`. The same template gives the same hash, so it is
the same failure. The original attempt used a `describe | grep` that
printed nothing, and the retake switched to the events query. The full
event log is in `outputs/lab-07-events.txt`.

Afterwards, `usms-results` was rolled back, both pods were deleted, and
`get pods` showed the five expected pods.

### 3.10 ECS beside EKS, and IRSA (Steps 20-21)

**Step 20** (`outputs/lab-07-ecs-vs-eks.txt`). With both platforms running,
ECS showed `2 2 .../usms-enrolment:2 1 1`. EKS showed the three Deployments
with their selectors, and the three ClusterIP Services. The filled-in
comparison table and the two-sentence choice (ECS on Fargate for USMS) are
in the notes.

**Step 21** (`outputs/lab-07-irsa.txt`). This build went further than the
guide expects:

```text
OIDC issuer: https://oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843
arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843
serviceaccount/usms-enrolment-sa created
... EKS Pod Identity injection is off for cluster usms-eks-cluster: Kubernetes only accepts an https admission webhook URL, and Floci serves HTTP ...
no AWS_* env vars injected
ls: /var/run/secrets/eks.amazonaws.com: No such file or directory
```

Of the guide's six IRSA steps:
- **Done:** step 1 (an issuer is published, though at a real-AWS host with
  no document behind it), step 2 (the IAM provider is registered), and
  step 4 (the ServiceAccount exists)
- **Not reached:** step 5. Floci turns its mutating webhook off without
  TLS, so a pod using `usms-enrolment-sa` received no token and no `AWS_*`
  variables. Steps 3 and 6 therefore had nothing to act on

**IRSA is not configured, and I do not claim it is.** The pods' AWS
permissions remain the node role's: every pod on the node carries
`USMSStudentDataReadWrite`. I did not `curl` the issuer URL, because it
points at real AWS. A probe-time request returned AWS's 404.

### 3.11 Checkpoint 8 - persistence

`scripts/utilities/lab-07-restart-facts.sh`:
- **finds the cluster** with ``list-clusters --query 'clusters[?@==`usms-eks-cluster`] | [0]'``
  and the node group with `list-nodegroups`, never with a shell variable
- **prints the AWS facts:** cluster status, version, endpoint, subnet count,
  auth mode, `_lb_ports_`, node group sizing and subnet count, and the
  access entries
- **prints the Kubernetes facts:** the namespace, Deployments with ready
  count and image, Services with type and ClusterIP, and the ConfigMap,
  Secret and ServiceAccount names

The facts were taken before `floci-down` and after `floci-up`. The wait
after the restart was `aws eks wait cluster-active`, then
`scripts/utilities/wait-kube.sh 300`, which polls `/readyz` and the three
rollouts. No `sleep` was used.

![Checkpoint 8: after restart, cluster from list-clusters usms-eks-cluster ACTIVE 1.30 https://localhost:6500 4 API_AND_CONFIG_MAP 8081,8082; nodegroup from list-nodegroups usms-eks-nodes ACTIVE 2 4 2 2; access entry usms-developer-role; namespace usms Active; usms-enrolment 2, usms-gateway 1, usms-results 2 nginx:1.27-alpine; Services with ClusterIPs 10.100.215.3, 10.100.21.200, 10.100.80.2; four ConfigMaps; secret usms-enrolment-secret; diff empty; PERSISTENCE PROVEN](../../screenshots/lab07-04-checkpoint8-persistence.png)

`diff` printed nothing: **PERSISTENCE PROVEN**. The ClusterIPs survived
unchanged, which shows the k3s datastore itself persisted, not just
manifests being re-applied. Floci keeps it in the Docker volume
`floci-aws-floci-course-eks-usms-eks-cluster`. The access entry and the
`API_AND_CONFIG_MAP` mode survived too, so `kubectl` worked straight after
the restart.

The ServiceAccount is not in this capture. Step 21 had not run yet when the
facts were taken, because I ran Steps 20-21 after the restart.

### 3.12 Verification and hygiene

`configs/lab-07.env` is written by `scripts/utilities/write-lab-07-env.sh`,
the guide's Step 23 heredoc moved into a script. Every value is a lookup.

`scripts/utilities/verify-lab-07.sh` is the guide's 30 checks with three
changes:
- **the `.gitkeep` fix** to "no secret is tracked by git", as in Labs 04-06
- **`grep -E` with `|=None$`** in the empty-value check. BSD `grep` treats
  `\|` literally, which gives false passes
- **the API check is `kubectl get --raw /readyz`**, which is meaningful with
  exec-plugin authentication

![Section 8 and Checkpoint 9: verify PASS=30 FAIL=0; lab-07.env all values populated; exports 21 cluster=usms-eks-cluster ns=usms lb_ports=8081,8082 endpoint=https://localhost:6500 cpu=50m; SMOKE TEST PASSED; nothing under outputs/, no root .env, no .bak, no secret manifest in git status; git ls-files outputs/ shows only outputs/.gitkeep](../../screenshots/lab07-05-verify-env-and-hygiene.png)

- **`PASS=30 FAIL=0`.** Path A has no expected failures, and none occurred.
  Verify was re-run after the exercises with the same result.
- **21 exports, none empty or `None`.** The five Lab 08 values on one line:
  `usms-eks-cluster`, `usms`, `8081,8082`, `https://localhost:6500`, `50m`.
- **The Section 8.1 smoke test passed**, through the gateway to both
  backends.
- **Git hygiene:**
  - `git status` lists nothing under `outputs/`, no root `.env`, no `.bak`
    (the `sed -i.bak` copy was removed first) and no secret manifest
  - `git ls-files outputs/` lists only `.gitkeep`
  - `git check-ignore -v` names `.gitignore:8:outputs/*` (Exercise 5
    output, and before Step 17's apply)
- **Cleanup:** `scripts/cleanup/lab-07-cleanup.sh` parses with `bash -n` and
  has **never been run**. It asks for `DELETE-LAB-07`, deletes in
  dependency order (namespace, node group, cluster, the leftover k3s volume,
  the OIDC provider, detach, roles, our two policies, the SG), and never
  touches `USMSStudentDataReadWrite`.

**Checkpoint 9 (Step 24)** is complete up to the commit, which I make
myself. Everything to be committed is untracked and visible in `git
status`, and nothing that should not be committed is.

**Scripts written for this lab:**
- `scripts/utilities/`: `eks-support-probe.sh`, `write-lab-07-requests.sh`,
  `wait-pod-state.sh`, `wait-kube.sh`, `lab-07-restart-facts.sh`,
  `write-lab-07-env.sh`, `verify-lab-07.sh`, `lab-07-exercise-edits.py`
- `labs/lab-07-eks/`: `lab07-readiness.sh`, `failure-toobig.yaml`,
  `failure-crasher.yaml`, `exercise3-broken.yaml`
- `scripts/cleanup/lab-07-cleanup.sh`

---

## 4. Exercises 1-5

Full commands and output are in [`exercises.md`](exercises.md).

| # | Deliverable | Result |
|---|---|---|
| 1 | `usms-timetable` | `70-timetable.yaml`: ConfigMap, Deployment (1 replica, requests `50m` / `32Mi`, readiness on `/healthz`) and ClusterIP Service in one file, `app` / `project` / `tier` labels; dry-run validated; four Deployments and four Services; JSON naming `usms-timetable-75b4cd7c79-6h8vl` |
| 2 | `/timetable/` route | `apply` changed only the ConfigMap (`deployment unchanged`, same ReplicaSet). **`rollout restart`** made revision 2 and ReplicaSet `5c46c9c6bf`, with `restartedAt` in the template as the recorded cause; four JSON answers (root, enrolment, results, timetable) in one command |
| 3 | Two faults | Found with `get endpoints` -> `<none>`, `--show-labels` against the selector, `get pods -l ...version=v2` -> nothing, and `Readiness probe failed ... 404` plus an in-pod `wget` (`/healthz` 404, `/` 200). One line each: selector `v2`->`v1`, probe `/healthz`->`/`. Fix 1 alone left both pods in `notReadyAddresses`; after fix 2, **two endpoints**. Deleted |
| 4 | Survive a node going away | Advisory `topologySpreadConstraints` and preferred anti-affinity, plus an **enforced** PDB `minAvailable 1` (new object). One node, said so. Drain: first eviction allowed, second **refused by the PDB**, one endpoint kept, replacement `Pending` until `uncordon`. Smoke loop **62,518 ok / 1 failed** in 70 s; the one in-flight failure is recorded, and a `preStop` hook is the fix |
| 5 | Lab 08 hand-off | Metrics API **present**: 8m (16%) and 16m (32%) of the 50m request. `USMSStudentDataReadWrite` v1 on three roles; bucket `arn:aws:s3:::usms-student-data` and object ARN `.../*` **read from the policy document**; `head-bucket` 404, exit 254. Both files git-ignored. Part 3 in the notes |

---

## 5. Review questions

Answered in full in [`../../notes/lab-07-notes.md`](../../notes/lab-07-notes.md).
Summarised:

1. **`ACTIVE` describes the control plane; `Pending` is the scheduler finding
   no data-plane capacity.** Two causes: no schedulable worker nodes (no node
   group, or nodes that cannot join because of the node role), or nodes too
   small for the requests. I produced the second in Step 19.
2. **Swapped trust policies change nothing on Floci** (trust is never
   evaluated). On real AWS, Step 8 fails at once because EKS cannot assume
   the cluster role. With that fixed, Step 10's nodes boot without
   credentials and never register, so `NodeCreationFailure` arrives slowly
   and indirectly.
3. **Readiness gates traffic; liveness restarts.** A database-dependent
   check wired to liveness turns a slow dependency into a fleet-wide restart
   loop. Exercise 3 showed the readiness side of the mistake.
4. **Undo restores the template, not the referenced ConfigMap.** It is a
   real rollback of the template and not of the configuration. Fix it by
   versioning config into the template's identity (hashed ConfigMap names
   or a checksum annotation) and keeping manifests in Git.
5. **At two replicas the default rounds to surge 1 / unavailable 0**, the
   same shape as enrolment's. They diverge at four or more replicas.
   `maxUnavailable 0` suits enrolment week; the default suits a service
   with headroom. ECS's 100 / 200 is closer to `maxUnavailable 0`.
6. **A Secret is base64, and I decoded one without a key.** It provides RBAC
   separation and optional encryption at rest, not protection in Git. On
   real EKS I would use KMS envelope encryption, keep values in Secrets
   Manager pulled through a pod-level role, and commit only sealed or
   SOPS-encrypted files.
7. **ECS on Fargate for USMS.** It means less standing work for a small,
   seasonal team. Harder here: two IAM lifecycles, a second API and identity
   system, and no per-pod AWS role by default. Kubernetes gave name-based
   discovery, built-in rollout history and a disruption budget.

---

## 6. Problems encountered

### 6.1 The first build ran with empty variables, and Floci accepted all of it

Stages 2-4 first ran in a terminal where the env files were not loaded.
Every command "succeeded":
- `create-security-group --vpc-id ""` put `usms-eks-cluster-sg` in
  **`vpc-default`**
- the ingress rule's CIDR came out as `None`
- the request writer's SG lookup in `usms-vpc` returned `None`, and
  **`create-cluster` accepted `securityGroupIds: ["None"]`**
- `create-access-entry` with an empty principal failed on the client and was
  lost in the scroll
- `update-kubeconfig --role-arn ""` wrote `--role ""` into the exec plugin

The first Checkpoint 3 screenshot showed `ParamValidation: Invalid length
for parameter RoleArn, value: 0` from every `kubectl` call, and an empty
access entry list.

**The fix:**
1. **Removed the bad objects:** I deleted the node group, then the cluster
   (each with its `wait ...-deleted`), the leftover k3s volume, the stray SG
   and the `usms-eks` context. The IAM roles and policies did not depend on
   any variable and were kept.
2. **Proved the corrected sequence on a throwaway cluster** before the
   rebuild. This found 6.3.
3. **Re-ran Stages 2-4 behind the `READY` guard.**
4. **Hardened the request writer:**
   `write-lab-07-requests.sh` now stops with `STOP - EKS_CLUSTER_SG is empty
   or None` rather than writing a body with a hole in it.

This is Lab 06 problem 2 again: Floci validates much less than AWS, so
validation has to come from the scripts.

### 6.2 `kubectl` could not authenticate

Section 3.3 has the detail. The guide's request body produces a
`CONFIG_MAP`-mode cluster that no identity can log in to on Floci 2.2.0.
The mode cannot be changed afterwards, and the guide's two fallbacks do not
apply. I solved it on probe clusters before the real build:
`accessConfig` at creation, an access entry, and `--role-arn` in the
kubeconfig.

The side effect is useful: on this build, **access entries are really
enforced**. Section 11 of the guide lists them as "not enforced" locally.

### 6.3 The node group recreates the cluster

`create-nodegroup` makes Floci replace the k3s container, and the cluster
drops back to `CREATING`. `wait nodegroup-active` returns first, so
`update-kubeconfig` would fail. The fix is a second `wait cluster-active`,
chained in the same command. The replacement keeps the access entry; I
verified this on a probe cluster.

### 6.4 `create-cluster` timed out and then collided with itself

Floci answers `CreateCluster` only once k3s is up. The CLI's 60 s read
timeout fired, the automatic retry hit the cluster the first attempt had
already created, and `ResourceInUseException` came back. The fix is
`--cli-read-timeout 300`.

### 6.5 Smaller ones

- **`kubectl wait -l` with a selector matches old, healthy pods** during a
  rollout, so it cannot wait for "some pod is in `ImagePullBackOff`".
  `wait-pod-state.sh` polls for the state instead.
- **Two retakes.** On the first captures:
  - Checkpoint 5's `nslookup | tail -2` printed blank lines for one name
  - Checkpoint 7's `describe | grep` printed nothing

  Both commands were replaced (3.6, 3.9) and the screenshots retaken.
- **Deleting a cluster leaves its Docker volume behind**
  (`FLOCI_STORAGE_PRUNE_VOLUMES_ON_DELETE=false`). `lab-07-cleanup.sh`
  removes it. Without that, a re-created cluster would reuse the old k3s
  datastore.

---

## 7. Floci limitations versus real AWS

| Behaviour | Floci 2.2.0 (observed) | Real AWS |
|---|---|---|
| `create-cluster` | Starts a k3s 1.30 container in about 1 minute; the HTTP call blocks until it is up | Control plane in AWS-owned accounts, 10-15 min, returns at once with `CREATING` |
| Default `authenticationMode` | `CONFIG_MAP`, with `aws-auth` ignored: nobody can log in | `API_AND_CONFIG_MAP`; the creator is mapped |
| `update-cluster-config --access-config` | Not implemented | Supported (one-way, towards `API`) |
| Access entries | Stored **and enforced** by Floci's token webhook | Enforced |
| Kubernetes API, controllers, scheduler | Upstream k3s, really running | Upstream EKS |
| CoreDNS, kube-proxy, metrics-server | Running | Add-ons |
| Managed node group | `ACTIVE` record (2/4/2, `t3.small`, AMI, labels); **no nodes**. Creating it replaces the k3s container | Real EC2 instances in an ASG |
| Nodes | One k3s server node, `control-plane,master`, schedulable | Worker nodes; control plane invisible |
| Pod IPs | `10.42.0.x` (k3s flannel) | From the VPC subnets (VPC CNI) |
| Cluster / node IAM roles, policies | Stored, never evaluated | Assumed; missing permissions fail creation or registration |
| Cluster security group | Stored; `None` accepted as an ID | Validated, attached to the control plane ENIs |
| `_lb_ports_` tag | Decides which host ports the cluster publishes (8081, 8082) | An ordinary tag |
| API endpoint | `https://localhost:6500` | `https://<id>.gr7.<region>.eks.amazonaws.com` |
| OIDC issuer | Filled in, at a real-AWS host with no document | Published, reachable |
| IAM OIDC provider | `create-open-id-connect-provider` works | Works |
| IRSA / Pod Identity injection | **Off** (webhook needs HTTPS; Floci runs HTTP) | Injected token and env vars |
| Secrets encryption at rest | Not available | KMS envelope encryption |
| Control plane logging, upgrades | Not meaningful | Supported |
| Persistence | Cluster, node group, access entries, and the k3s datastore (in a Docker volume) all survive a restart | n/a |
| Deleting a cluster | Leaves the k3s volume behind | Nothing to leave |
| Cost | Free | Per cluster-hour, plus nodes |

**Observed, recorded only, conceptual** (Section 11's three categories, for
this build):
- **Observed:** the whole Kubernetes object model, DNS discovery, load
  spreading, rollouts and rollback, readiness gating, the three failures,
  the PDB, CPU metrics, persistence, and access entries being enforced
- **Recorded only:** IAM, node group sizing, the security group, the node
  role's S3 policy
- **Conceptual:** IRSA end to end, KMS-encrypted Secrets, control plane
  logging, upgrades, VPC pod networking, cost

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh          # docker-compose.yml pins floci/floci:2.2.0
source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env
source configs/lab-05.env
source configs/lab-06.env
source configs/lab-07.env
aws eks wait cluster-active --name usms-eks-cluster && ./scripts/utilities/wait-kube.sh 300
./scripts/utilities/verify-lab-07.sh
```

Expected: `PASS=30  FAIL=0`.

If the kubeconfig context is missing on another machine, recreate it with
`aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks
--role-arn "$USMS_ROLE_DEVELOPER"`.
