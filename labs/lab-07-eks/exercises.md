# Lab 07 - Independent Exercises 1-5

**Environment:**
- Floci **2.2.0**, support path A
- `usms-eks-cluster`: k3s `v1.30.10+k3s1`, one node
  (`i-acfd2de022a9365b8.ec2.internal`)
- `kubectl` v1.36.1, context `usms-eks`, default namespace `usms`

Section 13's screenshots cover the checkpoints only. The exercise evidence
is the command output saved under `outputs/` (`lab-07-ex1.txt` to
`lab-07-ex4.txt`, `lab-07-cpu-baseline.txt`, `lab-07-lab06-readiness.txt`),
quoted below.

The two exercise edits to committed manifests go through
[`scripts/utilities/lab-07-exercise-edits.py`](../../scripts/utilities/lab-07-exercise-edits.py):
- `ex2` adds the gateway route
- `ex4` adds the spread rules and writes the PDB

Each is a fixed-anchor insertion that refuses to run twice, so the edits are
reproducible and never hand-typed.

After all five exercises, `verify-lab-07.sh` still reports `PASS=30  FAIL=0`
(`outputs/lab-07-verify-after-exercises.txt`).

---

## Exercise 1 - Basic: a fourth microservice

[`manifests/lab-07/70-timetable.yaml`](../../manifests/lab-07/70-timetable.yaml)
holds all three objects in one file, following `30-results.yaml`'s structure:

| Object | What it contains |
|---|---|
| ConfigMap `usms-timetable-conf` | An nginx template: `location = /healthz` returns `ok`, and `/` returns JSON with `service`, `pod`, `campus` and `version` |
| Deployment `usms-timetable` | 1 replica, `nginx:1.27-alpine`, `POD_NAME` from the downward API, `envFrom` the shared `usms-app-config`, requests `50m` / `32Mi`, limits `200m` / `128Mi`, readiness probe on `/healthz` (no liveness, as for results) |
| Service `usms-timetable` | ClusterIP, port 80 to the named port `http` |

All three carry the lab's `app` / `project` / `tier` labels on the
Deployment and the pod template, and `app` on the ConfigMap and Service, as
in the other manifests. The file was written by hand, not generated with
`kubectl create deployment`.

```bash
kubectl apply --dry-run=client -f manifests/lab-07/70-timetable.yaml
kubectl apply -f manifests/lab-07/70-timetable.yaml && kubectl rollout status deployment/usms-timetable --timeout=120s
kubectl get deploy,svc -n usms
kubectl run usms-debug --rm -i -q --restart=Never --image=busybox:1.36 -- wget -qO- http://usms-timetable.usms.svc.cluster.local/
```

**Result** (`outputs/lab-07-ex1.txt`):

```text
configmap/usms-timetable-conf created (dry run)
deployment.apps/usms-timetable created (dry run)
service/usms-timetable created (dry run)
...
deployment.apps/usms-enrolment   2/2     2            2           32m
deployment.apps/usms-gateway     1/1     1            1           31m
deployment.apps/usms-results     2/2     2            2           31m
deployment.apps/usms-timetable   1/1     1            1           6s
service/usms-enrolment   ClusterIP   10.100.215.3    <none>        80/TCP    32m
service/usms-gateway     ClusterIP   10.100.21.200   <none>        80/TCP    31m
service/usms-results     ClusterIP   10.100.80.2     <none>        80/TCP    31m
service/usms-timetable   ClusterIP   10.100.124.61   <none>        80/TCP    6s
usms-timetable-75b4cd7c79-6h8vl   1/1   Running   app=usms-timetable,pod-template-hash=75b4cd7c79,project=usms,tier=app
{"service":"usms-timetable","pod":"usms-timetable-75b4cd7c79-6h8vl","campus":"rtc","version":"1.0.0"}
{"cpu":"50m","memory":"32Mi"}  readiness=/healthz
```

Four Deployments and four Services. The JSON names the service and the exact
pod that answered.

---

## Exercise 2 - Intermediate: route to it, and prove the route

**The edit.** `python3 scripts/utilities/lab-07-exercise-edits.py ex2`
changed `40-gateway.yaml` in two places. It added a `/timetable/` location
after `/results/`, and listed the new route in the gateway's own root
response:

