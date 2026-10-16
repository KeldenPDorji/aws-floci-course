# Lab 08 - Independent Exercises 1-5

**Environment:**
- Floci **2.2.0**, support path A
- `usms-eks-cluster`: k3s `v1.30.10+k3s1`, one node with 1930m CPU and
  about 1.5 GiB allocatable (Floci reserves the rest to model a `t3.small`)
- `kubectl` v1.36.1, context `usms-eks`, namespace `usms`

The screenshots cover the checkpoints. The exercise evidence is command
output saved under `outputs/` (`lab-08-ex1.txt` to `lab-08-ex4.txt`,
`lab-08-scaling-evidence.json`, `lab-08-lab06-readiness.txt`), quoted below.

After all five exercises and the Section 15 cleanup:
- `verify-lab-08.sh` reports `PASS=33  FAIL=1`
  (`outputs/lab-08-verify-final.txt`). The one failure is Step 10's node
  group `maxSize`: `UpdateNodegroupConfig` does not exist on this build.
- `verify-lab-07.sh` reports `PASS=30  FAIL=0`, after one check was updated
  for Exercise 2 (below).

---

## Exercise 1 - Basic: a second autoscaler

[`manifests/lab-08/11-hpa-results.yaml`](../../manifests/lab-08/11-hpa-results.yaml)
is `autoscaling/v2`, written as a manifest (no `kubectl autoscale`):

| Field | Value |
|---|---|
| Bounds | min 2, max 6 |
| Target | `averageUtilization: 60` |
| `scaleUp` | `stabilizationWindowSeconds: 0`, one policy of `Pods 2 / 30s` |
| `scaleDown` | `stabilizationWindowSeconds: 180` |

The prerequisite was checked first: `usms-results` declares
`{"cpu":"50m","memory":"32Mi"}`. Then a client-side dry run, a server-side
dry run, and the real apply (`outputs/lab-08-ex1.txt`):

```text
horizontalpodautoscaler.autoscaling/usms-results-hpa created (dry run)
horizontalpodautoscaler.autoscaling/usms-results-hpa created (server dry run)
horizontalpodautoscaler.autoscaling/usms-results-hpa created
NAME                 REFERENCE                   TARGETS       MINPODS   MAXPODS   REPLICAS
usms-enrolment-hpa   Deployment/usms-enrolment   cpu: 2%/50%   2         8         2
usms-results-hpa     Deployment/usms-results     cpu: 2%/60%   2         6         2
scaleUp: 2 Pods per 30s | scaleDown window 180s
ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count ...
ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
```

Two HPAs, both reporting percentages.

**Why 60% suits results when enrolment uses 50%:** results is read-mostly
and its traffic arrives as a burst it can absorb a little late, so it can run
its pods hotter and keep less spare capacity. Enrolment has a deadline and
failed registrations, so it scales out earlier.

The shorter 180 s scale-in window follows from the same reasoning: results
traffic falls off as quickly as it arrived.

---

## Exercise 2 - Intermediate: make the gateway drainable

**The fix is the workload, not the PDB.** `minAvailable: 1` against **one**
replica can never allow a disruption. One ready pod is required, and one
exists, so zero may go. Keeping the PDB and running two replicas makes it
allow exactly one.

`python3 scripts/utilities/lab-08-edits.py ex2` changed
`manifests/lab-07/40-gateway.yaml` from `replicas: 1` to `replicas: 2`, and
it was re-applied (`outputs/lab-08-ex2.txt`):

```text
== before
usms-gateway-pdb   1     N/A   0     26m
-  replicas: 1
+  replicas: 2
deployment "usms-gateway" successfully rolled out
== after
usms-gateway-pdb   1               N/A               1                     26m
usms-gateway-5c46c9c6bf-pnhvn   1/1   Running   ...   10.42.0.6    i-acfd2de022a9365b8.ec2.internal
usms-gateway-5c46c9c6bf-thlr7   1/1   Running   ...   10.42.0.11   i-acfd2de022a9365b8.ec2.internal
== one voluntary eviction is now allowed
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
evicted usms-gateway-5c46c9c6bf-pnhvn; ALLOWED DISRUPTIONS straight after: 0
Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.
deployment "usms-gateway" successfully rolled out
usms-gateway-pdb   1     N/A   1     26m
== kubectl diff after apply
clean: repository matches the cluster
```

The budget did exactly its job:
- the first eviction was allowed, and the budget dropped to 0
- a second, while the replacement was starting, was refused
- once the replacement was ready, the budget was back at 1

`kubectl diff` on the edited manifest is clean. That depends on Step 15's
edit: before it, `40-gateway.yaml` also defined the gateway Service as a
`ClusterIP`, and re-applying it would have reverted the `LoadBalancer`.

