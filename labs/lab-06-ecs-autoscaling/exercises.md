# Lab 06 - Independent Exercises 1-5

Environment: Floci **2.2.0** (upgraded from 1.5.34 for this lab; see the
report, Section 3.1), AWS CLI 2.36.23, account `000000000000`, `us-east-1`.
The scalable target is `service/usms-ecs-cluster/usms-enrolment-svc`,
`ecs:service:DesiredCount`, min 2, max 10.

Section 14 asks for screenshots only of Checkpoints 3, 5 and 7, so the
exercise evidence is the command output saved under `outputs/`
(`lab-06-ex1.txt` to `lab-06-ex5.txt`, `lab-06-scaling-report-*.txt`,
`lab-06-scaling-history.json`, `lab-06-scale-latency.txt`,
`lab-06-lab10-readiness.txt`), quoted below. All commands assume the six env
files are sourced, with `$RID` and `$SDIM` derived as in Step 5.

---

## Exercise 1 - A memory policy that can only grow

[`templates/lab-06-target-tracking-memory.json`](../../templates/lab-06-target-tracking-memory.json)
is a static document with no variables, so it was written as a plain file:
target 70.0, `ECSServiceAverageMemoryUtilization`, out 60, in 600,
`DisableScaleIn: true`.

```bash
aws application-autoscaling put-scaling-policy --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking --policy-type TargetTrackingScaling --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-memory.json --query 'Alarms[].AlarmName' --output text
```

**Result** (`outputs/lab-06-ex1.txt`):

```text
TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-AlarmHigh-2e07e7fd-...   TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-AlarmLow-2f946308-...
ECSServiceAverageMemoryUtilization   70.0   60   600   True
managed alarms on the target: 6
PASS=39  FAIL=3
```

Before starting, I predicted verify would stay at `PASS=39 FAIL=3`. It only
checks the CPU policy by name and asserts "2 or more" managed alarms, so a
third policy changes no check. It did stay there.

**Why the guide expects five, not six, and why Floci gave six.** On real AWS
a target tracking policy with `DisableScaleIn: true` creates **only its high
alarm**. The low alarm's only job is to invoke the policy for a scale-in, and
this policy never scales in, so it would be an alarm with nothing to do.
Floci 2.2.0 created **both**, giving 6 managed alarms, and that is a Floci
limitation. Operationally, the missing low alarm means this policy never
votes in a scale-in decision.

**Memory 70 against CPU 50: which scales out first?** Whichever resource the
enrolment workload actually exhausts first, relative to its reservation. A
stateless API that renders small responses usually burns CPU before memory,
so CPU at 50 would fire first. A service holding large in-memory caches or
sessions would hit memory first. Answering properly needs the per-task CPU
and memory profile *under load* (Container Insights during a load test), not
a guess from the targets.

**Does `DisableScaleIn` change the other two policies' scale-in?** No.
Application Auto Scaling scales in only when every target tracking policy
*that has scale-in enabled* agrees. A scale-in-disabled policy takes no part
in scale-in, so it can only add capacity and never blocks the others from
removing it.

---

## Exercise 2 - The scale-in half of step scaling

[`templates/lab-06-step-scaling-in.json`](../../templates/lab-06-step-scaling-in.json):
`ChangeInCapacity`, `Average`, cooldown **300**.

```text
alarm threshold = 20; breach = metric - 20 (negative when below)

  MetricIntervalLowerBound   MetricIntervalUpperBound   ScalingAdjustment
           -10                         0                     -1     metric 10 to 20
         (none)                      -10                     -2     metric below 10
```

**Sign conventions.** For a scale-in policy every bound is **zero or
negative**, measured relative to the threshold, and every adjustment is
**negative**. `MetricIntervalUpperBound: 0` with `ScalingAdjustment: -1`
means "when the metric is anywhere from 10 below the threshold up to (not
including) the threshold, remove one task". The open-ended interval is now
the *bottom* one, because there is no lower limit on how empty a queue can be.

The **cooldown is 300, five times the scale-out cooldown,** because removing
capacity is the expensive mistake. A queue that dips for one minute must not
take away tasks the next wave will need.

