# Lab 06 - ECS service auto scaling - my notes

**Support path (Step 3): A on Floci 2.2.0, with scheduled scaling unavailable.**

- **On Floci 1.5.34, the build Labs 1-5 ran on:** every Application Auto Scaling
  call returns `UnknownOperationException`. That is path C.
- **The upgrade:** before switching, I ran 2.2.0 against a *copy* of
  `~/floci-data` and compared 36 facts across Labs 1-5. They were identical
  (the only difference was the task definition now reported as a full ARN,
  as on real AWS). I backed the data up to
  `~/floci-data-lab-05-complete-1.5.34.tar.gz`, pinned `docker-compose.yml`
  to `floci/floci:2.2.0`, and recreated the container.
- **On 2.2.0:** the scaling loop really runs. An alarm on real metric data
  invoked the step policy, `desiredCount` moved, ECS started real tasks, and
  `describe-scaling-activities` recorded a `Cause` naming the alarm and the
  policy.
- **What 2.2.0 does not implement:** scheduled actions
  (`UnsupportedOperation`), and `describe-alarm-history`.

## Step 4 - the service-linked role

`create-service-linked-role --aws-service-name
ecs.application-autoscaling.amazonaws.com` created a role at the correct
`/aws-service-role/ecs.application-autoscaling.amazonaws.com/` path, but under
the **wrong name**: `AWSServiceRoleForEcsApplicationAutoscaling`. So
`get-role --role-name AWSServiceRoleForApplicationAutoScaling_ECSService`
returns `NoSuchEntity`. The scalable target's `RoleARN` nonetheless names
the correct role, which Floci filled in without a role existing under that
name. On real AWS a missing role would show up at Step 5, as
`register-scalable-target` failing to assume the service-linked role.

## Step 6 "Your turn" - re-registering with MinCapacity 5

Prediction: on real AWS, `desiredCount` jumps from 2 to 5 within seconds, with
no policy and no alarm involved.

Observed on Floci 2.2.0: the floor was stored (`5 10`), but `desiredCount`
**stayed at 2**. `wait-desired.sh eq 5 30` timed out, and
`describe-scaling-activities` recorded **0** activities. Floci stores bounds
without enforcing them at registration (`outputs/lab-06-reregister.txt`).

(a) **The scalable target** makes that change, through its registration. It
is not a scaling policy, and ECS only carries it out.

