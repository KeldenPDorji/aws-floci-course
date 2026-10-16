# Lab 08 - EKS scaling and service exposure

## 1. Summary

Lab 07's microservices ran at a fixed size and could be reached only from
inside the cluster. This lab gave them two ladders.

**The scaling ladder.** The same integer was written by four different things:
1. **By hand:** `kubectl scale`
2. **By file:** `replicas:` in the manifest, plus drift and `kubectl diff`
3. **By a controller:** `usms-enrolment-hpa`
   - `autoscaling/v2`, min 2, max 8, CPU 50% of the 50m request
   - scale-up instant and rate-limited; scale-in held for 300 s, then one pod
     per minute
4. **From the AWS side:** a *different* integer, the node group's
   `desiredSize`. On this build, that half could not be changed at all.

Around the HPA, the lab added:
- a `nodeSelector` (`workload=usms`), with enforcement proven
- two PodDisruptionBudgets, with the eviction API refusing and
  `kubectl delete` succeeding

**The exposure ladder.** Each rung kept the one below it:
1. `port-forward`
2. a NodePort, `usms-results-np` on pinned 30080
3. the gateway as a `LoadBalancer` Service, which on this build really got
   an address
4. an Ingress, `usms-portal-ingress`, with three prefix paths and ALB
   annotations mapped onto Lab 05's `elbv2` calls

**Support path A, on Floci 2.2.0.** The Kubernetes half was **observed**:
- the HPA scaled 2 -> 3 under real load, and back to 2 after the
  stabilisation window
- k3s's built-in ServiceLB fulfilled `type: LoadBalancer`

The AWS half shows three gaps, which Section 7 details:
- `update-nodegroup-config` does not exist on this build
- Floci ignores `_lb_ports_`
- there is no ingress controller

