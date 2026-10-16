# Lab 08 - EKS scaling and service exposure - my notes

**Support path: A, on Floci 2.2.0**, as in Lab 07, with three things this
build cannot do:

- **`update-nodegroup-config` does not exist.** It returns
  `UnknownOperationException: Unknown operation: POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`,
  and so does `list-updates`. Step 10's 2/6/3 could not be applied; the node
  group stays at 2/4/2.
- **`_lb_ports_` does nothing.** The Floci 2.2.0 binary contains no reference
  to the tag. The k3s node container publishes only 6443 -> `localhost:6500`,
  so `localhost:8081` and `:8082` never answer.
- **There is no ingress controller.** Floci starts k3s with
  `--disable=traefik`, so no IngressClass exists.

What *does* work is more than the guide expects:

- **metrics-server is installed**, so the HPA computes real percentages.
- **k3s's ServiceLB fulfils `type: LoadBalancer`.** It runs a
  `svclb-usms-gateway` DaemonSet and writes the node's address,
  `172.17.0.3`, into `EXTERNAL-IP`. That address answers inside the cluster,
  but not from the Mac.

**The node is a t3.small on purpose.** Its capacity is the whole Docker VM
(10 CPUs, 8 GB), but Floci starts the kubelet with
`system-reserved=cpu=8000m`, so allocatable is **1930m CPU and about 1.5 GiB**.
Every scheduling number in this lab is against that, not against my laptop.

## Step 3 "Your turn" - ten times the traffic

1. **Dimension 1 first (more pods):** raise the HPA's `maxReplicas`, or
   pre-scale `replicas`, because it is instant and reversible. Check
   `kubectl get hpa` (is CPU per pod falling?) and
   `kubectl get pods | grep Pending` (did they all fit?).
2. **Dimension 3 as soon as anything is `Pending` (more nodes):** raise the
   node group's `desiredSize` and `maxSize`. Check that the new nodes are
   `Ready` and the pending pods scheduled. On this node, 1930m allocatable at
   50m per pod is roughly 25 more pods before that wall.
3. **Dimension 2 only if one pod is too small for one request (bigger
   pods):** a higher request restarts every pod and changes the HPA's
   denominator. So I would re-read the HPA arithmetic before and after.
4. **Dimension 4 only as a planned change (bigger nodes):** it cannot happen
   in place. It means a new node group with larger instances, then cordon,
   drain and delete the old one. Check that PDBs leave something to drain
   with.

## Step 4 - scaling by hand (`outputs/lab-08-step4-scale.txt`)

- **`kubectl scale --replicas=5`:** ReplicaSet `usms-enrolment-8686648d`
  before and after. It was scaled to 5, and no new ReplicaSet appeared.
- **Rollout status counted "2 of 5 ... 3 of 5 ... 4 of 5 available".** The
  endpoints grew as each pod passed readiness, not as it started.
- **40 requests through the gateway split 9/8/8/8/7 across five pods,** with
  no gateway restart.
- **Scaling back to 2** left the two original addresses,
  `10.42.0.2` and `10.42.0.6`.

## Step 5 - drift (`outputs/lab-08-step5-drift.txt`)

The cluster said 6 and line 35 of the file said `replicas: 2`. An `apply` of
the unchanged file put it back to 2 without a word: `deployment.apps/usms-enrolment configured`.

`kubectl diff` showed `-  replicas: 2 / +  replicas: 3` and **exited 1**.
After the restore it exited 0. Since Step 8, the HPA owns this field, and the
file's `replicas: 2` is only a starting value.

## Step 6 - QoS (`outputs/lab-08-step6-qos.txt`)

All six application pods, CoreDNS and metrics-server are `Burstable`
(50m / 200m CPU, 32Mi / 128Mi memory). The scheduler's table: requests 500m
(25%) and limits 1200m (62%) **of allocatable 1930m**, not of the 10
cores.

**"Your turn" - the gateway as `Guaranteed`.**
- I used `kubectl set resources --requests=cpu=200m,memory=128Mi
  --limits=cpu=200m,memory=128Mi`. Raising the requests to the existing
  limits leaves the ceiling unchanged, so the pod can do exactly what it
  could before.