```diff
<         return 200 '{"service":"usms-gateway","pod":"${POD_NAME}","routes":["/enrolment/","/results/"]}\n';
>         return 200 '{"service":"usms-gateway","pod":"${POD_NAME}","routes":["/enrolment/","/results/","/timetable/"]}\n';
>       location /timetable/ {
>         proxy_set_header Host $host;
>         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
>         proxy_pass http://usms-timetable.usms.svc.cluster.local/;
>       }
```

**Which command makes the new ReplicaSet.** The Step 18 hint applies here.
The edit is inside the ConfigMap `usms-gateway-conf`, not the pod template,
so `kubectl apply` reported `configmap/usms-gateway-conf configured` and
`deployment.apps/usms-gateway unchanged`, and the ReplicaSet list did not
change. Of the two commands Step 18 named, `kubectl annotate` on the
Deployment's metadata does not touch the template. **`kubectl rollout
restart` is the one that fits**, because it writes `restartedAt` into
`spec.template.metadata.annotations`:

```bash
kubectl apply -f manifests/lab-07/40-gateway.yaml
kubectl rollout restart deployment/usms-gateway && kubectl rollout status deployment/usms-gateway --timeout=120s
kubectl rollout history deployment/usms-gateway
kubectl run usms-debug --rm -i -q --restart=Never --image=busybox:1.36 -- sh -c 'G=http://usms-gateway.usms.svc.cluster.local; wget -qO- $G/; wget -qO- $G/enrolment/; wget -qO- $G/results/; wget -qO- $G/timetable/'
```

**Result** (`outputs/lab-07-ex2.txt`):

```text
== before
REVISION  CHANGE-CAUSE
1         <none>
usms-gateway-55f6dfc959   1     1     1     31m
== apply
configmap/usms-gateway-conf configured
deployment.apps/usms-gateway unchanged
== template unchanged, so no new RS yet:
usms-gateway-55f6dfc959   1     1     1     31m
== restart (the command that creates the new ReplicaSet)
deployment "usms-gateway" successfully rolled out
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
usms-gateway-55f6dfc959   0     0     0     31m
usms-gateway-5c46c9c6bf   1     1     1     6s
== three routes, one command
{"service":"usms-gateway","pod":"usms-gateway-5c46c9c6bf-8nl2p","routes":["/enrolment/","/results/","/timetable/"]}
{"service":"usms-enrolment","pod":"usms-enrolment-84f6dcc497-lvxrz","node":"i-acfd2de022a9365b8.ec2.internal","env":"laboratory","version":"1.0.0"}
{"service":"usms-results","pod":"usms-results-7d4678fd86-tmwf4","campus":"rtc","version":"1.0.0"}
{"service":"usms-timetable","pod":"usms-timetable-75b4cd7c79-6h8vl","campus":"rtc","version":"1.0.0"}
== what caused revision 2: {"kubectl.kubernetes.io/restartedAt":"2026-10-14T00:52:27+06:00"}
```

The proof that the change reached the running pod:
- the gateway pod that answered (`5c46c9c6bf-8nl2p`) belongs to the **new**
  ReplicaSet
- its root response lists `/timetable/`
- `/enrolment/` and `/results/` still work in the same command
- revision 2 exists, and the template annotation names `rollout restart`
  as its cause

---

## Exercise 3 - Problem solving: find the misconfiguration

The manifest was applied exactly as given
([`exercise3-broken.yaml`](exercise3-broken.yaml)). I found both faults with
commands, in this order (`outputs/lab-07-ex3.txt`):

```text
== 1. apply exactly as given
deployment.apps/usms-broken created
service/usms-broken created
== 2. the Service returns nothing
wget failed: no backend
== 3. endpoints (the most useful debugging command)
NAME          ENDPOINTS   AGE
usms-broken   <none>      6s
== 4. service selector vs pod labels
selector: {"app":"usms-broken","version":"v2"}
usms-broken-654f4944db-6j87p   0/1   Running   app=usms-broken,pod-template-hash=654f4944db,version=v1
usms-broken-654f4944db-qq7g8   0/1   Running   app=usms-broken,pod-template-hash=654f4944db,version=v1
== 5. does the selector match any pod?
No resources found in usms namespace.
== 6b. readiness events (kubectl get events reason=Unhealthy)
usms-broken-654f4944db-6j87p     Readiness probe failed: HTTP probe failed with statuscode: 404
usms-broken-654f4944db-qq7g8     Readiness probe failed: HTTP probe failed with statuscode: 404
== 7. what base nginx serves at /healthz vs /
  HTTP/1.1 404 Not Found
  HTTP/1.1 200 OK