**Placement.** Both gateway pods are on the one node, because this cluster
has only one. On a multi-node cluster I would add the same pair as Lab 07
Exercise 4:
- `topologySpreadConstraints` on `kubernetes.io/hostname` with
  `ScheduleAnyway`
- preferred `podAntiAffinity`

They keep the two replicas apart without making them unschedulable when only
one node is left. Without them, a drain could still find both gateway pods
on the node being drained: the PDB would let one go and hold the other, and
the drain would wait.

**Side effect on Lab 07's verify.** `verify-lab-07.sh` asserted that the
gateway has exactly 1 ready replica. That check now compares the gateway's
ready count with what `40-gateway.yaml` declares. Enrolment and results,
which HPAs now own, are checked as "at least 2". This is the same pattern as
Lab 05 updating `verify-lab-04.sh`.

---

## Exercise 3 - Problem solving: the autoscaler that will not act

The manifest was applied exactly as given
([`exercise3-broken.yaml`](exercise3-broken.yaml)). Diagnosis by commands,
in order (`outputs/lab-08-ex3.txt`):

```text
== 2. the HPA's own view
usms-reports-hpa   Deployment/usms-reports   cpu: 0%/70%   4         4         4          31s
== 3. all three conditions
AbleToScale     True    ReadyForNewScale  recommended size matches current size
ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count ...
ScalingLimited  True    TooFewReplicas    the desired replica count is less than the minimum replica count
Normal  SuccessfulRescale  17s  horizontal-pod-autoscaler  New size: 4; reason: Current number of replicas below Spec.MinReplicas
== 4. what does the HPA divide by?
requests:   limits: {"cpu":"200m","memory":"128Mi"}
pod QoS: Guaranteed
== 5. what values can it choose between?
minReplicas=4 maxReplicas=4 -> the only possible size is 4
== 6. the POD (not the template) has a request - defaulted from the limit at admission
usms-reports-7f7899cb44-52xnw   200m     200m     Guaranteed
...
template requests: ''
== 7. what it costs the scheduler
  cpu                1350m (69%)  2200m (113%)
```

**Fault 1, the missing request.** The template sets only `limits`. The guide
says this produces `<unknown>`, but **on this cluster it did not**: `TARGETS
cpu: 0%/70%` and `ValidMetricFound`. When a container sets a limit and no
request, Kubernetes copies the limit into the request at admission. Every
pod ran with `requests.cpu: 200m` and QoS `Guaranteed`, which the template
never asked for.

So the HPA *had* a denominator, but not the intended one:
- **70% meant 140m per pod,** nearly three times the CPU the other services
  scale at
- **four pods reserved 800m** of the node's 1930m (requests jumped to 1350m,
  69%)

`<unknown>` would appear only if the container set neither a request nor a
limit. It would then be `BestEffort`, and the HPA would report `missing
request for cpu`.

**Fault 2, the range.** `minReplicas: 4` and `maxReplicas: 4`. The first
event shows the HPA forcing the Deployment from 2 to 4 (`Current number of
replicas below Spec.MinReplicas`). From then on, 4 is the only value it can
write, so no metric can change anything. That is the fault that "prevents
action even with perfect metrics".

**Which is which:**
- Fault 2 stops action outright, at any metric value.
- Fault 1 would give `<unknown>` on a container with no limit. Here it gave
  a valid percentage against the wrong denominator, so the HPA would act
  late rather than never.

**The two fixes, one field each:**

```text
== 8. fix 1: declare the request the HPA is meant to divide by
>             requests:
>               cpu: "50m"
== 9. fix 2: give the HPA a range to move in
<   minReplicas: 4
>   minReplicas: 2
usms-reports-hpa   Deployment/usms-reports   cpu: 0%/70%   2         4         2          3m18s
usms-reports-7546594659-d9779   50m      Burstable
AbleToScale     True    SucceededRescale    the HPA controller was able to update the target scale to 3
ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
Normal   SuccessfulRescale  4s  horizontal-pod-autoscaler  New size: 3; reason: All metrics below target
== 10. clean up
deployment.apps "usms-reports" deleted from usms namespace
horizontalpodautoscaler.autoscaling "usms-reports-hpa" deleted from usms namespace
```

After the fixes:
- the pods request 50m and are `Burstable`
- the HPA has 2-4 to move in and **did move**, 4 -> 3, on its own
  arithmetic
- `ScalingLimited` is `False`