**Verification:** `verify-lab-08.sh` reports **`PASS=33  FAIL=1`**. The one
failure is the node group's `maxSize`, which this build cannot raise.
`verify-lab-07.sh` stays at `PASS=30 FAIL=0`.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| Autoscaling | `usms-enrolment-hpa` (2-8, 50%, up 0 s / `Percent 100` + `Pods 2` per 15 s `Max`, down 300 s / 1 pod per 60 s `Min`); `usms-results-hpa` (2-6, 60%, up `Pods 2` / 30 s, down 180 s; Exercise 1) |
| Disruption | `usms-gateway-pdb` `minAvailable 1`; `usms-enrolment-pdb` `maxUnavailable 1` (redefined from Lab 07's `minAvailable 1`) |
| Scheduling | `nodeSelector workload=usms` on `usms-enrolment`; node labelled `workload=usms tier=app` by hand |
| Exposure | `usms-results-np` NodePort `80:30080`; `usms-gateway` `LoadBalancer`, clusterIP `10.100.21.200`, nodePort `32125`, external `172.17.0.3`; `usms-portal-ingress` (`/enrolment`, `/results`, `/`, group `usms-portal`); `usms-results-ingress` (`/examinations/results`, source-IP condition; Exercise 4) |
| Workloads | `usms-gateway` 2 replicas (Exercise 2); enrolment, results and timetable unchanged; `usms-loadgen` deleted (Section 15) |
| Node group | `usms-eks-nodes` unchanged at 2/4/2. The 2/6/3 update is `UnknownOperationException` |
| Files | `manifests/lab-08/` (10, 11, 20, 30, 40, 50, 60, 61); `manifests/lab-07/20-enrolment.yaml` (+ `nodeSelector`) and `40-gateway.yaml` (Service moved out, `replicas: 2`); `manifests/lab-07/21-enrolment-pdb.yaml` removed; `configs/lab-08.env` (19 exports); scripts in Section 3.9 |

---

## 2. Evidence index

Section 9 has eight checkpoints. Five screenshots prove them without
repeating each other:
- Checkpoints 3, 4 and 7 have one screenshot each
- Checkpoints 5 and 6 share one, the whole exposure ladder
- Checkpoint 8 shares one with the verification result

Checkpoints 1 and 2 (the baseline, manual scaling and drift) are command
output under `outputs/`, git-ignored and quoted where used. Each screenshot
was cleared before capture.

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoint 3: the HPA with `cpu: 2%/50%` at rest; the `behavior` block on one line; a 12-sample watch going 2% -> 61% and replicas 2 -> 3; the two `SuccessfulRescale` events, `New size: 3 ... above target` at 14:22:30 and `New size: 2 ... All metrics below target` at 14:30:45 | [3.4](#34-checkpoint-3---the-hpa-moving-steps-8-9) |
| 02 | Checkpoint 4: `update-nodegroup-config` -> `UnknownOperationException`; node group still 2/4/2; node labels `workload=usms tier=app`; a `nonexistent` selector pod `Pending` with `didn't match Pod's node affinity/selector` while both old pods serve; both PDBs (gateway `ALLOWED DISRUPTIONS 0`); eviction -> `TooManyRequests`; `kubectl delete` goes through | [3.5](#35-node-group-nodeselector-and-disruption-budgets-steps-10-12) |
| 03 | Checkpoints 5-6: five Services across three types; the gateway's `type / clusterIP / nodePort / external` on one line; NodePort 30080 and the LoadBalancer address each answering from a pod; `localhost:8081` silent; no IngressClass; the Ingress with no class or address and its three path -> Service rules | [3.6](#36-checkpoints-5-6---the-exposure-ladder-steps-13-16) |
| 04 | Checkpoint 7: HPA, PDBs, Services (with ClusterIPs and both nodePorts), Ingress paths, `nodeSelector` and node group re-read after a Floci restart, `diff` empty, `PERSISTENCE PROVEN` | [3.8](#38-checkpoint-7---persistence-step-18) |
| 05 | Section 8 and Checkpoint 8: `FAIL node group maxSize was raised to 6`, `PASS=33 FAIL=1`; `lab-08.env` 19 exports, none empty; the HPA, NodePort, gateway type, ingress class `none` and node group 2/4/2; `kubectl diff` clean on both edited Lab 07 manifests; Git hygiene | [3.9](#39-verification-and-hygiene-steps-19-20) |

---

## 3. Build walkthrough (Steps 1-20)

### 3.1 What this build supports, found before starting

Before writing the guide's commands, I tested the parts most likely to differ
from the guide, on the live cluster, and reverted each test:

| Probe | Result |
|---|---|
| `aws eks update-nodegroup-config` | `UnknownOperationException: Unknown operation: POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`. `list-updates` is the same. This is the guide's "known issue on 2.0.1", and it is still present on 2.2.0 |
| The `_lb_ports_` tag | Not referenced anywhere in the Floci 2.2.0 binary. The node container publishes only `6443 -> localhost:6500` |
| A test `type: LoadBalancer` Service | **Fulfilled** by k3s ServiceLB: a `svclb-*` pod, `EXTERNAL-IP 172.17.0.3` (the node), reachable from a pod, not from the Mac |
| Ingress controller | None. Floci starts k3s with `--disable=traefik` (and `--disable=local-storage`) |
| Node capacity | Capacity 10 CPU / 8 GB (the Docker VM), but **allocatable 1930m CPU / 1,588,324 Ki**: Floci passes `system-reserved=cpu=8000m` to model a `t3.small` |
| HPA under load | 2 -> 3 in about 50 s; load-generator pods pinned at their 300m limit |

A throwaway cluster was **not** used this time, unlike Lab 07. The node's
`memory.available` was 6,952 Mi against the kubelet's eviction threshold of
5,782 Mi, so a second k3s container could have triggered evictions on the
live one.

### 3.2 Steps 1-2 - starting point and baseline

`outputs/lab-08-step1.txt` and `outputs/lab-08-baseline.txt`:

```text
{"cpu":"50m","memory":"32Mi"}           <- the HPA's denominator exists
from configs/lab-07.env : 8081,8082
8081,8082                               <- tag present (Floci ignores it - 3.6)
PASS=30  FAIL=0                         <- verify-lab-07
usms-enrolment 2 2 / usms-gateway 1 1 / usms-results 2 2 / usms-timetable 1 1
all four Services ClusterIP, EXTERNAL <none>
i-acfd2de022a9365b8.ec2.internal  Ready  10  8124516Ki  1930m  1588324Ki
```

Lab 07 Exercise 5's two files were present. **Checkpoint 1** holds.

### 3.3 Steps 3-7 - scaling by hand, drift, QoS, metrics

These steps change nothing permanent, so they were run once and recorded.
The notes have the commentary.

**Step 4** (`outputs/lab-08-step4-scale.txt`):
- `kubectl scale --replicas=5` kept the **same ReplicaSet**,
  `usms-enrolment-8686648d`, now at 5, so no rollout happened.
- Rollout status counted "2 ... 3 ... 4 of 5 available" as pods passed
  readiness, and the endpoint list grew with it.
- 40 requests through the gateway split **9 / 8 / 8 / 8 / 7** across five
  pods.

**Step 5** (`outputs/lab-08-step5-drift.txt`):
- The cluster said 6, and line 35 of the file said `replicas: 2`.
- `apply` of the unchanged file reverted it to 2 with only `configured`.
- `kubectl diff` showed `- replicas: 2 / + replicas: 3` and **exited 1**,
  then 0 after the restore. No `.bak` was left behind.

**Checkpoint 2** holds.

**Step 6** (`outputs/lab-08-step6-qos.txt`):
- Every pod is `Burstable`.
- The scheduler's table is against **allocatable**: requests 500m (25%),
  limits 1200m (62%) of 1930m.
- The "Your turn" went `Burstable` (`8nl2p`) -> `Guaranteed` (`wc2w2`,
  200m/200m) -> `Burstable` (`gsghw`). **The pod was replaced both times**,
  and `kubectl diff` on the gateway manifest was clean afterwards.

**Step 7** (`outputs/lab-08-step7-metrics.txt`):
- `v1beta1.metrics.k8s.io ... True`, `metrics API: AVAILABLE`.
- Every pod sat at `1m` idle: 2% of the request.
- metrics-server ships with k3s, so no install and no `--kubelet-insecure-tls`
  were needed.

### 3.4 Checkpoint 3 - the HPA moving (Steps 8-9)

**The waits.** `manifests/lab-08/10-hpa-enrolment.yaml` is the guide's,
applied as written. Every wait is deterministic:
- `scripts/utilities/wait-hpa.sh metrics` replaces the guide's `sleep 30`
- `wait-hpa.sh ge 3` waits for the scale-out
- `wait-hpa.sh le 2 900` waits for the scale-in

**The load.** The guide's `hpa-watch.sh` sampled every 10 s, while
`usms-loadgen` (three busybox `wget` loops) ran. The second run is the one
captured.

![Checkpoint 3: usms-enrolment-hpa cpu 2%/50% min 2 max 8 replicas 2; usms-loadgen 0/0, usms-enrolment 2/2; scaleUp window=0s policies=Percent Pods select=Max | scaleDown window=300s 1 pod/60s select=Min; watch 14:21:37 2%/50% 2 2 2 rising to 23%, 43%, then 61%/50% replicas 3 ready 2 at 14:22:34, 3/3 at 14:22:45, settling at 42%/50% with 3; events 14:22:30 New size: 3 reason: cpu resource utilization (percentage of request) above target, 14:30:45 New size: 2 reason: All metrics below target](../../screenshots/lab08-01-checkpoint3-hpa-scaling.png)

- **The `behavior` block, read back from the live object:** up window 0 s
  with both policies under `Max`; down window 300 s with 1 pod per 60 s
  under `Min`. That is "instant out, slow in", the same doctrine as Lab 06's
  `ScaleInCooldown 300`.
- **The arithmetic, quoted from the HPA's own reason.** At 61% on two pods,
  `ceil(2 × 61 / 50)` = `ceil(2.44)` = **3**. The rate policies would have
  allowed +2 (both `Percent 100` and `Pods 2` give +2 at two replicas), so
  the *recommendation* limited the move, not the policy.
- **Ready lags desired by one sample.** At 14:22:34 `REPLICAS 3`, `READY 2`.
  The new pod existed but had not passed readiness. By 14:22:45 it was 3/3.
- **It settled at three pods, at 42%.** `ceil(3 × 42 / 50)` = 3, so it is
  stable. The load source was the limit: each `usms-loadgen` pod sat at its
  own 300m CPU limit (301m, 301m, 300m in the test run). The guide's 2 -> 4
  would need more load than three busybox loops can make.
- **Scale-in, by design, about seven minutes later.** Load was removed just
  after 14:23:42, and the HPA did not remove a pod until 14:30:45. The 300 s
  stabilisation window kept the highest recent recommendation (3), then the
  one-pod-per-minute policy applied. The event's reason, `All metrics below
  target`, is quoted rather than paraphrased.

**The first capture of this screenshot was not usable** (Section 6.2). It
showed `kubectl get hpa,deploy/usms-loadgen` failing, which was my command
mixing a type list with `type/name`. It also showed no rescale events, only
an unrelated `FailedGetScale Unauthorized` warning. The rescale events had
expired: k3s keeps events for one hour, and the capture was taken hours
after the run. The load cycle was re-run and captured straight away.

### 3.5 Node group, nodeSelector and disruption budgets (Steps 10-12)

**Step 10, the node group** (`outputs/lab-08-step10-nodegroup.txt`):
- `describe-nodegroup` before: `ACTIVE`, 2/4/2, `t3.small`, the two private
  subnets, labels `tier=app workload=usms`.
- `update-nodegroup-config` and `list-updates`:
  `UnknownOperationException`.
- After: still 2/4/2. Kubernetes still sees one node.

**Step 11, the node labels.** `kubectl get nodes -L workload,tier` showed
**empty** columns. Floci passes the node group's labels to the kubelet as
`--node-labels`, but those apply only when a node first registers, and this
node registered at cluster creation, before the node group existed. The
first `apply` of the `nodeSelector` therefore stalled, with the new pod
unschedulable. **`maxUnavailable: 0` kept both old pods serving**, so the
rollout timed out and nothing broke. I labelled the node by hand
(`kubectl label node --all workload=usms tier=app --overwrite`), which the
guide's Part 2 allows.

The `nodeSelector` went into the repository with
`scripts/utilities/lab-08-edits.py nodeselector`, not the guide's Python.
The guide's anchor (`spec:` then `containers:`) disappeared when Lab 07
Exercise 4 put `topologySpreadConstraints` first, and the guide's script
would have printed "added" without adding anything.

**Step 12, the PDBs.** `usms-enrolment-pdb` already existed from Lab 07
Exercise 4 as `minAvailable: 1`. The guide redefines it as
`maxUnavailable: 1`, which is right now that an HPA moves the count
(`minAvailable 1` at 8 replicas would allow 7 down). A server-side dry run
confirmed the apply swaps the field cleanly. `lab-08-edits.py pdb` removed
`manifests/lab-07/21-enrolment-pdb.yaml`, so one file defines the object.

![Checkpoint 4: update-nodegroup-config UnknownOperationException POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config; usms-eks-nodes ACTIVE 2 4 2; node i-acfd2de022a9365b8.ec2.internal WORKLOAD usms TIER app; pods usms-enrolment-6d554c6b89-j64dk Pending node none selector nonexistent, two usms-enrolment-8686648d pods Running; FailedScheduling 0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector; PDBs usms-enrolment-pdb max unavailable 1 allowed 1, usms-gateway-pdb min available 1 allowed 0; eviction Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget; kubectl delete pod usms-gateway-5c46c9c6bf-v6bh6 deleted, replacement pnhvn Running in 5s](../../screenshots/lab08-02-checkpoint4-nodes-selector-pdb.png)

- **The AWS side refuses outright.** The node group is unchanged, recorded
  as observed (Section 7). `replicas` and `desiredSize` are different
  integers behind different APIs, and here only one of the two APIs exists.
- **Enforcement proven.** With `workload: nonexistent`, the new pod is
  `Pending`, and the scheduler's reason names the selector. The two old pods
  (selector `<none>`, from before the change) keep serving. That is
  `maxUnavailable: 0` again: stuck is better than broken.
- **The PDBs:** the gateway (`minAvailable 1`, one replica) allows **0**
  disruptions, and enrolment (`maxUnavailable 1`) allows **1**.
- **The eviction API is refused; a delete is not.** The POST to
  `pods/<pod>/eviction` (the body is `outputs/lab-08-eviction.json`) gets
  `TooManyRequests`. `kubectl delete pod` goes straight through, and the
  ReplicaSet replaces the pod in 5 s. A PDB constrains a cooperative
  request, not a command.

After the screenshot, re-applying `20-enrolment.yaml` put `workload: usms`
back, and the rollout completed. **Checkpoint 4** holds, except "node group
at 2/6/3", which this build cannot do.

**Step 12 Part 3, the drain dry run** (`outputs/lab-08-step12-drain-dryrun.txt`),
held a surprise. `kubectl drain --dry-run=client` printed `drained (dry run)`
and listed the gateway pod as evictable. A *client-side* dry run never calls
the eviction API, so it cannot see the PDB that would block a real drain.

### 3.6 Checkpoints 5-6 - the exposure ladder (Steps 13-16)

**Step 13** (`outputs/lab-08-step13-15-host.txt`):
- `curl` to the gateway's ClusterIP `10.100.21.200` from the Mac failed:
  there is no route.
- `kubectl port-forward svc/usms-gateway 18080:80` returned all three JSON
  answers, and showed both properties that disqualify it for anything but
  debugging:
  - **every** request landed on **one** gateway pod (`pnhvn`)
  - `localhost:18080` was gone as soon as the command stopped
- Backgrounded with `&`, the port-forward first died with
  `aws: [Errno 32] Broken pipe`. The `aws eks get-token` exec plugin needs a
  stdin, and `</dev/null` fixed it.

**Step 14:** `40-service-nodeport.yaml`, a **second** Service on the
**same** pods as `usms-results`, pinned to 30080.

**Step 15** applied `50-service-loadbalancer.yaml`, a full manifest, not a
patch. It needed one repository change first. `manifests/lab-07/40-gateway.yaml`
*also* defined the gateway Service, as a `ClusterIP`. Exercise 2 re-applies
that file, which would have reverted the `LoadBalancer` silently: Step 5's
drift, caused by two files owning one object. `lab-08-edits.py gateway-svc`
removed the block, and `50-service-loadbalancer.yaml` is now the only
definition. The wait for an address was `kubectl wait
--for=jsonpath='{.status.loadBalancer.ingress}'`.

**Step 16:** `60-ingress.yaml` as written. Exercise 4 later added the
`group.name` and `group.order` annotations.

![Checkpoints 5-6: services usms-enrolment ClusterIP, usms-gateway LoadBalancer 10.100.21.200 external 172.17.0.3 80:32125/TCP, usms-results ClusterIP, usms-results-np NodePort 80:30080/TCP, usms-timetable ClusterIP; type=LoadBalancer clusterIP=10.100.21.200 nodePort=32125 external=172.17.0.3; from a pod -- NodePort 172.17.0.3:30080 returns usms-results JSON, -- LoadBalancer 172.17.0.3:80 /enrolment/ returns usms-enrolment JSON; host localhost:8081 - no answer; ingressclass No resources found; ingress usms-portal-ingress class none address empty port 80; /enrolment -> usms-enrolment, /results -> usms-results, / -> usms-gateway](../../screenshots/lab08-03-checkpoint6-exposure-ladder.png)

- **Each rung keeps the one below it, on one object:**
  `type=LoadBalancer clusterIP=10.100.21.200 nodePort=32125 external=172.17.0.3`.
  The nodePort was allocated automatically.
- **NodePort:** `172.17.0.3:30080`, the node's address, answers with
  `usms-results` JSON from a pod. It is a node port, not a ClusterIP.
- **LoadBalancer:** `172.17.0.3:80` answers `/enrolment/` through the
  gateway. **k3s ServiceLB fulfilled it**: a `svclb-usms-gateway` DaemonSet
  bound port 80 on the node and wrote the node's address into the Service
  status. It is the local equivalent of the cloud controller, and it ignores
  the three AWS annotations.
- **From the Mac, nothing answers.** `localhost:8081` and `:8082` are silent,
  because Floci does not implement `_lb_ports_`. `172.17.0.3` is on Docker's
  internal bridge, and `localhost:30080` was never published. The
  `port-forward svc/usms-results-np 30080:80` fallback proves the Service,
  not the NodePort.
- **The Ingress is stored and valid, and nothing acts on it.** There are no
  IngressClasses, the class is `<none>`, the address is empty, and
  `describe` shows `Events: <none>`. The three rules map to the right
  Services, which `describe` resolved to live pod IPs.

**Checkpoints 5 and 6** hold. On this single-node cluster, "every node
answers on 30080" is one node. The address is a recorded local one, not a
cloud load balancer.

**The annotation-to-`elbv2` mapping**, written for real EKS (the notes have
the ordered list):

| Annotation / field | Lab 05 command it replaces |
|---|---|
| `alb.ingress.kubernetes.io/scheme: internet-facing` | `create-load-balancer --scheme internet-facing --subnets <public pair>` |
| `alb.ingress.kubernetes.io/target-type: ip`, `healthcheck-path: /healthz` | `create-target-group --target-type ip --health-check-path ...`, once per backend |
| `alb.ingress.kubernetes.io/listen-ports: [{"HTTP": 80}]` | `create-listener --port 80 --protocol HTTP` |
| `spec.rules[].http.paths[]` | `create-rule --priority N --conditions path-pattern` (longest prefix here; numeric priority there: Lab 05's rule is priority 10, `/alb-health`) |
| `alb.ingress.kubernetes.io/tags` | `--tags` on each call |
| (the controller watching Endpoints) | ECS's `register-targets` / `deregister-targets` |

### 3.7 Step 17 - comparison with both systems running

`outputs/lab-08-step17-compare.txt` captures both stacks side by side:
- **ECS:** `usms-enrolment-svc` 2 / 2 on `usms-enrolment:2`, grace 60.
  Scalable target 2-10 with two target-tracking policies and one step policy.
  Target group type `ip`, health check `/`. Listener rule priority 10
  (`/alb-health`, fixed response) plus the default forward.
- **EKS:** both HPAs, five Services, the Ingress and both PDBs.

The two filled-in tables and the two prose paragraphs are in the notes,
under "Step 17".

### 3.8 Checkpoint 7 - persistence (Step 18)

`scripts/utilities/lab-08-restart-facts.sh` prints the configuration that
must survive:
- the HPA bounds, target and scale-in window
- both PDBs
- every Service's type, ClusterIP and nodePort
- the Ingress paths
- the `nodeSelector`
- the node group, **re-derived from `list-nodegroups`**

Replica counts, live CPU and the external address are left out, because
they may legitimately move.

The wait after `floci-up` was `aws eks wait cluster-active`, then
`wait-kube.sh 300`. There was no `sleep`, and no `update-kubeconfig` was
needed.

![Checkpoint 7: after restart usms-enrolment-hpa 2 8 50 300; usms-enrolment-pdb maxunavail 1, usms-gateway-pdb minavail 1; services with ClusterIPs, usms-gateway LoadBalancer nodePort 32125, usms-results-np NodePort 30080; usms-portal-ingress /enrolment,/results,/; nodeSelector workload usms; nodegroup from list-nodegroups usms-eks-nodes ACTIVE 2 4 2; diff empty; PERSISTENCE PROVEN](../../screenshots/lab08-04-checkpoint7-persistence.png)

`diff` printed nothing: **PERSISTENCE PROVEN**.

The guide names two "legitimate differences". **Neither happened**:
- **The gateway's allocated nodePort stayed 32125**, because it is stored in
  the k3s datastore, which persisted in its Docker volume.
- **The ServiceLB pod restarted and wrote the same `172.17.0.3` back.**

The pinned 30080 is unchanged too, as it must be. The hand-applied node
labels also survived, because the `nodeSelector` pods came back `Running`.

### 3.9 Verification and hygiene (Steps 19-20)

`configs/lab-08.env` is written by `scripts/utilities/write-lab-08-env.sh`,
the guide's Step 19 heredoc moved into a script. Every value is a lookup,
with one deliberate change: `USMS_INGRESS_CLASS` falls back to the literal
`none`, with a comment, because an empty value would look like a failed
lookup.

`scripts/utilities/verify-lab-08.sh` is the guide's 34 checks with two
changes:
- the `.gitkeep` fix to "no secret is tracked by git", as in Labs 04-07
- `/readyz` as the API check

Its header states the expected result for this build.

![Section 8 and Checkpoint 8: FAIL node group maxSize was raised to 6, PASS=33 FAIL=1; lab-08.env all values populated; exports 19 hpa 2..8 at 50% cpu scale-in window 300s nodeport 30080 gateway LoadBalancer ingress class none nodegroup 2/4/2; kubectl diff repository matches the cluster; nothing under outputs/, no root .env, no .bak in git status; check-ignore .gitignore:8:outputs/* outputs/lab-08-baseline.txt; ls-files outputs/ only .gitkeep](../../screenshots/lab08-05-verify-env-and-hygiene.png)

- **`PASS=33 FAIL=1`.** The one failure is Step 10 (Section 7). Every
  autoscaling, PDB, exposure and hygiene check passes. Re-run after the
  exercises and the Section 15 cleanup, the result is the same
  (`outputs/lab-08-verify-final.txt`).
- **19 exports, none empty or `None`:**
  - HPA `2..8` at 50%, window 300 s
  - NodePort 30080
  - gateway `LoadBalancer`
  - ingress class `none` (stated, not blank)
  - node group `2/4/2`, the true state
- **`kubectl diff` is clean on both edited Lab 07 manifests**, so the
  repository describes the cluster. That covers the `nodeSelector` in
  `20-enrolment.yaml`, and the Service removed from `40-gateway.yaml`.
- **Git hygiene:** nothing under `outputs/` and no `.bak` in `git status`;
  `check-ignore` names `.gitignore:8:outputs/*`; `ls-files outputs/` lists
  only `.gitkeep`.
- **Cleanup:** `scripts/cleanup/lab-08-cleanup.sh` parses with `bash -n` and
  has **never been run**. It asks for `DELETE-LAB-08`, then deletes in this
  order: Ingresses, then the LoadBalancer Service, then the HPAs and PDBs,
  then the load generator, then the AWS side.

**Checkpoint 8** is complete up to the commit, which I make myself.

**Scripts written for this lab:**
- `scripts/utilities/`: `hpa-watch.sh` (the guide's), `wait-hpa.sh`,
  `lab-08-edits.py`, `lab-08-restart-facts.sh`, `write-lab-08-env.sh`,
  `verify-lab-08.sh`
- `labs/lab-08-eks-scaling/`: `lab08-readiness.sh` (Exercise 5),
  `exercise3-broken.yaml`
- `scripts/cleanup/lab-08-cleanup.sh`
- `scripts/utilities/verify-lab-07.sh`: one check updated for Exercise 2
  (Section 4)

### 3.10 Section 15 - clean up

The following were removed, as `outputs/lab-08-cleanup.txt` shows:
- `usms-loadgen`
- Exercise 3's `usms-reports` and its HPA
- any leftover debug pods

No `.bak` files remained and no node is cordoned.

The KEEP list stands: seven pods (two each of enrolment, results and
gateway, and one timetable), both HPAs, both PDBs, five Services and two
Ingresses.

---

## 4. Exercises 1-5

Full commands and output are in [`exercises.md`](exercises.md).

| # | Deliverable | Result |
|---|---|---|
| 1 | `usms-results-hpa` | `11-hpa-results.yaml`: 2-6, 60%, up `Pods 2 / 30s`, down 180 s; client and server dry runs, then applied; two HPAs reporting `2%/50%` and `2%/60%`. Reasoning: read-mostly results tolerates running hotter |
| 2 | Drainable gateway | The workload was fixed, not the PDB: `replicas: 2` in `40-gateway.yaml`, so `ALLOWED DISRUPTIONS` went 0 -> **1**. One eviction was allowed (`201`), the second refused until the replacement was ready; `kubectl diff` clean. One node, so spread rules were explained rather than shown. `verify-lab-07.sh`'s "exactly 1 gateway replica" check now follows the manifest |
| 3 | The HPA that will not act | Found with `describe`'s three conditions, the template's empty `requests`, and the pods' QoS. **Fault 1 did not give `<unknown>`:** a limit with no request is copied into the request, so the HPA divided by 200m (70% = 140m per pod), and four `Guaranteed` pods reserved 800m. **Fault 2:** `min = max = 4` (`TooFewReplicas`, forced 2 -> 4, no room). One field each: `requests.cpu: 50m`, `minReplicas: 2`. Afterwards it moved 4 -> 3 itself. Deleted |
| 4 | Results for the Examinations Office | A second Ingress in IngressGroup `usms-portal` (one ALB), path `/examinations/results`, source-IP condition, ExternalDNS name, `target-type: ip`, `group.order` 10 before the portal's 20; no second LoadBalancer (1 in the namespace). Cost: $0 extra fixed versus about $16.40 a month for a second load balancer. Failure: an outside ALB answers 503 if the pods are gone, and keeps serving if only the control plane is down |
| 5 | Lab 10 hand-off | `lab-08-scaling-evidence.json` (valid, 3,254 bytes; HPA spec and status, replicas, request, node group, and the update's absence **stated**). Readiness file: policy v1 on three roles; bucket and object ARNs **read from the document**; `head-bucket` 404, exit 254; SA `usms/usms-enrolment-sa` with `eks.amazonaws.com/role-arn: .../usms-enrolment-irsa-role` (named, not created, and why not the node role). Part 3: 346 words in the notes |

---

## 5. Review questions

Answered in full in [`../../notes/lab-08-notes.md`](../../notes/lab-08-notes.md).
Summarised:

1. **50% of the pod's request, not the node.** The node sat at 3% while the
   HPA scaled. Halving the request doubles the percentage for the same load,
   so the HPA runs more pods, each reserved half the CPU. It reaches
   `Pending` sooner without adding real capacity.
2. **The order is 1 -> 3 -> 2, with a check between each.** First pods
   (check for `Pending`), then nodes (check `Ready`), then bigger pods only if
   needed. Dimension 4 cannot change in place: build a new node group, then
   cordon and drain the old one, before Monday.
3. **Outside versus inside.** Application Auto Scaling outlives anything that
   happens to the service, and dies with AWS's control plane. The HPA
   outlives AWS trouble, and dies with the cluster. Its decision trail lives
   in events that k3s keeps for an hour.
4. **Two control loops.** The HPA wrote 8 and stopped there. Only a Cluster
   Autoscaler or Karpenter would turn `Pending` into nodes. Lowering the
   request overcommits the node and makes the HPA ask for more pods.
5. **NodePort versus LoadBalancer.** "One stable address on port 80" fails
   with node IPs on port 30080 and succeeds with a load balancer. Both rungs
   are visible on one Service (`80:32125/TCP`, `external=172.17.0.3`).
6. **Route through the gateway** and delete the direct `/enrolment` rule.
   The gateway strips the prefix and sets headers. The direct rule sends
   `/enrolment` unstripped and behaves differently.
7. **A PDB governs evictions, and a delete is not an eviction.** I saw
   `TooManyRequests` against a delete that went straight through. It saves a
   service during a managed node group upgrade in enrolment week.

---

## 6. Problems encountered

### 6.1 The AWS half of Step 10 does not exist

`UpdateNodegroupConfig` and `ListUpdates` both return
`UnknownOperationException` on Floci 2.2.0. The guide flags this as a 2.0.1
issue and points to a known-issues page that is not in this repository.

The workaround would be to delete and recreate the node group as 2/6/3. On
Floci, a node group change **replaces the k3s container** (Lab 07 report
6.3), which would risk the whole running application for a number that adds
no node. So the node group stays 2/4/2. The attempt is in screenshot 02 and
the verify failure is explained: `PASS=33 FAIL=1`, not 34/0.

### 6.2 Two screenshots needed retakes, both teaching something

- **Checkpoint 3.** The first capture used `kubectl get hpa,deploy/usms-loadgen`,
  which is invalid (my command). More importantly, the HPA's rescale events
  had **expired**: k3s keeps events for one hour, and the screenshot was
  taken hours after the run. What remained was an unrelated `FailedGetScale
  Unauthorized` warning, logged six times while the cluster sat idle. I
  re-ran the load cycle and took the capture inside the hour. The fixed
  command filters events to `reason=SuccessfulRescale`, so stale warnings
  cannot crowd it out. **Lesson:** Kubernetes events are short-lived. Lab
  06's `Cause` strings were not.
- **Checkpoint 4.** The first capture ran in a terminal without the env
  files, so `--cluster-name ""` produced the URL `/clusters/node-groups/...`.
  It also skipped the setup blocks: no `nodeSelector`, no gateway PDB. The
  eviction therefore **succeeded** (`201`), and the ReplicaSet replaced the
  pod. Nothing broke, but the screenshot proved the opposite of the point.
  The retake sourced the env behind the `READY` guard and ran the setup.

### 6.3 The node group's labels never reached the node

Covered in 3.5: kubelet `--node-labels` apply only at first registration.
The `nodeSelector` rollout stalled until I labelled the node by hand.
`maxUnavailable: 0` meant the stall was harmless.

### 6.4 Two files, one object - twice

- **The gateway Service** was defined by both `manifests/lab-07/40-gateway.yaml`
  (ClusterIP) and `manifests/lab-08/50-service-loadbalancer.yaml`
  (LoadBalancer).
- **`usms-enrolment-pdb`** was defined by both `manifests/lab-07/21-enrolment-pdb.yaml`
  (`minAvailable 1`) and `manifests/lab-08/30-pdb-gateway.yaml`
  (`maxUnavailable 1`).

In each case, whichever file was applied last would win silently. That is
exactly the drift Step 5 demonstrates. `scripts/utilities/lab-08-edits.py`
gives each object one owner, and the Lab 07 exercises page records where
the PDB went.

### 6.5 Smaller ones

- **The guide's Step 11 Python fails silently on this repository.** Its
  anchor is gone since Lab 07 Exercise 4. `lab-08-edits.py nodeselector`
  replaces it, and refuses to claim success otherwise.
- **`kubectl port-forward &` dies with `Broken pipe`** under the exec-plugin
  kubeconfig. `</dev/null` fixes it.
- **`kubectl drain --dry-run=client` reports `drained`** even with a PDB
  that would block it. Only a server-side eviction tells the truth.
- **zsh `no matches found`** on `rm -f manifests/lab-07/*.bak` when there are
  no `.bak` files. It is harmless: zsh refuses a glob that matches nothing.

---

## 7. Floci limitations versus real AWS

| Behaviour | Floci 2.2.0 (observed) | Real AWS / EKS |
|---|---|---|
| `kubectl scale`, `replicas`, rolling updates, readiness gating | Standard, observed | Same |
| metrics-server, `kubectl top` | Present (k3s default), no flags needed | An add-on to install |
| HPA `autoscaling/v2` with `behavior` | Works: 2 -> 3 -> 2, 300 s window observed | Same |
| HPA events | Kept **1 hour** by k3s | Kept 1 hour by default on EKS too; ship them elsewhere to keep them |
| Node capacity | One node; allocatable 1930m / ~1.5 GiB (`system-reserved=cpu=8000m` models a `t3.small`) | One node per instance, sized by the type |
| Node group labels -> node | **Did not arrive** (node registered before the group); labelled by hand | Applied when each node joins |
| `update-nodegroup-config`, `list-updates`, `describe-update` | **`UnknownOperationException`** / `No update` | Asynchronous Update object, then the ASG resizes |
| A third node from `desiredSize 3` | Not possible (not even recordable) | The ASG launches an instance; Ready in 1-2 min |
| `nodeSelector`, PDBs, eviction API | Standard, observed | Same |
| NodePort | Allocated, answers on the node IP in-cluster; **not published to the host** | Reachable on every node's VPC address, subject to security groups |
| `type: LoadBalancer` | **Fulfilled by k3s ServiceLB**: `EXTERNAL-IP 172.17.0.3` (node IP), in-cluster only | An NLB in the public subnets (AWS Load Balancer Controller), pod-IP targets |
| `_lb_ports_` cluster tag | **Ignored**: no reference in the binary; 8081/8082 never answer | An ordinary tag |
| AWS Service and Ingress annotations | Stored and ignored | Drive the NLB / ALB configuration |
| Ingress controller | **None** (`--disable=traefik`); Ingress stored, no class, no address | AWS Load Balancer Controller creates an ALB per IngressGroup |
| Cluster Autoscaler, Karpenter, custom metrics | Not installed (need IRSA and real EC2) | Standard add-ons |
| Persistence | HPA, PDBs, Services (incl. allocated nodePort), Ingress, `nodeSelector`, node group all survive a restart | n/a |
| Cost | Free | One NLB or ALB per hour each, LCUs, and nodes |

**Observed, recorded only, conceptual** (Section 11's three categories, for
this build):
- **Observed:**
  - manual and declarative scaling, drift and `kubectl diff`
  - QoS classes and allocatable arithmetic
  - metrics-server, and the HPA moving both ways
  - `nodeSelector` enforcement, and `maxUnavailable 0` protecting the
    service
  - PDB versus eviction versus delete
  - port-forward, NodePort and a `LoadBalancer` address (all in-cluster)
  - persistence
- **Recorded only:**
  - the AWS annotations
  - both Ingress objects
  - the node group's 2/4/2
- **Conceptual:**
  - the AWS Load Balancer Controller's ALB and NLB
  - Cluster Autoscaler, Karpenter
  - custom metrics
  - the Update-object pattern
  - IRSA for the Lab 10 ServiceAccount
  - cost

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh          # docker-compose.yml pins floci/floci:2.2.0
source configs/course.env
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-04.env
source configs/lab-07.env
source configs/lab-08.env
aws eks wait cluster-active --name usms-eks-cluster && ./scripts/utilities/wait-kube.sh 300
./scripts/utilities/verify-lab-08.sh
```

Expected: `PASS=33  FAIL=1` (the node group `maxSize` check).

On a freshly created cluster, label the node first, because the node
group's labels do not reach it on this build:

```bash
kubectl label node --all workload=usms tier=app --overwrite
```