- The QoS class went `usms-gateway-5c46c9c6bf-8nl2p Burstable`, then
  `usms-gateway-588db98db5-wc2w2 Guaranteed`, then
  `usms-gateway-5c46c9c6bf-gsghw Burstable`.
- **The pod was replaced both times.** Resources are part of the pod
  template, and a running container's requests cannot be edited (dimension
  2). That is why a VerticalPodAutoscaler restarts what it resizes, and why
  it is used far less than the HPA.
- **When I would want `Guaranteed`:** for something that must be the last to
  go under memory pressure and must never be CPU-throttled below its
  reservation. On USMS that is the database tier, or this gateway, since
  every request passes through it. It is not worth it for the stateless
  backends.

## Step 7 - metrics (`outputs/lab-08-step7-metrics.txt`)

`v1beta1.metrics.k8s.io kube-system/metrics-server True`, `metrics API:
AVAILABLE`, and every pod at `1m` idle. That is 2% of the 50m request,
exactly the `cpu: 2%/50%` the HPA shows at rest. No install was needed, and
no `--kubelet-insecure-tls`.

## Steps 8-9 - the HPA moving (screenshot 01)

| Time (UTC) | CPU/target | Replicas | What happened |
|---|---|---|---|
| 14:21:37-14:22:00 | 2% | 2 | Load generator just started |
| 14:22:11 | 23% | 2 | Load arriving |
| 14:22:22 | 43% | 2 | |
| 14:22:30 | | | Event `New size: 3; reason: cpu resource utilization (percentage of request) above target` |
| 14:22:34 | 61% | 3 (ready 2) | The new pod is not ready yet |
| 14:22:45 | 61% | 3 / 3 | |
| 14:23:19 onwards | 42% | 3 | Settled below the target at three pods |
| 14:30:45 | | | Event `New size: 2; reason: All metrics below target` |

**The arithmetic.** At the moment of the decision, `ceil(2 × 61 / 50)` =
`ceil(2.44)` = **3**. The scale-up policies would have allowed +2 (Percent
100 = +2, Pods 2 = +2, `selectPolicy: Max`). The recommendation was only 3,
so the policy was not what limited it.

**At three pods, 42% is below 50%**, which gives `ceil(3 × 42 / 50)` =
`ceil(2.52)` = 3, so the HPA stayed put. The load source was the limit:
each `usms-loadgen` pod was pinned at its 300m CPU limit
(`kubectl top` in my test run read 301m, 301m, 300m). The guide's 2 -> 4
needs more load than three busybox loops can make.

**Scale-in.** Load stopped just after the watch ended at 14:23:42. The
scale-in arrived at 14:30:45, about seven minutes later: the 300 s
stabilisation window, plus the one-pod-per-60 s policy, plus the time CPU
took to fall.
For five minutes the HPA held a pod it no longer needed, by design.