```bash
STEP_IN_ARN=$(aws application-autoscaling put-scaling-policy ... --policy-name usms-enrolment-queue-step-in --policy-type StepScaling --step-scaling-policy-configuration file://templates/lab-06-step-scaling-in.json --query PolicyARN --output text)
aws cloudwatch put-metric-alarm --alarm-name usms-enrolment-queue-low --namespace USMS/Enrolment --metric-name EnrolmentQueueDepth --dimensions Name=Service,Value=enrolment --statistic Average --period 60 --evaluation-periods 3 --threshold 20 --comparison-operator LessThanThreshold --treat-missing-data notBreaching --alarm-actions "$STEP_IN_ARN"
# metric pushed to 5 three times, then:
aws cloudwatch set-alarm-state --alarm-name usms-enrolment-queue-low --state-value ALARM --state-reason "Lab 06 Exercise 2"
```

**Result** (`outputs/lab-06-ex2.txt`):
- `low alarm forced to ALARM`
- `wait-desired.sh eq 1 30` timed out: **desiredCount stayed at 2**
- no new scaling activity was recorded (the three listed are Step 12's
  scale-outs)

A metric of 5 is a breach of **-15**, which selects the `-2` step. From 2
tasks, `2 + (-2) = 0`, below `MinCapacity` 2, so the result is clamped back
to 2 and nothing changes.

**The unreachable step.** At the baseline, **the -2 step can never apply in
full**: `2 + (-2) = 0 < 2`. It only does anything when the service has
already scaled out to 4 or more. (From 2 tasks the -1 step is clamped as
well, since 2 - 1 = 1 < 2. Scale-in from the floor is by definition a no-op.)
That is a finding about the design: the strong scale-in step exists only to
unwind a large scale-out.

Floci recorded no activity for the clamped decision. Real AWS would list it
under `--include-not-scaled-activities` with a `NotScaledReason`.

**Deletion, in dependency order:**

> **DANGER - delete the alarm `usms-enrolment-queue-low`**
> **What will be deleted:** the CloudWatch alarm `usms-enrolment-queue-low`, created in this exercise.
> **What depends on it:** nothing. It is the only thing that invokes `usms-enrolment-queue-step-in`.
> **Reversible?** Yes, one `put-metric-alarm` recreates it.
> **Effect on later labs:** none; it is not in the KEEP column.

> **DANGER - delete the policy `usms-enrolment-queue-step-in`**
> **What will be deleted:** the step scale-in policy, after its alarm.
> **What depends on it:** nothing, once the alarm is gone. Deleting the policy first would leave an alarm whose action names a policy ARN that no longer exists.
> **Reversible?** Yes, from `templates/lab-06-step-scaling-in.json`.
> **Effect on later labs:** none.

```bash
aws cloudwatch delete-alarms --alarm-names usms-enrolment-queue-low
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" --policy-name usms-enrolment-queue-step-in
./scripts/utilities/verify-lab-06.sh | grep -E 'FAIL|PASS='      # PASS=39 FAIL=3
```

**A CPU step policy beside the CPU target tracking policy.** Target tracking
computes the capacity that would bring CPU back to 50, using the linear
model from the interlude (for example 4 tasks at 80% gives `4 x 80 / 50 =
6.4 -> 7`), and writes that number. A step policy with its own alarm at 60%
responds to the same breach by *adding* a fixed amount on top of whatever
target tracking just wrote. The two react to one signal with incompatible
models, so the result overshoots. Then target tracking scales back towards
50, the step alarm clears, CPU climbs again, and the service oscillates with
two cooldown clocks that know nothing of each other.

I would keep **the target tracking policy**. CPU has a natural set point,
which is exactly what target tracking models. Step scaling should be kept
for signals target tracking cannot model, like the queue. "Whichever fires
first" is not the answer, because both keep firing.

---

## Exercise 3 - A scaling report tool

[`scripts/utilities/usms-scaling-report.sh`](../../scripts/utilities/usms-scaling-report.sh)

The work is split between bash and python:
- **Bash discovers**, one call per level: the scalable targets (filtered with
  `starts_with(ResourceId,'service/usms-')`), then the policies, scheduled
  actions, last activity and ECS counts per target.