```

**Fault 1, the selector.** `get endpoints` printed `<none>`. The Service
selects `version=v2`, but `--show-labels` shows the pods carry `version=v1`,
and `kubectl get pods -l app=usms-broken,version=v2` (the Service's selector
run by hand) finds nothing.

**Fault 2, the readiness probe.** The pods are `Running` but `READY 0/1`.
The events say `Readiness probe failed ... statuscode: 404`, and an in-pod
`wget` shows why: the stock `nginx` image serves `/`, but has nothing at
`/healthz`. That path only exists in this lab's own ConfigMap templates, and
`usms-broken` mounts none.

**Diagnosis in one sentence:** the Service's selector asks for `version: v2`
while the pods are labelled `v1`, and the readiness probe checks `/healthz`,
which plain nginx answers with 404, so no pod is ever ready. Either fault
alone leaves the Service with no ready endpoint.

**Proof that fixing one is not enough.** Each fix changes exactly one line:

```text
== 8. fix 1 only (Service selector v2 -> v1)
37c37
<     version: v2
---
>     version: v1
service/usms-broken configured
usms-broken               26s
not-ready addresses: 10.42.0.21 10.42.0.22
== 9. fix 2 (readiness path /healthz -> /)
25c25
<               path: /healthz
---
>               path: /
deployment "usms-broken" successfully rolled out
usms-broken-75d7c948bd-78b4p   1/1     Running
usms-broken-75d7c948bd-tlp9l   1/1     Running
usms-broken   10.42.0.24:80,10.42.0.25:80   29s
<title>Welcome to nginx!</title>
== 10. clean up
deployment.apps "usms-broken" deleted from usms namespace
service "usms-broken" deleted from usms namespace
```

After fix 1 the selector matched both pods, but they landed in
`notReadyAddresses`, so the ENDPOINTS column was still empty. After fix 2 the
Service had **two endpoints** and served nginx's page. The two intermediate
files are `outputs/lab-07-ex3-fix1.yaml` and `outputs/lab-07-ex3-fixed.yaml`.

An alternative to fix 2 is mounting a `/healthz` location, as the other
services do. That is more than one line, so I pointed the probe at `/`.
`usms-broken` was deleted (CLEAN UP item).

---

## Exercise 4 - Challenge: survive a node going away

### The configuration

`python3 scripts/utilities/lab-07-exercise-edits.py ex4` made two changes:

- **It added two scheduling rules to `usms-enrolment`'s pod template** in
  [`20-enrolment.yaml`](../../manifests/lab-07/20-enrolment.yaml):
  - `topologySpreadConstraints`: `maxSkew 1` on `kubernetes.io/hostname`,
    `whenUnsatisfiable: ScheduleAnyway`
  - preferred `podAntiAffinity`: weight 100, same topology key, same
    `app: usms-enrolment` selector
- **It wrote one new object,**
  [`21-enrolment-pdb.yaml`](../../manifests/lab-07/21-enrolment-pdb.yaml): a
  `PodDisruptionBudget` `usms-enrolment-pdb` with `minAvailable: 1` and the
  same selector.

The third requirement was already met. `20-enrolment.yaml` injects
`spec.nodeName` as `NODE_NAME` through the downward API, so every response
names its node, and `kubectl get pods -o wide` answers the same question
from the API.

### Justification

The brief has three requirements, and each gets its own mechanism.

**"Must not have all its capacity on one node"** is about *placement*, which
the scheduler decides when a pod is created. The topology spread constraint
says the number of enrolment pods on any two nodes may differ by at most
one, so two replicas on two nodes go one each. I chose `ScheduleAnyway`
(advisory) rather than `DoNotSchedule` (enforced) on purpose.

With `DoNotSchedule` and one node, the second replica could never be placed,
because two pods on one node and zero on a missing second is a skew of two.
Enrolment would then run at half capacity *because of* a rule meant to
protect it. During a node loss it is worse: the replacement pods could not
start on the surviving node either.

An advisory rule spreads the pods whenever nodes exist and still schedules
them when they do not. The preferred anti-affinity says the same thing in a
second vocabulary, and adds weight to the scheduler's scoring. Two
scheduling rules alone would not protect anything at drain time, because
they act only when a pod is created.

**"Must never drop below one healthy pod during a voluntary disruption"** is
about *eviction*, which has nothing to do with placement. The PDB is the
enforced half. The eviction API, which `kubectl drain`, node group upgrades
and the cluster autoscaler all use, refuses any eviction that would leave
fewer than `minAvailable` ready pods. I chose `minAvailable: 1` rather than
`maxUnavailable: 1`. With two replicas they allow the same one disruption,
but `minAvailable: 1` keeps meaning "at least one serving pod" if Lab 08's
HPA scales enrolment to ten. `maxUnavailable: 1` would then allow only one
of ten down at a time, which is safe but slows node rotation.

A PDB does not cover *involuntary* disruption. A node that crashes is not
an eviction, and the budget cannot stop it. That half is covered by having
two replicas spread across nodes in the first place, which is why the
brief needs both mechanisms.

**"Must be able to say which node each pod is on"** comes from the API, not
from memory. `kubectl get pods -o wide` and `.spec.nodeName` give it, and the
downward API puts it in each response, so a client can see it too.

### The demonstration, with one schedulable node

This build has **one** node: the node group is a record, and the k3s server
runs every pod. So I could not show the pods landing on two nodes. Instead:

- **Placement:** both pods sit on the one node, because the rule is
  advisory. This is the exact case `ScheduleAnyway` was chosen for.
- **The disruption:** I drained that node for enrolment pods, with a smoke
  loop running through the gateway for 70 s.

```bash
kubectl apply -f manifests/lab-07/20-enrolment.yaml -f manifests/lab-07/21-enrolment-pdb.yaml && kubectl rollout status deployment/usms-enrolment --timeout=180s
kubectl run usms-smoke-loop -n usms --restart=Never --image=busybox:1.36 -- sh -c '<70 s loop of wget .../enrolment/, counting ok and fail>'
kubectl drain "$NODE" --pod-selector=app=usms-enrolment --ignore-daemonsets --delete-emptydir-data --timeout=40s
kubectl uncordon "$NODE" && kubectl rollout status deployment/usms-enrolment --timeout=180s
```

**Result** (`outputs/lab-07-ex4.txt`):

```text
== schedulable nodes: 1
usms-enrolment-pdb   1               N/A               1                     12s
POD                             NODE                               IP           READY
usms-enrolment-8686648d-2zhkj   i-acfd2de022a9365b8.ec2.internal   10.42.0.28   true
usms-enrolment-8686648d-p86jv   i-acfd2de022a9365b8.ec2.internal   10.42.0.27   true
ScheduleAnyway / antiAffinity preferred weight=100
"pod":"usms-enrolment-8686648d-2zhkj","node":"i-acfd2de022a9365b8.ec2.internal"
"pod":"usms-enrolment-8686648d-p86jv","node":"i-acfd2de022a9365b8.ec2.internal"
== drain i-acfd2de022a9365b8.ec2.internal (enrolment pods only), smoke loop running
node/i-acfd2de022a9365b8.ec2.internal cordoned
error when evicting pods/"usms-enrolment-8686648d-2zhkj" -n "usms" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
error: unable to drain node "i-acfd2de022a9365b8.ec2.internal" due to error: ... global timeout reached: 40s
== during/after drain
i-acfd2de022a9365b8.ec2.internal   Ready,SchedulingDisabled   control-plane,master
usms-enrolment-pdb   1     N/A   0     83s
usms-enrolment-8686648d-2zhkj 1/1 Running i-acfd2de022a9365b8.ec2.internal
usms-enrolment-8686648d-4x29b 0/1 Pending <none>
usms-enrolment   10.42.0.28:80   35m
== uncordon
node/i-acfd2de022a9365b8.ec2.internal uncordoned
deployment "usms-enrolment" successfully rolled out
usms-enrolment-8686648d-2zhkj 1/1 Running i-acfd2de022a9365b8.ec2.internal
usms-enrolment-8686648d-4x29b 1/1 Running i-acfd2de022a9365b8.ec2.internal
usms-enrolment-pdb   1     N/A   1     90s
smoke loop over 70s: ok=62518 fail=1
```

What happened, in order:

1. **The drain cordoned the node,** so `SchedulingDisabled`. No new pod
   could land anywhere.
2. **The first eviction was allowed,** because the PDB said `ALLOWED
   DISRUPTIONS 1`. Pod `p86jv` went. Its replacement `4x29b` was created by
   the ReplicaSet but stayed `Pending` with `<none>` for a node, because the
   only node was cordoned.
3. **The second eviction was refused:** `Cannot evict pod as it would
   violate the pod's disruption budget`. The budget now read `ALLOWED
   DISRUPTIONS 0`. The drain retried every 5 s until its 40 s timeout.
   `2zhkj` kept serving, and the Service kept exactly one endpoint,
   `10.42.0.28:80`.
4. **After `uncordon`,** the Pending pod scheduled, the Deployment returned
   to 2/2, and the budget to 1.

**The smoke loop: 62,518 successful requests and 1 failure in 70 s.** I am
recording the failure rather than rounding it away. It is almost certainly
the request that was in flight on `p86jv` at the moment of its eviction. The
pod gets SIGTERM, while the endpoint removal is still travelling through the
endpoints controller and kube-proxy.

The PDB guarantees that a ready pod exists. It does not drain connections
gracefully. The usual fix is a `preStop` hook (`sleep 5`, so nginx keeps
serving until the endpoint is gone), plus nginx's own graceful quit. I would
add that before calling this zero-downtime.

**What I would have shown with two nodes:**
- `kubectl get pods -o wide` with one enrolment pod on each node
- `kubectl drain` of one node, which completes quickly: one eviction, the
  replacement schedules on the other node, then the budget is satisfied again
- the smoke loop unbroken while it happens
- with all pods on one node deleted at once, the survivor on the other node
  keeps serving while the ReplicaSet recreates the rest

What the cluster allowed me to demonstrate is the enforced half, the budget
blocking a drain. That is the half that matters on the day.

---

## Exercise 5 - Integration: what Lab 08 needs, using what Lab 01 built

[`lab07-readiness.sh`](lab07-readiness.sh) does Parts 1 and 2. It reads every
value from an API, so it can be re-run in Lab 08 Step 2.

**Part 1** (`outputs/lab-07-cpu-baseline.txt`). The metrics API exists on
this build, because k3s ships metrics-server:

```text
generated 2026-10-13T18:56:03Z
metrics API: PRESENT (metrics.k8s.io/v1beta1 - k3s ships metrics-server)
cpu request per pod: 50m
usms-enrolment-8686648d-2zhkj        cpu=8m  16% of 50m request  mem=8Mi
usms-enrolment-8686648d-4x29b        cpu=16m  32% of 50m request  mem=9Mi
```

The request is read from the live Deployment, not typed in. The percentages
are what Lab 08's HPA will compute (usage ÷ request). The baseline was taken
just after Exercise 4, with the smoke loop finished, so the pods were idle.
`4x29b` had started seconds earlier, which probably explains its higher
figure.

**Part 2** (`outputs/lab-07-lab06-readiness.txt`). The script chains
`list-policies` into `get-policy` (default version), then
`get-policy-version`, and reads the S3 ARNs out of the document's `Resource`
entries with Python:

```text
policy_arn        arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite  (default version v1)
carried_by        usms-ec2-app-role usms-ecs-task-role usms-eks-node-role
bucket_arn        arn:aws:s3:::usms-student-data   (read from the policy document, not typed)
object_arn        arn:aws:s3:::usms-student-data/*  (the s3:*Object actions apply here, ListBucket to the bucket ARN)
bucket_exists     no  (head-bucket exit 254: An error occurred (404) when calling the HeadBucket operation: Not Found)
```

**Three roles** carry the policy (Labs 03, 04 and 07). The bucket ARN and the
object ARN are separate entries: `s3:ListBucket` applies to the bucket,
`s3:GetObject` / `PutObject` / `DeleteObject` to `.../*`. The bucket still
does not exist, as Section 15 says, until Lab 10.

Both files are git-ignored:

```text
.gitignore:8:outputs/*	outputs/lab-07-cpu-baseline.txt
.gitignore:8:outputs/*	outputs/lab-07-lab06-readiness.txt
```

**Part 3** is in [`notes/lab-07-notes.md`](../../notes/lab-07-notes.md),
under "Exercise 5 Part 3": the eleven variables Lab 08 needs, each with its
reason, and the ten it does not.