**An honest oddity.** While the cluster sat idle for hours,
`usms-enrolment-hpa` logged `Warning FailedGetScale Unauthorized` six times
(07:03 to 13:32 UTC). The controller briefly failed to read the
Deployment's scale subresource. It recovered on its own: `ScalingActive
True ValidMetricFound`. I think it is the cluster's token webhook path
(Floci's authenticator) being unavailable for a moment, but that is a guess.
k3s keeps events for one hour. The first screenshot attempt, taken hours
after the run, therefore showed only this warning and no rescale events, so
I re-ran the load and captured it within the hour.

## Step 10 - the node group from the AWS side (`outputs/lab-08-step10-nodegroup.txt`)

- **Before:** `usms-eks-nodes ACTIVE`, 2/4/2, `t3.small`, the two private
  subnets, labels `tier=app` and `workload=usms`.
- **`update-nodegroup-config ... 2/6/3`:** `UnknownOperationException`.
  `list-updates` gave the same, and `describe-update` gave `No update`.
- **After:** still 2/4/2. Kubernetes sees one node.

So, recorded as observed:
- **this build cannot even record the change**, never mind enact it
- the *Update object* pattern (an asynchronous `InProgress` update, polled
  with `describe-update`) is conceptual here

The point of the step survives. `replicas` (moved by the HPA, in the
cluster) and `desiredSize` (moved by nobody, on the AWS side) are two
different integers behind two different APIs. On this build that is
literally true: only one of the two APIs exists.

**The alternative I did not use.** Deleting and recreating the node group
with 2/6/3 would satisfy verify's `maxSize = 6` check. But on Floci a node
group change replaces the k3s container (Lab 07, report 6.3). That would
risk the whole running application for a number that changes nothing. Verify
records it as its one failure instead.

## Step 11 - labels and the `nodeSelector`

The node group declares `workload=usms` and `tier=app`, and Floci passes them
to the kubelet as `--node-labels`. But **the labels had not reached the
node.** `kubectl get nodes -L workload,tier` showed empty columns. Kubelet
`--node-labels` apply only when a node first registers, and this node
registered when the cluster was created, before the node group existed.

My first `apply` of the `nodeSelector` therefore *timed out*. The new pod
could not schedule, and `maxUnavailable: 0` kept both old pods serving, so
the timeout broke nothing. I labelled the node by hand
(`kubectl label node --all workload=usms tier=app`), as the guide's Part 2
allows. On real EKS the node group would have done it.

The guide's own Python edit would not have worked here either. Its anchor
(`spec:` directly followed by `containers:`) disappeared when Lab 07
Exercise 4 put `topologySpreadConstraints` first, and it would still have
printed "added". `scripts/utilities/lab-08-edits.py nodeselector` anchors on
whatever comes first, and refuses to claim success otherwise.

**Enforcement proven** (screenshot 02):
- The `nonexistent` selector gave pod `usms-enrolment-6d554c6b89-j64dk`
  `Pending` with `0/1 nodes are available: 1 node(s) didn't match Pod's node
  affinity/selector`.
- Both old pods stayed `Running`.
- Re-applying the file put `workload=usms` back, and `kubectl diff` was
  clean.

**Cluster Autoscaler versus Karpenter, in one sentence each.**
- Cluster Autoscaler raises the desired size of a node group *you defined*
  when pods are `Pending`.
- Karpenter launches EC2 capacity *it chooses* to fit the pending pods,
  without needing a matching node group.

Neither is installed. Both need IRSA (not available here, Lab 07 Step 21)
and real EC2 capacity.

## Step 12 - disruption budgets (screenshot 02)

- **`usms-gateway-pdb`** (`minAvailable 1`, one replica): `ALLOWED
  DISRUPTIONS 0`.
- **`usms-enrolment-pdb`** (`maxUnavailable 1`): `1`. This redefines Lab 07
  Exercise 4's `minAvailable: 1`. With the HPA able to run 8 pods,
  `minAvailable: 1` would allow 7 down at once, whereas `maxUnavailable: 1`
  scales with the count. `manifests/lab-07/21-enrolment-pdb.yaml` was
  removed, so one file defines the object.
- **The eviction API** POSTed to `pods/<pod>/eviction` gave `Error from
  server (TooManyRequests): Cannot evict pod as it would violate the pod's
  disruption budget.`
- **`kubectl delete pod`** went straight through. `usms-gateway-5c46c9c6bf-v6bh6`
  was deleted and `pnhvn` replaced it in 5 s. A PDB constrains evictions, not
  deletes.
- **Something I did not expect:** `kubectl drain --dry-run=client` printed
  `drained (dry run)` and listed the gateway pod as evictable. A client-side
  dry run never calls the eviction API, so it cannot see a PDB. Only a real
  drain, or a server-side eviction, finds out.

The first attempt at this screenshot is worth recording too. It ran in a
terminal without the env files and skipped the setup blocks, so the eviction
**succeeded** (`201`), because there was no PDB yet. That proves the
contrapositive, and it is why the setup blocks matter.

## Step 13 - port-forward (`outputs/lab-08-step13-15-host.txt`)

- The ClusterIP `10.100.21.200` from the Mac gave no route.
- `kubectl port-forward svc/usms-gateway 18080:80` returned all three JSON
  answers.

**The two properties that disqualify it from anything but debugging:**
- **One pod.** Every request through the tunnel landed on the same gateway
  pod (`usms-gateway-5c46c9c6bf-pnhvn`), with no Service load balancing at
  that hop. Spreading still happened *behind* the gateway (`lgvps` ×5,
  `9zzrj` ×1), because the gateway calls the enrolment Service.
- **It exists only while my command runs.** After I killed it,
  `localhost:18080` was gone. Every byte also went through the API server.

A practical trap: backgrounded with `&`, `kubectl port-forward` died with
`aws: [Errno 32] Broken pipe`. The `aws eks get-token` exec plugin needs a
usable stdin. `</dev/null` fixed it.

## Steps 14-16 - the rest of the ladder (screenshot 03)

- **NodePort** `usms-results-np 80:30080/TCP` answered on the node's address,
  `172.17.0.3:30080`, from a pod. From the Mac, `localhost:30080` gave no
  answer, because the node container publishes only 6443. The
  `port-forward svc/usms-results-np 30080:80` fallback works, but it proves
  the Service, not the NodePort.
- **LoadBalancer:** `type=LoadBalancer clusterIP=10.100.21.200 nodePort=32125
  external=172.17.0.3`. All three rungs are on one object.
  - **Fulfilled by k3s ServiceLB** (`svclb-usms-gateway` DaemonSet), not by
    any AWS controller. The three AWS annotations were ignored, as the
    manifest says.
  - `172.17.0.3:80/enrolment/` answered from a pod.
  - From the Mac, `172.17.0.3` (Docker's internal bridge), `localhost:8081`
    and `localhost:8082` gave nothing.
- **Ingress:** `kubectl get ingressclass` returned `No resources found`. The
  Ingress `CLASS <none>`, `ADDRESS` empty, and `Events: <none>`: nothing
  even tried. The paths are stored correctly: `/enrolment -> usms-enrolment`,
  `/results -> usms-results`, `/ -> usms-gateway`, with backends resolved
  to pod IPs in `describe`.

**Moving `usms-gateway` to `LoadBalancer` needed one repository change the
guide misses.** `manifests/lab-07/40-gateway.yaml` also defined the gateway
Service, as a `ClusterIP`. Re-applying it, which Exercise 2 requires, would
silently turn the gateway back into a ClusterIP. That is Step 5's drift,
caused by two files owning one object. `lab-08-edits.py gateway-svc`
removed that block. `50-service-loadbalancer.yaml` is now the only
definition, and `kubectl diff` on both Lab 07 files is clean.

**Step 16's written alternative** (no controller here): which Lab 05 `elbv2`
commands would the AWS Load Balancer Controller have run, and in what order?
1. **`create-load-balancer`**: `scheme: internet-facing`, in the subnets tagged
   `kubernetes.io/role/elb=1`, which are Lab 02's public pair.
2. **`create-target-group --target-type ip`**, once per backend Service:
   `usms-enrolment`, `usms-results` and `usms-gateway`. `healthcheck-path:
   /healthz` and `target-type: ip` are the annotations behind it.
3. **`create-listener --port 80`**, from `listen-ports`.
4. **`create-rule`**, one per path. The controller orders them so that
   longest prefix wins. Lab 05 used `--priority 10` by hand.

After that, `register-targets` and `deregister-targets` follow the
Endpoints continuously. In Lab 05, ECS did that.

## Step 17 - Practical 2 and Practical 4, compared with both running

Both stacks were up (`outputs/lab-08-step17-compare.txt`):
- **ECS:** 2 / 2 on `usms-enrolment:2`, grace 60. Scalable target 2-10 with
  two target-tracking policies and one step policy. Target group type `ip`,
  rule priority 10 (`/alb-health`, a fixed response).
- **EKS:** both HPAs, five Services, the Ingress and two PDBs.

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | `desiredCount` on `usms-enrolment-svc` | `spec.replicas` on the Deployment `usms-enrolment` |
| Who writes it? | Application Auto Scaling, through a policy the alarm invokes | The HPA controller in kube-controller-manager |
| Where does that thing run? | In AWS, outside anything I own | In the cluster's control plane (on EKS AWS operates it, but it is still *my cluster's* controller) |
| Where does the metric come from? | CloudWatch (`AWS/ECS` CPU, ALB request count, my `USMS/Enrolment` metric) | metrics-server -> `metrics.k8s.io`, scraped from the kubelets |
| What does "50% CPU" mean - 50% of what? | Of the CPU **reserved for the task** (task-level `cpu`) | Of the container's **request** (50m), not the limit (200m), not the node |
| How is scale-in slowed down? | `ScaleInCooldown` (300 s), plus target tracking's 15-evaluation low alarm | `behavior.scaleDown.stabilizationWindowSeconds: 300` plus `Pods 1 / 60s`, `selectPolicy: Min` |
| What happens if there is no capacity for the new instance/pod? | Fargate finds capacity; an ECS task essentially never waits for a host | The pod sits `Pending` until a node frees up or is added (Step 11's two control loops) |
| What creates the alarms, if anything? | Target tracking creates two CloudWatch alarms per policy (four here) | Nothing. The controller polls every 15 s, with no alarm objects |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | Five: security group, load balancer, target group, listener, rule (plus the service's load balancer link) | None. One Ingress, and the controller would create the ALB, target groups, listener and rules |
| What is the target type, and why? | `ip`, because each Fargate task has its own ENI and address | `ip` (`target-type: ip`, and `nlb-target-type: ip` on the Service), because with the VPC CNI each pod has its own VPC address, which skips the NodePort hop |
| How are targets registered and deregistered? | ECS registers and deregisters each task as it starts and stops | The controller watches the Service's Endpoints and calls `register-targets` / `deregister-targets` |
| How are competing routing rules disambiguated? | Numeric `--priority`, lowest first | Longest matching path; across Ingresses in a group, `group.order` |
| What would I change to move this to another cloud? | Everything: the ALB, the target group, the listener and the ECS link are all AWS API calls | The Ingress `spec` moves; only the `alb.ingress.kubernetes.io/*` annotations and the class change |
| What is the cost of exposing ten services? | Ten ALBs if done the Lab 05 way, or one ALB with ten rules if I share it by hand | One Ingress (or one IngressGroup) = **one ALB**; ten `LoadBalancer` Services would be ten NLBs |

### Two paragraphs, in prose

1. **If the AWS control plane has a bad afternoon,** ECS scaling stops
   entirely. CloudWatch alarms, Application Auto Scaling and the ECS API are
   all AWS services, and I cannot look inside any of them. I can only read
   their APIs, which are the thing that is down. The running tasks keep
   serving, but nothing will add one. The HPA keeps working through an
   outage of everything *outside* the cluster, because the controller,
   metrics-server and the scheduler all live inside it. I can debug it with
   `kubectl describe hpa`, `kubectl top` and the events. The exception is an
   EKS control-plane outage: then the HPA stops as well, and so does
   `kubectl`. Running pods still serve.

2. **For USMS, I would still choose ECS on Fargate.** It is one small team,
   one region, quiet for eight months and very busy for two. Scaling to zero
   hosts and paying for nothing to manage in the quiet months matters more
   than portability. **The strongest argument against my choice** is the
   busy two months. The HPA reacted in under a minute here, and an
   IngressGroup puts every service behind one ALB with one source-IP rule,
   as in Exercise 4. ECS needed a separate alarm, policy and cooldown for
   each scaling signal, and gave me no disruption budget at all.

## Step 18 - persistence (screenshot 04)

`PERSISTENCE PROVEN`. These were identical after a Floci stop and start:
- both HPAs' bounds, targets and windows
- both PDBs
- all five Services, with their ClusterIPs, the pinned **30080**, and the
  gateway's *allocated* nodePort **32125**
- the Ingress paths
- the `nodeSelector`
- the node group (re-derived from `list-nodegroups`)

The allocated nodePort did not change, because it is stored in the k3s
datastore, which persisted. The guide's "legitimate difference" did not
occur. The ServiceLB pod restarted and wrote the same `EXTERNAL-IP` back.

## Step 19 - the env file

`configs/lab-08.env`: 19 exports, none empty.

`USMS_INGRESS_CLASS=none` is written as a literal, with a comment saying why
(no IngressClass exists). An empty value would look like a failed lookup. The
node group values are `2/4/2`, the true state, not the 2/6/3 the lab
intended.

## Review questions (Section 14)

### 1. "Scales when the node hits 50% CPU"

No. `averageUtilization: 50` means the **mean CPU across the target's ready
pods is 50% of each pod's *request***. Here that is 25m against a 50m
request. Node CPU never enters it: this node had 1930m allocatable and sat
at 3% while the HPA scaled.

**If someone halves the request to 25m** without touching the HPA, the same
real load shows as twice the percentage. The HPA scales out at 12.5m per pod
instead of 25m, so it runs **more pods** for the same traffic. Each pod
still does the same work, and the scheduler packs twice as many per node, so
the cluster reaches `Pending` sooner. It is more *replicas*, but each is
reserved half the CPU, so it is not more real capacity.

### 2. Ten times the traffic by Monday

Same order as Step 3:
1. **Dimension 1:** raise `maxReplicas` (and pre-scale by raising
   `minReplicas` for the event). Check `kubectl get hpa` and `kubectl get
   pods | grep Pending`.
2. **Dimension 3:** raise the node group's `maxSize` and `desiredSize`. Check
   that new nodes are `Ready` and nothing is `Pending`.
3. **Dimension 2,** only if per-pod limits are being hit. Check for
   throttling, then accept the rolling restart.

**Dimension 4, bigger instances, cannot change in place.** I would create a
second node group with the larger type, cordon and drain the old one, with
PDBs that allow at least one disruption (Exercise 2), then delete it.
Before Monday, not on it.

### 3. Outside the workload versus inside the cluster

- **Failure:** Application Auto Scaling survives anything that happens to my
  ECS service, because it is not in it, but it dies with an AWS regional
  control-plane problem I cannot see into. The HPA survives AWS-side
  trouble as long as the cluster's control plane is up, but it shares fate
  with the cluster. If etcd or the controller manager is unhealthy, scaling
  stops with them.
- **Visibility and coupling:** ECS's decision trail is in CloudWatch alarms
  and `describe-scaling-activities` (Lab 06's `Cause` strings). The HPA's is
  in Kubernetes events, which **k3s keeps for one hour**. I lost my first
  run's rescale events that way. The HPA is also bound to the request I
  set, while ECS's percentage is of the task reservation.

### 4. Four pods `Pending` for twenty minutes

The HPA did its job. It wrote 8 into `spec.replicas`, and its loop ends
there. The scheduler found no node with 4 × the request free, so four pods
are `Pending`. Adding nodes is the *other* loop, `desiredSize` on the node
group, and nothing connects the two unless something watches `Pending`
pods. Normally that is the **Cluster Autoscaler or Karpenter**. Without one,
somebody must raise the node group by hand (Step 10).

**Lowering the CPU request is a bad fix.** It makes the pods "fit" on paper
while each pod is guaranteed less CPU. It also changes the HPA's
denominator, so the same load reads as a higher percentage and the HPA asks
for *even more* pods. It hides a capacity problem by overcommitting.

### 5. NodePort versus LoadBalancer

A NodePort opens one port (30000-32767) on every node and forwards it to
ready pods. A LoadBalancer is a NodePort plus an external load balancer in
front, with one stable address. I saw both on one object: `80:32125/TCP`
and `external=172.17.0.3`.

**A requirement the wrong choice fails:** "students reach the portal at one
stable address on port 80". A NodePort fails it, because clients would need
node IPs (which change as nodes are replaced) and a port like 30080. A
LoadBalancer meets it, with one DNS name on port 80 whose targets follow the
pods.

### 6. `/enrolment` through the Ingress or through the gateway

**I would route `/enrolment` through `usms-gateway` and delete the Ingress's
`/enrolment` and `/results` rules,** leaving `/ -> usms-gateway`.

The gateway does three things the Ingress rule does not:
- it strips the `/enrolment/` prefix before proxying (`proxy_pass
  .../usms-enrolment.../;`)
- it sets `Host` and `X-Forwarded-For` headers
- it gives every backend one consistent front door that I control in a
  ConfigMap

With both routes live, the same path behaves differently depending on which
one a client hits. The direct rule sends `/enrolment` *unstripped* to a
backend that serves its JSON at `/`.

The case *for* the direct route is one fewer hop and one fewer pod to scale.
It would win only if the gateway did nothing. Exercise 4 is the exception:
there a direct, *restricted* rule is the point.

### 7. `kubectl delete pod` went through a PDB

That is correct, because a PDB constrains the **eviction API**: the
cooperative "may I remove this?" request that `kubectl drain`, node upgrades
and autoscalers send. `kubectl delete` is not a request for permission. I
saw both: the eviction got `TooManyRequests`, and the delete went straight
through.

**Voluntary disruptions** are ones something with an API asked for: drains,
upgrades, scale-in of nodes. **Involuntary** ones are crashes, kernel
panics, a terminated instance, an OOM eviction. No API call is made for
those, so no PDB is consulted.

**A realistic save:** a managed node group upgrade during enrolment week
drains nodes one at a time. With `usms-enrolment-pdb maxUnavailable: 1`, the
upgrade cannot evict a second enrolment pod until the first replacement is
ready elsewhere, so the service never drops to zero.

## Observed, recorded only, conceptual (Section 11)

- **Observed:**
  - manual and declarative scaling, drift and `kubectl diff`
  - QoS classes and the scheduler's allocatable arithmetic
  - metrics-server
  - the HPA scaling 2 -> 3 -> 2 with its 300 s window
  - `nodeSelector` enforcement, and `maxUnavailable 0` protecting service
  - PDBs refusing evictions while deletes go through
  - ClusterIP, port-forward, NodePort and a real `LoadBalancer` address
    (k3s ServiceLB), reachable in-cluster
  - persistence of all of it
- **Recorded, not enacted:**
  - the AWS annotations on the Service and Ingresses
  - the Ingress objects themselves (no controller)
  - the node group's 2/4/2 (and the 2/6/3 that could not even be recorded)
- **Conceptual:**
  - the AWS Load Balancer Controller and the ALB / NLB it would create
  - Cluster Autoscaler, Karpenter
  - custom metrics
  - the Update-object pattern
  - IRSA for the readiness file's ServiceAccount
  - cost

## Exercise 5 Part 3 - ECS or Kubernetes for USMS

**Recommendation: ECS on Fargate.** USMS has a small team and one region.
It is quiet for eight months and very busy for two. Fargate means nothing to
patch or upgrade in the quiet months, and per-task IAM roles from day one:
Lab 04's `usms-ecs-task-role` worked immediately. Here, every pod still acts
as `usms-eks-node-role`, because IRSA could not complete (Lab 07 Step 21).
Kubernetes asked more of me before anything served:
- two IAM lifecycles
- an access entry, plus an authentication mode that had to be chosen at
  creation (Lab 07)
- node labels that did not reach the node (Step 11)
- a node group whose size this build could not change (Step 10)

**The strongest argument against it** is the two busy months.
- **Scale-up speed:** the HPA went from load to a new pod in under a minute
  (14:21:37 at 2%, a ready third pod by 14:22:45). Lab 06's target tracking
  needed three one-minute evaluations before acting at all.
- **Disruption:** Kubernetes gave me a disruption budget, which refused an
  eviction that would have taken the gateway to zero. ECS has no equivalent.
- **Exposure:** one IngressGroup can put the portal and a source-restricted
  results endpoint behind one ALB, as declared configuration (Exercise 4).
  Lab 05 built a single path by hand, with four `elbv2` calls and a
  security group.

**Three observations behind the choice:**
1. **ECS never waited for a host.** Lab 06's step policy took the service to
   10 tasks, and Fargate placed every one. On EKS, capacity is my problem:
   this node's 1930m allocatable is a hard ceiling, and nothing here would
   add a node (Step 10).
2. **The HPA's decision trail evaporates.** k3s kept its rescale events for an
   hour, and I lost a whole run that way. Lab 06's `Cause` strings were
   still readable weeks later.
3. **Two files owning one object broke Kubernetes twice in two labs:** the
   gateway Service (Step 15) and the enrolment PDB (Step 12). Declarative
   configuration is only as good as the discipline behind it. A two-person
   team pays for that discipline every month, busy or not.