(b) The cost is three extra tasks around the clock (about USD 0.044 an hour,
roughly USD 1 a day at Lab 04's task size), plus a floor nobody knows about,
which then disagrees with `configs/lab-04.env`. The single call that would
have shown it is `describe-scalable-targets`. A monitor comparing its
`MinCapacity` with the expected 2 would catch it at once.

## Step 8 "Your turn" - how long the service runs at 100% CPU before a third task serves

| Term | Value | Where it comes from |
|---|---|---|
| 1. The high alarm must see the breach | 3 x 60 s = **180 s** | The managed AlarmHigh: `Period` 60, `EvaluationPeriods` 3 (screenshot 01) |
| 2. Alarm invokes the policy | about **0 s** | Seconds; treated as zero |
| 3. The task starts | **20-60 s** on Fargate; 7 s observed on Floci (Exercise 5) | Lab 06 Exercise 5 / Lab 05 measurement |
| 4. The task becomes useful | **60 s** | Lab 05 `healthCheckGracePeriodSeconds` 60, plus the target group's 2 x 30 s healthy threshold, which runs in the same window |

Total on real AWS: **about 260-300 s**, roughly 4.5-5 minutes of 100% CPU on
the two tasks you already had.

**I would change term 1 first,** because it is the biggest. That means
reacting on a 1-minute alarm (a step policy on requests, as in Step 10)
instead of the managed 3-minute one. The cost is a twitchier service: more
scale-outs on noise, and another alarm to pay for and maintain.

## Step 10 - TreatMissingData

On a real system I would choose **`breaching`**. The queue depth is
published by the application, so a missing datapoint most likely means the
application has stopped publishing, which is a fault, not an empty queue.
`notBreaching` treats silence as good news. Review question 4 has the full
argument.

## Step 11 "Your turn" - the at() action

Floci 2.2.0 answers `PutScheduledAction` and `DescribeScheduledActions` with
`UnsupportedOperation`. That happened for the cron actions, the UTC fallback
and the `at()` action alike (`outputs/lab-06-scheduled.txt`), so nothing was
created and nothing could fire.

An `at()` action is not deleted after it fires. What stays behind is the
action itself and, more importantly, the floor it raised (6). Six months
later, a quiet service is still paying for six tasks, with nothing in the
policies to explain why. The runbook page that creates it should also
contain `delete-scheduled-action` **and** the `register-scalable-target
--min-capacity 2` that puts the floor back, because deleting the action
does not undo its change.

## Step 15 - the nine-line chain

1. A student clicks Register.
2. **Requests per target rises past 1000, or the work queue passes 100.** *(this lab: the alarm thresholds)*
3. **An alarm fires and invokes a policy.** *(this lab)*
4. **The policy writes desiredCount, clamped to 2..10.** *(this lab)*
5. ECS starts a task from `usms-enrolment:2`. *(Lab 04)*
6. The task gets an ENI in `usms-private-subnet-a` or `-b`, with no public address. *(Labs 02, 04)*
7. `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only. *(Lab 05)*
8. The **service** registers its address in `usms-enrolment-tg`. *(Lab 05)*
9. The load balancer health-checks it, and after 60 s of grace it takes traffic. *(Lab 05)*

**This laboratory is responsible for three of them: lines 2, 3 and 4.**
Block 7 of `outputs/lab-06-chain.txt` proves it: the task definition is
still `usms-enrolment:2`, with 1 load balancer entry and 1 deployment.

## Section 12.1 for this build

*Observed:*
- a service-linked role under `/aws-service-role/...` (with Floci's wrong name)
- a resource ID derived from the service ARN and validated at 3 segments
- re-registration keeping `MinCapacity` when only `MaxCapacity` was passed
- two target tracking policies on two metrics
- a policy ARN with the whole resource ID inside it, in the `autoscaling` ARN namespace
- **two managed alarms per policy**, with evaluation periods **3** (high) and **15** (low)
- a six-segment `ResourceLabel`
- a step table with relative bounds
- an alarm whose `AlarmActions` I populated
- a custom metric
- suspension on and off with every policy untouched
- persistence across a restart
- the nine-line chain
- Moved from the guide's conceptual list to observed, because the loop runs
  on 2.2.0:
  - **an alarm changing state because a metric moved**
  - **scaling activities whose `Cause` names the alarm and the policy**
  - **the step selection** (+3 for a breach of 160)
  - **the ceiling clamping the result** (10)
  - **suspension of scale-out actually blocking a scale-out**, seen in the probe and then used as the Step 12 brake

*Reasoned about, not observed:*
- the target tracking capacity calculation (no CPU or request metric is published)
- **a cooldown suppressing a second scale-out**: the opposite was observed, because Floci re-fired every ~10 s
- `DisableScaleIn` preventing a scale-in
- the 15-minute target tracking scale-in
- **a scheduled action firing** (unsupported)
- registration raising `desiredCount` to the floor (not enforced)
- the 20-60 s Fargate start
- the grace period delaying usefulness
- cost

---

# Review Questions

### 1. What auto scaling changes about my application

The nine lines are listed above, with lines 2-4 belonging to this lab:
- the thresholds that decide when load is "too much"
- the alarms that turn a breach into an invocation
- the policies that turn an invocation into one integer, clamped to 2..10

The other six needed no change because each was already written in terms of
"however many tasks there are", not a fixed number:
- **ECS:** the service already starts tasks until `runningCount` equals
  `desiredCount` (Lab 04), whatever the number.
- **Placement:** every task already lands in one of two private subnets with
  the service's security group, because that is the service's network
  configuration, not a per-task decision.
- **Registration:** the service already registers every task it starts in the
  target group, and deregisters every task it stops (Lab 05).
- **The firewall:** the security group names the load balancer's *group*, so
  a tenth task is admitted exactly as the first was.

Five labs built a system whose every layer is indifferent to the count, and
that is why a control loop over the count can be added without touching any
of them. Block 7 of the chain is the evidence: the same revision, one load
balancer entry, one deployment. **Auto scaling changes nothing about your
application; it changes how many copies of it are running.**

### 2. The resource ID is not an ARN

`--resource-id` takes Application Auto Scaling's own address for the
resource: a short, path-shaped string whose grammar each namespace defines.
For ECS it is `service/<cluster>/<service>`, which is exactly the suffix of
the service ARN after the last colon. Passing the full ARN is "too much
string", and the call rejects its format.

A constructed string is used because one generic API scales resources in
nine services, each naming things differently:

| Namespace | Resource ID shape |
|---|---|
| `ecs` | `service/usms-ecs-cluster/usms-enrolment-svc` |
| `dynamodb` | `table/<name>`, or `table/<name>/index/<index>` |
| `lambda` | `function:<name>:<alias>`, with colons, not slashes |

A per-namespace grammar is unambiguous, where "an ARN" would need every
namespace's ARN format understood by the scaler.

The other three constructed identifiers in this architecture:
- **ECS control-plane calls** take the **names** `--cluster` and `--service`,
  from the cluster and service.
- **ECS tagging** takes the **service ARN** itself.
- **`ALBRequestCountPerTarget`** takes a `ResourceLabel`
  `app/<lb>/<id>/targetgroup/<tg>/<id>`. It is built from **two** ARNs: the
  load balancer's after `loadbalancer/`, and the target group's after its last
  colon, which keeps the word `targetgroup`.

### 3. Who raised the count to 2

The **scalable target** did, at the moment of registration. Application Auto
Scaling enforces the floor against the resource as part of registering the
target, so no policy, alarm or metric is involved.

When a policy makes the same change, an alarm has changed state and a
scaling activity is recorded with a `Cause` naming the alarm and the policy.
A floor enforced at registration leaves only the target's new `MinCapacity`,
plus whatever the activity log records for the registration, which may be
nothing. (On Floci 2.2.0 the floor was not enforced at all: Step 6's "Your
turn".)

**The 3 a.m. incident.** The service is overwhelmed, and the on-call
engineer cannot wait for the policies' 3-minute alarms plus cooldowns. They
run `register-scalable-target --min-capacity 8` to force capacity up
immediately, it works, and they go to bed.

The evidence the 8 a.m. person finds:
- `MinCapacity 8` in `describe-scalable-targets`, disagreeing with
  `configs/lab-04.env`'s baseline of 2
- a `desiredCount` that never drops below 8 however quiet it gets
- a CloudTrail `RegisterScalableTarget` event naming the engineer's
  principal (on real AWS)
- possibly nothing at all in `describe-scaling-activities`

Write the change down at the moment you make it, or the floor will look
like a bug.

### 4. Their alarms and mine

| | Managed alarms (target tracking) | My alarm (`usms-enrolment-queue-high`) |
|---|---|---|
| Owner | AWS, on the policy's behalf | Me |
| When the policy changes | Recreated by `put-scaling-policy`; my edits are overwritten without warning | Unaffected; I change it with `put-metric-alarm` |
| If the alarm is deleted | The policy silently stops scaling in that direction, while `describe-scaling-policies` still lists the alarm | The step policy can never fire, and `describe-scaling-policies` on real AWS stops listing it |
| When the policy is deleted | Deleted with it (seen on Floci: managed alarm count 6 -> 4) | Left behind, pointing at an ARN that no longer exists. `lab-06-cleanup.sh` deletes it explicitly |
| What it can do | Exactly one action: invoke its policy | Several actions at once, including **an SNS topic that pages a human** alongside the scaling policy |

**The case for `breaching`.** The queue depth is not an AWS metric that
always exists. The application publishes it, so a missing datapoint means the
publisher, which is the application, has stopped. Under `notBreaching`, an
enrolment service that crashed mid-week leaves the alarm `OK` forever:
"no data" reads as "queue empty", exactly when the backlog is growing
fastest. `breaching` turns silence into a scale-out (and, with an SNS action,
a page).

What goes wrong if I am right and use it: every *benign* gap in publishing
also fires the alarm and adds tasks:
- a deploy that restarts the publisher
- a throttled `PutMetricData`
- a network blip
- this lab's own hand-published datapoints

So `breaching` buys safety with spurious scale-outs, and possibly a steady
cost floor if the publisher is flaky. The usual compromise is `breaching`
plus a separate "metric missing" alarm that pages a human, so the scale-out
is a stopgap, not the fix.

### 5. Why reactive scaling cannot absorb the first minutes

The arithmetic, with every delay and where it is configured:

| Delay | Typical | Configured where |
|---|---|---|
| The metric is published and aggregated over its period | 60 s | The metric's publishing interval and the alarm's `Period` |
| The alarm needs N consecutive breaching periods | 3 x 60 s (target tracking) or 1 x 60 s (my step alarm) | The managed alarm (AWS's choice) / `--evaluation-periods` |
| Policy invocation and `UpdateService` | seconds | Application Auto Scaling |
| ECS starts a Fargate task | 20-60 s | The image size and Fargate; Lab 06 Exercise 5 |
| The task is health-checked and allowed to count | 60 s | Lab 05 `healthCheckGracePeriodSeconds` and the target group's 2 x 30 s healthy threshold |
| A second scale-out must wait | 60 s | `ScaleOutCooldown` / `Cooldown` |

That is about 2.5-5 minutes before the *first* added task serves a request.
Every request in that window is served by the capacity that existed before
the spike. That is arithmetic about measurement and start-up, not a defect.

The three consequences, and which configuration decision each justifies:
1. **The minimum capacity is a latency decision.** The floor absorbs the first
   minutes. This justifies the **floor of 2** (one task per AZ) and, in
   Exercise 4, a much higher floor on cohort mornings.
2. **Scale out eagerly, scale in reluctantly.** This justifies the asymmetric
   **ScaleOutCooldown 60 / ScaleInCooldown 300**, and the step policy's
   1-period alarm.
3. **For known spikes, reactive scaling is the wrong tool.** This justifies the
   **scheduled actions**, the only mechanism that can be early. (On this build
   they could not be created; the reasoning stands.)

The other two decisions are a consequence of the same arithmetic:
- **the ceiling of 10**: a runaway guard, sized against what the subnets and
  budget can hold
- **step scaling for the queue**: a non-linear response to a signal that is
  not a utilisation

### 6. Two target tracking policies that disagree

**Scale out:** the largest capacity any policy asks for wins. **Scale in:**
only when *every* policy (with scale-in enabled) agrees it is safe. The rule
is asymmetric for the same reason the cooldowns are. "Do I need more?" is
safely answered by *any* yes, because under-provisioning causes the outage.
"Can I have less?" is safely answered only by *all* yes. A consequence:
adding a policy can only make the service the same size or bigger.

Two target tracking policies on the **same** metric with different targets
are two thermostats in one room:
- one wants CPU at 50 and adds tasks
- the other wants 70 and, once CPU drops below 70, is willing to remove them
- only the "all agree" rule stops it, and only partly

So the service oscillates or sits permanently at the more aggressive target.
Either way one policy is dead weight that makes the behaviour harder to
reason about. That is a fault, not redundancy.

A step policy on CPU at 60% beside a CPU target tracking policy at 50 is the
same mistake. Target tracking computes the *capacity that brings CPU to 50*
(for example `4 x 80 / 50 -> 7`) and writes it. Meanwhile the step policy's
own alarm fires at 60 and *adds* a fixed number on top. The two respond to one
signal with different models: a computed set point versus a fixed increment.
Each overshoots the other, then target tracking scales in towards 50, the
step alarm clears, and the cycle repeats. Keep one per metric. Here, keep
target tracking for CPU, which has a natural set point, and use step scaling
only for signals target tracking cannot model, like the queue.

### 7. Requests per target versus CPU

The three reasons, in my own words:
1. **CPU is relative to a reservation.** 80% of a 256-unit task is 20% of a
   1024-unit task. Resize the task and every CPU target silently means
   something else. Requests per target means the same thing at any task size.
2. **CPU lags.** A request has to arrive, queue and start being processed
   before it costs CPU, and an I/O-bound enrolment API waiting on
   `usms-db-01` can be saturated at 15% CPU. Request count moves the instant
   the load does.
3. **It is a number the business already speaks.** "1,200 registrations in
   the first hour" converts directly into a target; "55% CPU" converts into
   nothing.

**CPU is the better signal** for a CPU-bound workload whose cost per request
varies widely, such as a transcript PDF renderer, where one request can cost
a hundred times another. Request count is then a poor proxy, and CPU measures
the resource that actually runs out.

`ALBRequestCountPerTarget` would scale the enrolment API **badly** in either
of these cases:
- **its requests had very uneven cost**, for example a few long transcript
  exports among many cheap reads
- **its bottleneck were elsewhere**, most likely `usms-db-01`'s connections

In the second case, more tasks mean more concurrent queries against a
database that is already the limit, so scaling out makes latency worse.

The metric that would have shown this before I chose it is the target
group's **`TargetResponseTime`** in `AWS/ApplicationELB`. If response time
climbs while requests per target stays flat, the work per request (or a
downstream dependency) is the problem, not the request count. RDS's
`DatabaseConnections` and CPU would confirm the second case.