- **Alarm states come from one batched call:** `describe-alarms --alarm-names`
  with every name at once.
- **`python3` joins and formats**, and writes
  `outputs/lab-06-scaling-report.json`.

Edge cases:

| Case | Output |
|---|---|
| No `usms-*` target | `no usms-* ECS scalable targets found` |
| Target with no policies | `policies     none` |
| Target tracking policy with no alarms | `alarms  none listed by the policy` |
| Step policy with no alarm invoking it | `alarm   none attached - this policy can never fire` |
| Scheduled actions or activities unimplemented | `not available on this build` (both happen on Floci 2.2.0) |

Step adjustments are derived from the configuration as a signed list
(`+1 / +3`). It runs with `set -uo pipefail` **without `-e`**: an
unimplemented call must print a row saying so, not abort and drop every
target after it.

**Verdict order** (a comment in the script explains each step):

| Order | Verdict | Why it sits here |
|---|---|---|
| 1 | `PINNED` | If min equals max, nothing can move and every other statement is moot |
| 2 | `FROZEN` | **Outranks `AT-CEILING`**. A suspended target sitting at its ceiling would read "at ceiling, working as designed" and hide the switch that will stop it ever coming down. The switch is the actionable fact |
| 3 | `AT-CEILING` | Unable to grow is the outage risk |
| 4 | `AT-FLOOR` | At the floor is a cost question, so it comes after `AT-CEILING` |
| 5 | `ELASTIC` | None of the above |

**Results** (`outputs/lab-06-ex3.txt`, `lab-06-scaling-report-*.txt`):

```text
IDENTICAL from ~ and labs/lab-06-ecs-autoscaling/
  bounds  min=2  max=10   desired=2   running=2   FROZEN      suspended  DynamicScalingIn
  bounds  min=3  max=3    desired=2   running=2   PINNED      suspended  none
  bounds  min=2  max=10   desired=2   running=2   AT-FLOOR    suspended  none
```

The full report (after Exercise 1, so four policies) printed every target
tracking policy with its `AlarmHigh` and `AlarmLow` states, the step policy
as `+1 / +3  cooldown=60`, `scheduled  not available on this build`, and the
last activity, `Setting desired capacity to 10`.

**Two findings.**
1. **The `PINNED` row** shows `desired=2` with min and max both 3. Floci stores
   bounds without enforcing them against the current count (as in Step 6's
   "Your turn"). On real AWS, re-registering at 3/3 would have moved desired
   to 3.
2. **The first version of the report said the step policy had no alarm** and
   "can never fire", minutes after it had fired three times. On Floci 2.2.0,
   `describe-scaling-policies` returns an empty `Alarms` list for a step
   policy; real AWS lists the alarm. The script now also asks from the
   alarm's side, collecting every alarm whose `AlarmActions` contain a policy
   ARN, which works on both. The corrected run is
   `outputs/lab-06-scaling-report-fixed.txt`, identical from both directories:

```text
  step         usms-enrolment-queue-step-out            +1 / +3         cooldown=60
                 alarm   usms-enrolment-queue-high = OK  (USMS/Enrolment EnrolmentQueueDepth >= 100.0)
```

The original output is kept as evidence. A report that trusts one side of a
relationship gets the answer wrong when that side is incomplete.

---

## Exercise 4 - The enrolment-week capacity plan

*To the USMS project lead.*

### Is it solved? (three sentences)

Reactive scaling will handle the three weeks of roughly double traffic well,
adding and removing tasks between 2 and 10 as requests and CPU move.
It will handle the forty-fold cohort mornings badly: the ceiling of 10
cannot hold that load, and each round of reactive scaling takes minutes.
The first twenty minutes are served almost entirely by whatever capacity
was running at 07:59, so unless we raise the floor *before* enrolment opens,
the portal falls over exactly as it did last year.

### Why forty times traffic is not a scaling problem

How long reactive policies take to go from 2 tasks to 10, using this lab's
own configuration:

| Path | Arithmetic | Time to 10 *decided* | + start and grace |
|---|---|---|---|
| **Step policy** (queue, +3 per fire, 1 x 60 s alarm, `Cooldown` 60) | 60 s alarm, +3 (5); 60 s cooldown, +3 (8); 60 s cooldown, +2 clamped (10) | **180 s** | + 20-60 s start + 60 s grace = **about 4.5-5 min** |
| **CPU target tracking** (3 x 60 s alarm, `ScaleOutCooldown` 60) | CPU is capped at 100%, so one round can at most double capacity (`n x 100/50`): 2 -> 4 -> 8 -> 10. Each round needs 180 s of breach, then the new tasks' 20-60 s start and 60 s grace before CPU can be re-measured | 3 rounds | **about 12-15 min** |

On Floci, the step path reached 10 in **59 s** (screenshot 02), because Floci
ignores the cooldown and re-fires every ~10 s. On real AWS the cooldowns
apply.

Even at 10 tasks, the target value sets the throughput:

```text
capacity    10 tasks x 1,000 requests per target per minute = 10,000 req/min = 167 req/s
throughput  baseline: 2 tasks at target = 2,000 req/min = 33 req/s
```

The figure that matters is **capacity versus demand**. If normal traffic is
about 2,000 req/min (*assumption*: two tasks at target, to be replaced by
analytics), forty times normal is **80,000 req/min (1,333 req/s)**, which is
**80 tasks** at the target value. The ceiling of 10 serves **one eighth** of
it. So forty times traffic is not a question of *how fast* we scale: no
reactive speed fixes a ceiling eight times too low, or a first twenty minutes
spent waiting for alarms.

### The ceiling, checked against Lab 02

Every `awsvpc` task consumes one private address. AWS reserves **5
addresses in every subnet**: the network address, the VPC router, the DNS
server, one reserved for future use, and the broadcast address (Amazon VPC
User Guide, "Subnet CIDR blocks",
docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html).