I lowered `minReplicas` rather than raising `maxReplicas`. The Deployment
asks for 2, and `min = max` was the contradiction. In between, two transient
`FailedGetResourceMetric` warnings appeared while metrics-server had not yet
scraped the new pods. That is normal and cleared within 30 s. The fixed
manifests are `outputs/lab-08-ex3-fix1.yaml` and
`outputs/lab-08-ex3-fixed.yaml`, and `usms-reports` was deleted.

---

## Exercise 4 - Challenge: expose the results service properly

### The design

[`manifests/lab-08/61-ingress-results.yaml`](../../manifests/lab-08/61-ingress-results.yaml)
is a **second Ingress object in the same IngressGroup** as
`usms-portal-ingress`. Both carry `alb.ingress.kubernetes.io/group.name:
usms-portal`, so the AWS Load Balancer Controller merges them into rules on
**one** ALB. Each requirement maps to one choice:

| Requirement | How it is met | Ladder rung |
|---|---|---|
| Reachable from the university network | `alb.ingress.kubernetes.io/conditions.usms-results`: a `source-ip` listener-rule condition limited to the university's egress CIDR (`203.0.113.0/24` stands in; IT Services would supply the real one) | Ingress (4) |
| Stable address | `external-dns.alpha.kubernetes.io/hostname: results.usms.example.edu`, a Route 53 alias to the ALB, which the ALB's generated name cannot be | Ingress (4) |
| Normal HTTP port | `listen-ports: [{"HTTP": 80}]`. In production, `HTTPS: 443` with `certificate-arn` from ACM | Ingress (4) |
| A path of its own | `/examinations/results` (Prefix) -> `usms-results:80`, `group.order: 10`, so it is evaluated before the portal's rules (`group.order: 20`) | Ingress (4) -> ClusterIP (1) |
| Enrolment not given the same exposure | The source-IP condition sits on *this* Ingress's rule only. Nothing in it names `usms-enrolment`, and the portal Ingress's rules are untouched | |
| No second load balancer | No new `type: LoadBalancer` Service. The group adds rules, not an ALB | |
| Targets | `target-type: ip`: pod IPs registered directly, as in Lab 05; the NodePort rung is skipped | |

**Why not a second `type: LoadBalancer` Service:** each one is its own NLB,
billed by the hour, and an NLB works at layer 4. It has no path rules and no
per-path source condition, so it would expose all of `usms-results`, not a
path, on a second address.

**Is the existing Ingress the answer?** No, it is the wrong shape to *edit*.
Its rules share one exposure: anything I add to it is as public as
`/enrolment`. But it is the right ALB to *join*, which is what the group
does.

One deviation I am recording rather than hiding. The portal Ingress still
routes `/results` publicly, because Step 16 and `verify-lab-08.sh` require
its three paths. In production I would delete that rule, so that
`/examinations/results`, restricted, is the only way in.

### What this build could demonstrate (`outputs/lab-08-ex4.txt`)

```text
ingress.networking.k8s.io/usms-portal-ingress configured (server dry run)
ingress.networking.k8s.io/usms-results-ingress created (server dry run)
NAME                   GROUP         ORDER   CLASS    ADDRESS   PATHS
usms-portal-ingress    usms-portal   20      <none>   <none>    /enrolment,/results,/
usms-results-ingress   usms-portal   10      <none>   <none>    /examinations/results
/examinations/results -> usms-results:80
[{"field":"source-ip","sourceIpConfig":{"values":["203.0.113.0/24"]}}]
usms-results   10.42.0.3:80,10.42.0.8:80   2d20h
{"service":"usms-results","pod":"usms-results-7d4678fd86-zd59p","campus":"rtc","version":"1.0.0"}
== enrolment is NOT in this Ingress
usms-results
LoadBalancer Services in usms: 1
```

**Observed:**
- both Ingresses validated by the API server, stored, and in one group with
  their order
- the rule's backend has two live endpoints
- the backend answers on the exact path the rule forwards
- enrolment is absent from the rule set
- the namespace still has exactly **one** `LoadBalancer` Service

**Not observable here:** the ALB itself, the merged listener rules and the
source-IP match, because this cluster has no ingress controller. On real
EKS, `kubectl get ingress` would show the same ALB DNS name as `ADDRESS` on
both objects. That shared address is the proof that one load balancer
serves both.

### Cost

Rates are AWS's standard `us-east-1` Elastic Load Balancing prices. Re-check
https://aws.amazon.com/elasticloadbalancing/pricing/ before quoting them to
the Examinations Office:
- ALB: $0.0225 per hour, plus $0.008 per LCU-hour
- NLB: $0.0225 per hour, plus $0.006 per NLCU-hour

What each design costs:
- **This design (join the existing ALB): $0 extra fixed cost.** The only new
  cost is LCU usage from results traffic. A results lookup is a small JSON
  response, so the bill is set by new connections and requests, not bytes.
  At results-week volumes that is cents.