| Subnet | Size | Reserved | Already used | Free for tasks |
|---|---|---|---|---|
| `usms-private-subnet-a` 10.0.3.0/24 | 256 | 5 | `usms-db-01` (plus `usms-db-02` from Lab 3's exercise, where it still exists): about 2 | about 249 |
| `usms-private-subnet-b` 10.0.4.0/24 | 256 | 5 | none in this architecture (the S3 endpoint is a *gateway* endpoint, which uses no ENI) | 251 |

The largest ceiling these subnets could support is **about 500 tasks**,
reduced by anything else placed there later. The address space is not the
constraint. The real constraint is the account's **Fargate vCPU quota**:
60 tasks x 0.25 vCPU = 15 vCPU, within the default quota but worth confirming
in Service Quotas before enrolment week.

### The capacity plan

Assumptions: enrolment opens Wednesday **2026-10-14** and runs three weeks to
**2026-11-04**. The cohort days are the 14th, 21st and 28th at 08:00
Thimphu time. All times use `--timezone Asia/Thimphu`. Bhutan has no
daylight saving, but the zone is stated anyway.

| Action | Schedule | Bounds | Why |
|---|---|---|---|
| `usms-enrol-window-open` | `at(2026-10-14T07:00:00)` | min **4**, max **60** | Raise the **ceiling first**, and a floor of 4 (two per AZ) for the three weeks of double traffic |
| `usms-cohort-1-morning` | `at(2026-10-14T07:30:00)` | min **40**, max 60 | Capacity in place 30 min before 08:00, enough to start the first hour's spike at half the computed 80, with reactive scaling owning 40-60 |
| `usms-cohort-1-release` | `at(2026-10-14T10:00:00)` | min 4, max 60 | Lowers the floor only. The policies scale in when the metrics allow; no count is forced down |
| `usms-cohort-2-morning` / `-release` | `at(2026-10-21T07:30:00)` / `at(2026-10-21T10:00:00)` | 40 / 4, max 60 | Same |
| `usms-cohort-3-morning` / `-release` | `at(2026-10-28T07:30:00)` / `at(2026-10-28T10:00:00)` | 40 / 4, max 60 | Same |
| `usms-enrol-window-close` | `at(2026-11-04T20:00:00)` | min **2**, max **10** | Back to this lab's baseline |

Other changes:
- **Target values:** keep CPU at 50. **Lower `ALBRequestCountPerTarget` from
  1,000 to 800** for the window, so tasks scale out earlier with headroom for
  start latency.
- **Morning cooldowns:** keep the step policy's 1-minute alarm, with
  `ScaleOutCooldown` 60 and `ScaleInCooldown` raised to 600 so a dip at 08:20
  does not release capacity before the next wave.
- **Cleanup:** every `at()` action stays behind after it fires, so the plan
  ends with `delete-scheduled-action` on all eight.

**Reversible in one command:**
- each scheduled action (`delete-scheduled-action`), though deleting it does
  not undo a bound it already moved
- the target value (`put-scaling-policy`)
- the bounds (`register-scalable-target`)

**Not reversible:** the cost of capacity already run, and the requests
already dropped.

**Floci caveat:** `PutScheduledAction` is unsupported on this build, so the
plan can be written and reviewed here but not rehearsed.

### Monthly cost (us-east-1, Linux/x86, on-demand)

Sources:
- **AWS Fargate pricing** (aws.amazon.com/fargate/pricing):
  **USD 0.04048 per vCPU-hour** and **USD 0.004445 per GB-hour**, the same
  figures as Lab 04 Exercise 4.
- **Amazon CloudWatch pricing** (aws.amazon.com/cloudwatch/pricing):
  - **USD 0.10 per standard-resolution alarm metric per month**
  - **USD 0.30 per custom metric per month** (first 10,000)
  - **USD 0.01 per 1,000 `PutMetricData` requests**

The task size from `configs/lab-04.env` is 256 CPU / 1024 MiB, which is
0.25 vCPU and 1 GB:

```text
per task-hour = 0.25 x 0.04048 + 1 x 0.004445 = USD 0.01457
```

| Item | Calculation | Cost |
|---|---|---|
| Baseline (2 tasks, 730 h) | 2 x 730 x 0.01457 | USD 21.27 / month |
| Window floor of 4, extra 2 tasks for 21 days | 2 x 504 h x 0.01457 | **USD 14.69** |
| Cohort mornings, extra 36 tasks (40 - 4) for 2.5 h x 3 days | 270 task-h x 0.01457 | **USD 3.93** |
| Reactive scale-out above the floors | Unknown until load-tested; at most 20 tasks above 40 for 2.5 h x 3 | at most USD 2.19 |
| CloudWatch alarms | 4 managed + 1 queue alarm = 5 x 0.10 | USD 0.50 / month |
| Custom metric `EnrolmentQueueDepth` | 1 x 0.30 | USD 0.30 / month |
| `PutMetricData` (one per minute) | 43,800 requests x 0.01/1,000 | USD 0.44 / month |
| **Additional cost of the plan** | | **about USD 21.5 in the enrolment month** |

The plan roughly doubles one month's compute bill. The alarms and metrics
people forget come to USD 1.24 a month, which matters more when multiplied
across forty services than for one. Re-check all prices on the two pages
named above before this goes to finance.

### What I need from you

1. **A load test of one task**, measuring sustainable requests per minute at
   an acceptable p95 latency, and where it falls over. Every target value in
   this plan (1,000, then 800 requests per target, 50% CPU) is provisional
   until that number exists (§12.4).
2. **The exact cohort eligibility dates and times, in Thimphu time**, plus
   last year's normal request rate in requests per minute, not a ratio. The
   floors of 40 are derived from "forty times normal", which is only as good
   as "normal".
3. **Approval for the ceiling of 60 and the budget above**, and someone to own
   confirming the account's Fargate vCPU quota before the 14th.

### Tidy-up, executed

> **DANGER - delete the policy `usms-enrolment-memory-target-tracking`**
> **What will be deleted:** Exercise 1's memory target tracking policy, and with it its two managed alarms.
> **What depends on it:** nothing. It is not recorded in `configs/lab-06.env` and is not in the KEEP column.
> **Reversible?** Yes, one `put-scaling-policy` from `templates/lab-06-target-tracking-memory.json`.
> **Effect on later labs:** none. The CloudWatch lab reads the CPU, requests and queue objects only.

Exercise 2's alarm and policy had already been removed in that exercise's
point 5, in dependency order (alarm first).

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking
```

**Result** (`outputs/lab-06-ex4.txt`):
- `policies: usms-enrolment-cpu-target-tracking usms-enrolment-queue-step-out usms-enrolment-requests-target-tracking`
- `managed alarms: 4`: deleting the policy took its two alarms with it,
  6 -> 4
- `PASS=39 FAIL=3`, the three scheduled-action checks only

---

## Exercise 5 - The hand-off to Lab 10

**1-2. The history export.**
[`scripts/utilities/usms-scaling-history.sh`](../../scripts/utilities/usms-scaling-history.sh)
derives the resource ID from the service ARN, then exports one JSON
document:
- the scalable target
- every policy
- the scheduled actions (recorded as `{"unavailable": "...UnsupportedOperation..."}` on this build)
- every alarm involved
- every scaling activity, including the not-scaled ones

It adds `"generated"` (a `python3` UTC timestamp) and `"resourceId"`.
`python3 -m json.tool` validates it:

```text
valid JSON: outputs/lab-06-scaling-history.json  14431 bytes
targets 1 policies 3 alarms 5 activities 3
```

The first run recorded 4 alarms and 13,229 bytes. It missed
`usms-enrolment-queue-high`, for the same step-policy reason as Exercise 3.
The script now also finds alarms whose `AlarmActions` name a policy ARN, and
it was re-run.

**3. The measurement.**
[`lab10-readiness.sh`](lab10-readiness.sh) records a `python3` timestamp,
raises `MinCapacity` to 4 by re-registering, and polls
(`outputs/lab-06-scale-latency.txt`):

```text
method            MinCapacity 2->4 by re-registering the scalable target
capacity          desired 2 -> 2 after the registration
verdict           floor stored, desiredCount NOT raised by the registration (Floci limitation)
substitute        update-service --desired-count 4, timed until runningCount=4
elapsed_seconds   7
bounds_restored   2 10
```

The floor itself produced no capacity, because Floci does not enforce
bounds at registration. What this build *can* time is desired -> running:
**7 s** for two real nginx containers.

That figure is a floor on reality, not a measurement of it. On Fargate, task
start-up is dominated by image pull and ENI attachment. AWS documents no
single fixed figure, and the course uses 20-60 s. Add Lab 05's 60 s grace
period before a new task counts. Lab 06's cooldowns are sized against
**about 80-120 s on real AWS**, not 7.

**4. The env file.**
`./scripts/utilities/write-lab-06-env.sh --with-exercise5` appends
`USMS_SCALING_HISTORY_FILE=outputs/lab-06-scaling-history.json` and
`USMS_SCALE_LATENCY_SECONDS=7`, both derived. That gives **24 exports**, with
the empty-value check printing `all values populated`.

**5-6. The readiness file** (`outputs/lab-06-lab10-readiness.txt`):

```text
history_file      outputs/lab-06-scaling-history.json  14431 bytes
scale_latency     7 s  (see outputs/lab-06-scale-latency.txt for method)
task_role_arn     arn:aws:iam::000000000000:role/usms-ecs-task-role
policy            arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite  version v1
bucket_arn        arn:aws:s3:::usms-student-data   (read from the policy document; objects are arn:aws:s3:::usms-student-data/*)
grants            USMSStudentDataReadWrite allows: s3:DeleteObject, s3:GetBucketLocation, s3:GetObject, s3:ListBucket, s3:PutObject
--- head-bucket, before Lab 10 creates the bucket ---
output            aws: [ERROR]: An error occurred (404) when calling the HeadBucket operation: Not Found
exit_code         254
```

The bucket ARN was **read from the policy document** with
`get-policy-version`, never typed. The document has two S3 resources, the
bucket and `usms-student-data/*` for its objects. I recorded the **bucket**
ARN, because `head-bucket` and Lab 10's `create-bucket` act on the bucket,
and noted the object ARN beside it.

The failure was captured **with its exit code**: `|| true` keeps the script
running, and the code is recorded separately.

**After Lab 10's Step 1**, the same `head-bucket` returns exit 0 with no
output. At that same instant, `usms-ecs-task-role`'s unchanged policy (and
`usms-ec2-app-role`'s) starts granting real access to a real bucket, with no
IAM change at all. The 404 is the "before" picture of that.

No script in this exercise contains, reads or references an access key.