- **A second load balancer (ALB or NLB)** would add at least
  $0.0225 × 730 h ≈ **$16.40 a month**, fixed, all year, for two weeks of
  real use. It would also add a second address for the university's
  firewall team to approve.

### What breaks if the cluster is unavailable

- **The ALB lives outside the cluster.** Its DNS name and the
  `results.usms.example.edu` alias keep resolving, so clients reach the
  load balancer.
- **The targets are pod IPs.** If the pods are gone or the nodes are down,
  health checks on `/healthz` fail, the target group has no healthy targets,
  and the ALB answers **HTTP 503**. That is a fast, explicit failure, not a
  timeout.
- **If only the control plane is down** (API server, controllers) while
  nodes and pods keep running, **results keeps serving**. The data path is
  ALB -> pod IP and does not touch the API server. What stops is change:
  - no new targets are registered when pods move
  - the HPA cannot scale
  - an Ingress edit is not reconciled
- **The operational trap:** deleting the cluster *before* deleting the
  Ingresses orphans the ALB, which keeps billing.
  `scripts/cleanup/lab-08-cleanup.sh` deletes both Ingresses first for that
  reason.

---

## Exercise 5 - Integration: the artefacts Lab 10 needs

[`lab08-readiness.sh`](lab08-readiness.sh) builds both files from live API
calls. It re-derives everything rather than copying Lab 07's file.

**Part 1** is `outputs/lab-08-scaling-evidence.json`, valid JSON (3,254
bytes). `python3` assembles it from:
- `kubectl get hpa -o json` (the full `spec` and `status`)
- `kubectl get deploy -o json` (replicas, ready, the CPU request)
- `aws eks describe-nodegroup`
- a timestamp

The node group update's **absence is stated, not omitted**:

```text
2026-10-16T15:13:48Z 2 8 2 {'name': 'usms-enrolment', 'specReplicas': 2, 'readyReplicas': 2, 'cpuRequest': '50m'}
{'minSize': 2, 'maxSize': 4, 'desiredSize': 2}
{'available': False, 'evidence': '... (UnknownOperationException) when calling the UpdateNodegroupConfig operation ...',
 'note': "Step 10's 2/6/3 could not be applied on Floci 2.2.0; the recorded config is the real one"}
```

**Part 2** is `outputs/lab-08-lab06-readiness.txt`. The bucket ARN is read
out of the policy document's `Resource` entries:

```text
policy_arn        arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite  (default version v1)
carried_by        usms-ec2-app-role usms-ecs-task-role usms-eks-node-role
bucket_arn        arn:aws:s3:::usms-student-data   (read from the policy document's Resource, not typed)
object_arn        arn:aws:s3:::usms-student-data/*  (s3:*Object applies here; s3:ListBucket to the bucket ARN)
bucket_exists     no  (head-bucket exit 254: ... (404) when calling the HeadBucket operation: Not Found)
irsa_sa           usms/usms-enrolment-sa
irsa_annotation   eks.amazonaws.com/role-arn: arn:aws:iam::000000000000:role/usms-enrolment-irsa-role
irsa_role         usms-enrolment-irsa-role - NOT created: a new role trusting arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/663EBC42F8FF46A5988672981C8E9843
                  via sts:AssumeRoleWithWebIdentity, condition sub = system:serviceaccount:usms:usms-enrolment-sa,
                  carrying USMSStudentDataReadWrite. Not usms-eks-node-role: that role trusts ec2.amazonaws.com,
                  not the OIDC provider, and is shared by every pod on the node.
irsa_status       Floci 2.2.0 does not inject web-identity tokens (Lab 07 Step 21), so this is the plan, not a build
```

**Which ServiceAccount, and which role.** The ServiceAccount is
`usms-enrolment-sa` (Lab 07 Step 21). The annotation must name a **new,
dedicated** role whose trust policy names the cluster's OIDC provider and
pins the token's `sub` to that ServiceAccount.

It must not be `usms-eks-node-role`, for two reasons:
- its trust policy is `ec2.amazonaws.com`, so a web-identity token could not
  assume it
- it is shared by every pod on the node, so annotating it would grant
  nothing new and isolate nothing

The role is named, not invented as if it exists. It was not created, because
Floci never injects the token that would use it.

Both files are git-ignored:

```text
.gitignore:8:outputs/*	outputs/lab-08-scaling-evidence.json
.gitignore:8:outputs/*	outputs/lab-08-lab06-readiness.txt
```

**Part 3** is in [`notes/lab-08-notes.md`](../../notes/lab-08-notes.md),
under "Exercise 5 Part 3": 346 words.
