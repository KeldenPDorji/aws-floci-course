# Lab 06 - ECS service auto scaling

## 1. Summary

This lab handed `usms-enrolment-svc`'s capacity to Application Auto Scaling
and proved that something other than me moved it. It created:

- **a scalable target** at `service/usms-ecs-cluster/usms-enrolment-svc`, with
  dimension `ecs:service:DesiredCount`, min 2 and max 10, and all three
  suspension switches off
- **two target tracking policies:** CPU at 50, and `ALBRequestCountPerTarget`
  at 1000 with the six-segment `ResourceLabel` from Lab 05. Each has
  cooldowns of 60 out and 300 in, and each created its own two CloudWatch
  alarms
- **a step scaling policy** (+1, then +3, `ChangeInCapacity`, cooldown 60),
  driven by **`usms-enrolment-queue-high`**, an alarm I wrote on the custom
  metric `USMS/Enrolment EnrolmentQueueDepth >= 100`
- the service-linked role, as far as this build models it

The proof is screenshot 02:

```text
Successful  Setting desired capacity to 5   monitor alarm usms-enrolment-queue-high in state ALARM triggered policy usms-enrolment-queue-step-out
Successful  Setting desired capacity to 8   ...
Successful  Setting desired capacity to 10  ...
10   10   0
```

A real metric breach invoked a real policy. `desiredCount` went 2 -> 5 -> 8 ->
10 and stopped at the ceiling, and ECS started eight more real containers.

**The emulator had to change first.** Floci 1.5.34, which ran Labs 1-5, has
no Application Auto Scaling at all; on it, this lab would be path C. Floci
2.2.0 has it. Before switching I tested 2.2.0 against a copy of the data,
backed the state up, and pinned the compose file (Section 3.1). On 2.2.0 the
lab runs as **path A**, with the exceptions recorded in Section 7:

- **scheduled actions are unsupported**, so Step 11 could not be built
- **cooldowns are ignored**: the policy re-fires about every 10 s
- **bounds are not enforced at registration**
- **the managed alarms are modelled imperfectly**

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| Scalable target | `service/usms-ecs-cluster/usms-enrolment-svc`, `ecs:service:DesiredCount`, min 2 / max 10, `RoleARN` `.../AWSServiceRoleForApplicationAutoScaling_ECSService`, suspension `False False False` |
| Policies | `usms-enrolment-cpu-target-tracking` (`ECSServiceAverageCPUUtilization` 50.0, 60/300); `usms-enrolment-requests-target-tracking` (`ALBRequestCountPerTarget` 1000.0, 60/300); `usms-enrolment-queue-step-out` (StepScaling, `ChangeInCapacity`, `Average`, 60, two steps, the top open-ended) |
| Alarms | 4 managed `TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-Alarm{High,Low}-<uuid>`; `usms-enrolment-queue-high` (Average, 60 s, 1 evaluation, `>= 100`, `notBreaching`, action = the step policy) |
| Metric | `USMS/Enrolment EnrolmentQueueDepth`, dimension `Service=enrolment` |
| Scheduled actions | None. Floci 2.2.0 answers `UnsupportedOperation` |
| Service | Unchanged: `usms-enrolment:2`, 1 load balancer entry, 1 deployment, desired 2, grace period 60 (now stored) |
| Files | `templates/lab-06-target-tracking-{cpu,requests,memory}.json`, `lab-06-step-scaling-{out,in}.json`, `lab-06-suspended-state.json`; `configs/lab-06.env` (24 exports); scripts `verify-lab-06.sh`, `write-lab-06-env.sh`, `lab-06-probe.sh`, `wait-desired.sh`, `lab-06-scaling-proof.sh`, `lab-06-restart-facts.sh`, `lab-06-chain.sh`, `usms-scaling-report.sh`, `usms-scaling-history.sh`, `labs/lab-06-ecs-autoscaling/lab10-readiness.sh`, `scripts/cleanup/lab-06-cleanup.sh` (never run); `docker-compose.yml` pinned to `floci/floci:2.2.0` |

---

## 2. Evidence index

Section 14 asks for screenshots of Checkpoints 3, 5 and 7. The fourth is the
verification result, for the README. Everything else is a file under
`outputs/` (git-ignored), quoted where used. Each screenshot was cleared
before capture.

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoint 3: scalable target and its address, `RoleARN` filled in by AWS, suspension off, `ResourceLabel` validated, two target tracking policies with 2 alarms each, four managed alarms with 3/15 evaluations, each pair invoking its policy | [3.3](#33-checkpoint-3---the-target-and-two-target-tracking-policies) |
| 02 | Checkpoint 5: three `Successful` activities whose `Cause` names the alarm and the policy; desired 2 -> 5 -> 8 -> 10, clamped at the ceiling; `10 10 0` | [3.6](#36-checkpoint-5---something-other-than-me-moved-the-number) |
| 03 | Checkpoint 7: `PERSISTENCE PROVEN` after a restart, every identifier re-derived | [3.8](#38-checkpoint-7---persistence) |
| 04 | Section 9: `PASS=39 FAIL=3` (the scheduled-action checks); verify-lab-05 unchanged by this lab; `lab-06.env` populated, 22 exports; cleanup `bash -n`; Git hygiene | [3.10](#310-verification-and-recording-state) |

---

## 3. Build walkthrough (Steps 1-17)

### 3.1 The emulator: path C on 1.5.34, path A on 2.2.0

The first probe on the course's Floci 1.5.34 returned
`UnknownOperationException` for every Application Auto Scaling call. That
makes this lab support path C: only the interludes and Exercises 4-5. Floci
had released **2.2.0** on 2026-10-06, with an `application-autoscaling`
service. I tested it in four ways before touching anything:

1. **The whole Lab 06 chain, on a throwaway 2.2.0 container** with no data.
   Register, policies, managed alarms, step policy and alarm, the loop
   firing, activities and suspension all worked. Scheduled actions returned
   `UnsupportedOperation`.
2. **Your Lab 1-5 state, on a copy of `~/floci-data`.** I paused Floci, copied
   the 1.2 MB directory, resumed 1.5.34, and started 2.2.0 against the copy on
   another port, without the Docker socket so it could not touch real
   containers. I compared 36 facts across IAM, the VPC, subnets, routes,
   security groups, instances, the NAT gateway, AMIs, volumes, ECS, logs and
   every ELBv2 object. They were **identical**, except that `describe-services`
   now returns `taskDefinition` as a full ARN, as real AWS does.
3. **Persistence of the new objects**, across a container restart on 2.2.0.
   The target, suspension state, policy ARN and alarms all survived, stored in
   `application-autoscaling-*.json`.
4. **The alarm timing that Step 12 depends on** (3.6).

The upgrade was then a three-command Stage 0:
- `floci-down`
- `tar -czf ~/floci-data-lab-05-complete-1.5.34.tar.gz`, a rollback point
  outside the repository
- `floci-up`, with `docker-compose.yml` now pinned to `floci/floci:2.2.0`
  instead of the floating `latest`

`outputs/lab-06-floci-version.txt` reads `floci 2.2.0`.

**Side effects of 2.2.0 on earlier labs.** `deployments` is now `1`, not
`null`, and `--health-check-grace-period-seconds` is now stored. I used the
second to complete Lab 05 Step 10's intent:
`update-service --health-check-grace-period-seconds 60` returned `60 1`, and
`lab-05.env` was regenerated, so the grace period is now a lookup rather
than a recorded request.

| Script | On 2.2.0 | Note |
|---|---|---|
| `verify-lab-05.sh` | **`PASS=48 FAIL=2`**, up from 46/4 | Only the two security group limitations remain: group references (the Lab 05 rules were written under 1.5.34, which never stored them) and the revoke no-op, which 2.2.0 still has |
| `verify-lab-04.sh` | `PASS=38 FAIL=1` | |
| `verify-lab-02.sh` | `PASS=32 FAIL=1` | |
| `verify-lab-03.sh` | `PASS=31 FAIL=5` | "usms-web-01 is running" now fails: the instance's container did not come back after the emulator was recreated, the same class of issue as Lab 03 problem 13. Not caused by this lab |

### 3.2 Resuming, the probe, and the service-linked role (Steps 1-6)

**Step 2.** The baseline was confirmed as desired 2, running 2,
1 deployment, 1 load balancer (`outputs/lab-06-baseline.json`).
`verify-lab-05.sh` was captured to `outputs/lab-06-pre-verify-05.txt`, so
that the end of the lab could be a `diff` instead of an opinion.

**Step 3**, `scripts/utilities/lab-06-probe.sh` (classifying by error text,
as in Labs 04 and 05):

```text
floci version: 2.2.0
describe-scalable-targets    SUPPORTED     describe-alarms          SUPPORTED
describe-scaling-policies    SUPPORTED     list-metrics             SUPPORTED
describe-scheduled-actions   not available describe-alarm-history   not available
describe-scaling-activities  SUPPORTED     iam / ecs / elbv2        SUPPORTED
```

**Step 4.** `create-service-linked-role` created a role at the correct
`/aws-service-role/ecs.application-autoscaling.amazonaws.com/` path, but
under the wrong name, `AWSServiceRoleForEcsApplicationAutoscaling`. A
`get-role` on the real name returns `NoSuchEntity`
(`outputs/lab-06-slr.txt`). This is a Floci limitation. The target's
`RoleARN` names the correct role anyway, filled in by Floci, with no role ARN
passed (screenshot 01).

**Step 5.** The resource ID was derived from the service ARN with
`${SVC_ARN##*:}` and validated before use: `3 segments, first=service`.
Registration did not change the service (2/2). The first pass of this stage
went wrong, recorded in Section 6. **Floci accepted a scalable target with
resource ID `None`**, the validation gap that let it happen.

**Step 6, the change model** (`outputs/lab-06-reregister.txt`):
- Re-registering with only `--max-capacity 12` gave `2 12`. The floor
  survived a call that did not mention it.
- The "Your turn", min 5, stored the floor, but **`desiredCount` stayed 2**:
  `wait-desired.sh eq 5 30` timed out, with 0 activities. Real AWS raises
  desired to 5 at once. Floci does not enforce bounds at registration.
- Putting it back left exactly **one** target, `service/... 2 10`.

### 3.3 Checkpoint 3 - the target and two target tracking policies

![Checkpoint 3: scalable target ecs service/usms-ecs-cluster/usms-enrolment-svc ecs:service:DesiredCount 2 10; RoleARN .../AWSServiceRoleForApplicationAutoScaling_ECSService; suspended False False False; ResourceLabel app/usms-enrolment-alb/219a302e65154d3c/targetgroup/usms-enrolment-tg/5676809faf504f3d segments=6 first=app fourth=targetgroup; cpu policy ECSServiceAverageCPUUtilization 50.0 60 300 2 alarms and requests policy ALBRequestCountPerTarget 1000.0 60 300 2 alarms; four managed alarms 60 s periods, 3 evaluations GreaterThanThreshold and 15 evaluations LessThanThreshold, INSUFFICIENT_DATA; 2 invokes each policy](../../screenshots/lab06-01-checkpoint3-target-and-policies.png)

- **The address:** `ecs`, `service/usms-ecs-cluster/usms-enrolment-svc`,
  `ecs:service:DesiredCount`, with min 2 and max 10.
- **The role:** `RoleARN` names the service-linked role, and I never passed one.
- **Suspension:** all three switches are `False`. This is the object Step 13
  flips and verify asserts.
- **`ResourceLabel`:** `app/usms-enrolment-alb/219a302e65154d3c/targetgroup/usms-enrolment-tg/5676809faf504f3d`,
  validated as six segments, `app` first and `targetgroup` fourth. It is
  Lab 05 Exercise 5's value, read from `lab-05.env`. The requests template
  was generated with `jq --arg`, so it is valid JSON with the value baked in.
- **Two policies, two alarms each:** CPU `50.0` and requests `1000.0`, both
  `60 300`.
- **The four managed alarms I did not write:** each is 60 s periods, with the
  asymmetry baked into target tracking. The **high alarms need 3 evaluations
  (3 min)** and **the low alarms 15 (15 min)**, on top of my cooldowns.
- **The links:** `2 invokes usms-enrolment-cpu-target-tracking` and
  `2 invokes usms-enrolment-requests-target-tracking`. Every managed alarm's
  `AlarmActions` is its own policy's ARN.

Floci models the managed alarms with three visible differences from AWS:
1. **Their `MetricName` is the predefined type string**
   (`ECSServiceAverageCPUUtilization`), not `AWS/ECS CPUUtilization`.
2. **The request alarms are in `AWS/ECS`**, not `AWS/ApplicationELB`
   `RequestCountPerTarget`.
3. **The high and low thresholds are equal** (50.0 and 50.0). Real AWS puts
   the low threshold below the target, as a dead band against oscillation.

No ECS CPU or ALB request metric is published, so all four stay
`INSUFFICIENT_DATA`. The target tracking arithmetic is therefore reasoned
about, not observed.

The policy ARNs are in the **`autoscaling`** ARN namespace with the whole
resource ID embedded:
`arn:aws:autoscaling:...:scalingPolicy:<uuid>:resource/ecs/service/usms-ecs-cluster/usms-enrolment-svc:policyName/...`.
That is §12.3's naming trap, visible: nothing in the ARN says `application`.

### 3.4 Step scaling and the alarm I wrote (Step 10)

Three datapoints (3, 5, 4) created `USMS/Enrolment EnrolmentQueueDepth`. The
**policy came first**, then the alarm whose `--alarm-actions` names it
(`outputs/lab-06-step.txt`):

```text
usms-enrolment-queue-high  USMS/Enrolment  EnrolmentQueueDepth  Average  60  1  GreaterThanOrEqualToThreshold  100.0  notBreaching  INSUFFICIENT_DATA
StepScaling  ChangeInCapacity  60  2
```

The guide expects `describe-scaling-policies` to show the alarm on the step
policy, discovered "from the other end". **On Floci 2.2.0 the step policy's
`Alarms` list is empty**, even though the alarm's `AlarmActions` does name
the policy, and the loop fires (3.6). The relationship is stored on one side
only. That cost me a bug in two exercise scripts, described in Section 6.

### 3.5 Scheduled actions (Step 11) - not available

All of these returned `UnsupportedOperation`, and `DescribeScheduledActions`
did too (`outputs/lab-06-scheduled.txt`):
- the morning `cron(45 7 ? * MON-FRI *)` with `--timezone Asia/Thimphu`
- the UTC fallback `cron(0 14 ...)` for the evening
- the "Your turn" `at()` action

Nothing could be created, so nothing could fire. That accounts for verify's
three failing checks. The reasoning the step teaches still holds, and
Exercise 4's capacity plan is built on it: a scheduled action moves the
*bounds* and lets the reactive policies move the count, the cron form has six
fields with one day-field `?`, and the time zone is not the region.

### 3.6 Checkpoint 5 - something other than me moved the number

**Designing a safe Step 12 needed one more probe.** Floci 2.2.0 behaves like
this:
- it evaluates the alarm against **the average of the current wall-clock
  minute**
- it re-evaluates about **every 10 s**
- it **invokes the policy on every evaluation while in ALARM**, ignoring the
  cooldown

On the first dry run, resetting the count to 2 was followed by the policy
scaling back to 10. A low value pushed into the same minute as the 260 had
left the average above 100, and the alarm returned to ALARM.

So the reset uses Step 13's own mechanism as a brake, since the probe had
shown suspension really blocks scale-out on this build:
1. suspend scale-out
2. push the metric down
3. wait for `OK` (`aws cloudwatch wait alarm-exists --state-value OK`)
4. set desired to 2

All waits are deterministic: `wait alarm-exists`, and
`scripts/utilities/wait-desired.sh`, a bounded poll on `desiredCount`. No
`sleep` is used.

**Prediction:** a value of 260 against a threshold of 100 is a breach of
160. That falls in the open-ended interval, so the step is **+3**.

![Checkpoint 5: wait-desired desiredCount=10 after 59s; three scaling activities at 10:20:08, 10:20:18, 10:20:28, all Successful, Setting desired capacity to 5, 8, 10, Cause monitor alarm usms-enrolment-queue-high in state ALARM triggered policy usms-enrolment-queue-step-out; service 10 10 0](../../screenshots/lab06-02-checkpoint5-scaling-activity.png)

- **The `Cause` string** names the alarm, its state and the policy, three
  times. This is the evidence that `desiredCount` was changed by something
  other than me.
- **The step was +3**, as predicted (2 -> 5 -> 8). The third activity added
  only 2: **8 -> 10 is the ceiling clamping +3**.
- **The activities are 10 seconds apart** (10:20:08, :18, :28). On real AWS
  the 60 s `Cooldown` would hold the second scale-out for a minute. On Floci
  the cooldown is ignored, which is also why 10 was reached in **59 s**.
- **`10 10 0`.** ECS really started eight more nginx containers and the
  service registered them. The scaling activity completes long before the
  capacity exists on real AWS; on Floci the two are close together.

The screenshot was cleared after the first two commands. So the before-state
(`2 2 0`, 0 activities, in `outputs/lab-06-pre-scale.txt`) and the
"in ALARM" line are in files, not the image. The `Cause` text records the
ALARM state itself.

**Part 5's control-plane proof** (`outputs/lab-06-scaling-proof.txt`) walks
the same chain from configuration. Note block 1: the alarm already reads
`OK`, while desired is still 10. One 260 datapoint aged out of the minute
bucket within seconds of the clamp.

```text
alarm usms-enrolment-queue-high  >= 100  ->  policyName/usms-enrolment-queue-step-out
  -> on service/usms-ecs-cluster/usms-enrolment-svc  ecs:service:DesiredCount
  -> breach 160 selects ScalingAdjustment +3  -> bounds 2 10  -> desired 10
```

**Part 6, return to baseline**, via the brake. `paste` of the before and
after files: `2 2 0 / 0` then `2 10 0 / 3`. Desired is back to 2, running
still 10 while ECS stops the extra eight, and 3 activities are recorded. A
service under a scaling policy has no manual capacity: had the metric still
been high, the policy would simply have scaled out again.

### 3.7 Suspension (Step 13)

The suspension went through `register-scalable-target --suspended-state` with
the document, because there is no `suspend-scaling` call
(`outputs/lab-06-suspend.txt`):
1. **While suspended:** `DynamicScalingInSuspended: true`, the other two
   `false`, and the bounds unchanged at 2 and 10.
2. **The policies were untouched:** all three still listed, with 4 managed
   alarms.
3. **Resumed with the shorthand:** `False False False`, and
   `SuspendedState.* | grep -ci true` returned **0** with desired 2.

The `-i` matters, because `--output text` renders booleans as `True` and
`False`. The template in `templates/` deliberately keeps the *suspended*
state as the runbook page. Step 12 had already used suspension of scale-out
as a working brake.

### 3.8 Checkpoint 7 - persistence

`scripts/utilities/lab-06-restart-facts.sh` re-derives every identifier:
- the resource ID from the ECS service ARN
- the dimension by filtering on it
- the CPU policy by a `contains()` on its name
- the step policy **by type** (`PolicyType=='StepScaling'`)
- the alarm by prefix

It then prints the configuration facts. Alarm state, running counts and the
activity log are left out because they may legitimately move, and scheduled
actions because they do not exist here.

![Checkpoint 7: re-derived service/usms-ecs-cluster/usms-enrolment-svc ecs:service:DesiredCount usms-enrolment-cpu-target-tracking usms-enrolment-queue-step-out usms-enrolment-queue-high; target ecs 2 10; switches False False False; three policies with types; cpu 50.0 60 300 False ECSServiceAverageCPUUtilization; step ChangeInCapacity Average 60 2; alarm 100.0 GreaterThanOrEqualToThreshold 1 notBreaching 1; managed alarms 4; PERSISTENCE PROVEN](../../screenshots/lab06-03-checkpoint7-persistence.png)

`diff` printed nothing, so **PERSISTENCE PROVEN**. Everything survived a
`floci-down`/`floci-up` on 2.2.0:
- the target with its bounds and three switches
- three policies with their full configurations
- the custom alarm with its threshold, operator, evaluations, missing-data
  treatment and single action
- the four managed alarms, which kept their UUIDs on this build

### 3.9 The whole chain (Step 15) and the hint strings (Step 17)

`scripts/utilities/lab-06-chain.sh` (`outputs/lab-06-chain.txt`) prints the
seven blocks:
1. the three alarms' metrics and thresholds
2. the three policies they invoke
3. the one integer and its bounds (`2 10`)
4. the service (`2 2 usms-enrolment:2 60`; the grace period is now stored)
5. the two private subnets, `usms-enrolment-sg` and `DISABLED`
6. `enrolment-api 80 usms-enrolment-tg`, with two healthy targets
7. **`usms-enrolment:2  1  1`**

**Block 7 is the point:** the same revision, one load balancer entry, one
deployment. This lab changed nothing about the mechanism. Of the nine-line
chain from a click to a serving task, **three lines belong to this lab**
(notes, Step 15).

**Step 17's repair was not needed, and running it would have done damage.**
The `grep` found three lines in `lab-05-cleanup.sh`, all naming
`lab-04-cleanup.sh` correctly ("run BEFORE lab-04-cleanup.sh"). Both cleanup
scripts were written in Labs 04 and 05 with `lab-06-cleanup.sh` already in
the "run after" position (`outputs/lab-06-hint-strings.txt`). The guide's
`python3` replace-all would have turned the correct instruction into "run
BEFORE lab-06-cleanup.sh", so I skipped it.

### 3.10 Verification and recording state

`configs/lab-06.env` is written by `scripts/utilities/write-lab-06-env.sh`,
the guide's Step 16 heredoc moved into a script:
- **Every value is a lookup.** The resource ID comes from the service ARN, the
  bounds from the target, and the policy ARNs through `grep -E '^arn:' ||
  echo not-created`.
- **The two `USMS_SCHEDULED_*` names** are recorded with a comment saying
  that this build does not implement them.
- **The empty-value check uses `grep -E`.** The guide's `\|` form cannot
  match on macOS's BSD `grep` (Lab 05, problem 8).

`verify-lab-06.sh` is the guide's 42 checks with the Lab 04/05 `.gitkeep` fix
to "no secret is tracked by git", and its header states the expected Floci
result.

![verify-lab-06.sh: FAIL morning action exists, FAIL evening action exists, FAIL morning raises floor above evening, PASS=39 FAIL=3; verify-lab-05: Lab 05 is exactly as this lab found it; lab-06.env all values populated; exports 22, bounds 2..10, resource id service/usms-ecs-cluster/usms-enrolment-svc; cleanup syntax OK - do NOT run it; nothing under outputs/, no root .env, no .bak files in git status; check-ignore .gitignore:8:outputs/*; ls-files outputs/ shows only .gitkeep](../../screenshots/lab06-04-verify-env-and-hygiene.png)

| Failing check | Cause | Real AWS |
|---|---|---|
| morning action exists | `PutScheduledAction`: `UnsupportedOperation` (3.5) | Created |
| evening action exists | Same | Created |
| morning floor above evening floor | Both sides empty, so the comparison fails | 4 > 2 |

The checks the guide calls "the ones worth having" **all pass**:
- no suspension switch left `true`
- the resource ID is `service/usms-ecs-cluster/usms-enrolment-svc`
- exactly one scalable target
- the alarm invokes the step policy
- the top step is open-ended
- desired is inside the bounds and at the baseline
- no unexpanded variable in any template

**`diff` of verify-lab-05 before and after is empty:** Lab 05 is exactly as
this lab found it, which is stronger than `FAIL=0`.

The rest of the screenshot:
- 22 exports, populated, bounds `2..10`
- `lab-06-cleanup.sh` parses with `bash -n` and has never been run
- nothing under `outputs/`, no root `.env` and no `.bak` in `git status`
- `check-ignore` names `.gitignore:8:outputs/*`
- `ls-files outputs/` lists only `.gitkeep`

Exercise 5 later appended two derived exports, making **24**. Verify was
re-run after every exercise and stayed at `PASS=39 FAIL=3`.

---

## 4. Exercises 1-5

Full commands, output, and the Exercise 4 plan for the project lead are in
[`exercises.md`](exercises.md).

| # | Deliverable | Result |
|---|---|---|
| 1 | Memory policy, scale-out only | `usms-enrolment-memory-target-tracking`, 70.0, 60/600, `DisableScaleIn` True. Floci created **6** managed alarms, not the expected 5: it made a low alarm the policy can never use. Verify unchanged |
| 2 | Step scale-in pair | Bounds `[-10,0) -> -1`, `<-10 -> -2`, cooldown 300; `usms-enrolment-queue-low` (< 20, 3 x 60 s). Forced to ALARM: desired stayed 2, because the floor clamps both steps; the -2 step is unreachable from the baseline. Deleted alarm-first, then the policy |
| 3 | `usms-scaling-report.sh` | Computed verdicts observed: `FROZEN`, `PINNED` (min=max=3 with desired 2: bounds not enforced), `AT-FLOOR`. Identical from `~` and the lab directory. First version wrongly said the step policy had no alarm; fixed and re-run |
| 4 | Enrolment-week plan | Three-sentence verdict; reactive 2 -> 10 takes about 4.5-5 min (step) or 12-15 min (CPU); ceiling 10 = 167 req/s against about 1,333 needed; about 500 addresses free in the private subnets (5 reserved per subnet, cited); eight dated `at()` actions; **about USD 21.5 extra** in the enrolment month (cited); three asks; memory policy deleted, managed alarms 6 -> 4 |
| 5 | Lab 10 hand-off | `lab-06-scaling-history.json` (14,431 bytes, 5 alarms after the fix); floor 2 -> 4 did not raise desired, so the substitute desired -> running time is **7 s**; 24 exports; bucket ARN **read from the policy document**; `head-bucket` 404 with exit code 254 captured |

---

## 5. Review questions

Answered in full in [`../../notes/lab-06-notes.md`](../../notes/lab-06-notes.md).
Summarised:

1. **Three of nine lines are this lab's** (threshold, alarm, policy). The
   other six were already written for "however many tasks there are". Auto
   scaling changes how many copies run, not the application.
2. **The resource ID is a per-namespace grammar**, not an ARN. For ECS it is
   the ARN's suffix; DynamoDB and Lambda differ. The other three identifiers
   are the names, the service ARN, and the two-ARN `ResourceLabel`.
3. **The scalable target**, not a policy, raises the count to the floor, and
   leaves only a changed `MinCapacity` as evidence. Floci did not enforce it.
4. **Managed alarms belong to the policy; mine belongs to me** and can also
   page a human. `breaching` is right for an application-published metric,
   at the cost of spurious scale-outs on benign gaps.
5. **About 2.5-5 minutes of arithmetic** (period, evaluations, invocation,
   start, grace, cooldown). Hence a latency-sized floor, eager-out and
   reluctant-in, and scheduled actions for known spikes.
6. **Any yes to scale out, all yes to scale in.** Two policies on one metric
   are two thermostats in one room, and a step policy beside target tracking
   on one metric is the same fault.
7. **Requests beat CPU:** they are independent of the reservation, lead
   rather than lag, and are business-native. CPU wins for variable-cost
   CPU-bound work. `TargetResponseTime` exposes the bad case.

---

## 6. Problems encountered

Nine issues came up; full write-ups are in [`README.md`](README.md). The
three with the most transferable lessons:

**An empty variable produced a real object called `None`.** The first pass of
Stages 1-3 ran in a terminal without the env files. `describe-services
--cluster ""` returned `None`, `${SVC_ARN##*:}` turned that into the string
`None`, and Floci *accepted* a scalable target with resource ID `None`, then
attached a policy and two managed alarms to it. Every command "succeeded".
The tell was the screenshot's resource ID column. I deleted the objects and
re-ran the stages behind a guard that prints `READY` only when the critical
variables are set, plus an explicit `RID OK` check. Validate the identifier
before using it, as Step 5 itself says.

**A relationship stored on one side.** Floci records the step alarm's link to
its policy only in the alarm's `AlarmActions`, not in the policy's `Alarms`
list. Two exercise scripts trusted the policy side and reported the step
policy as unattached ("can never fire") minutes after it had fired three
times. Both scripts now look from the alarm side, which is correct on both
Floci and real AWS.

**Testing the emulator before trusting it.** The upgrade, the alarm-bucket
behaviour and the brake design all came from throwaway containers and a copy
of the data, never from the live state. That is why the upgrade cost nothing
and why Step 12's reset worked first time.

---

## 7. Floci limitations versus real AWS

| Behaviour | Floci (observed) | Real AWS |
|---|---|---|
| Application Auto Scaling on **1.5.34** | `UnknownOperationException` (path C) | Full |
| Application Auto Scaling on **2.2.0** | Targets, policies, activities, suspension implemented and persisted | Full |
| Lab 1-5 state under 2.2.0 | Identical (36 facts compared on a copy) | n/a |
| `create-service-linked-role` | Creates `AWSServiceRoleForEcsApplicationAutoscaling` (wrong name); the target's `RoleARN` names the right one anyway | `AWSServiceRoleForApplicationAutoScaling_ECSService`, really assumed |
| Resource ID validation | Accepted `None` | Rejected |
| Registration raising `desiredCount` to the floor | Not enforced (min 5 and min 3/max 3 both left desired at 2) | Immediate |
| Managed alarms | 2 per policy, 3 / 15 evaluations, actions correct; `MetricName` is the predefined type; ALB alarms in `AWS/ECS`; high = low threshold (no dead band) | `CPUUtilization` / `RequestCountPerTarget` in the right namespaces; low threshold below target |
| `DisableScaleIn: true` | Still creates the low alarm (6, not 5) | High alarm only |
| Target tracking capacity calculation | Not observed: no ECS or ALB metrics published, alarms stay `INSUFFICIENT_DATA` | Real |
| Step policy `Alarms` list | Empty, though the alarm invokes the policy | Lists the alarm |
| Alarm evaluation | Every ~10 s, on the current minute's average | Once per period |
| Step selection | Correct (+3 for a breach of 160) | Same |
| Cooldown | **Ignored**: re-fires every evaluation while in ALARM | Enforced |
| `MaxCapacity` clamp | **Enforced** (8 -> 10, not 11) | Enforced |
| `describe-scaling-activities` | Real activities with the full `Cause` string | Same |
| Not-scaled activities | None recorded (the clamped scale-in in Exercise 2) | Listed with `NotScaledReasons` |
| Suspension | Stored **and enforced** for scale-out (used as a brake) | Enforced |
| Scheduled actions | `UnsupportedOperation` | Full, with IANA time zones |
| `describe-alarm-history` | Not available | Full |
| `delete-scaling-policy` | Deletes the policy's managed alarms | Same |
| ECS on 2.2.0 | Real task containers; `deployments` = 1; grace period stored; full-ARN `taskDefinition` | Same |
| Security group group references (new rules) | Stored on 2.2.0 | Stored |
| `revoke-security-group-ingress` | Still returns `True` and removes nothing | Removes |
| Persistence | Target, policies, alarms all survive a restart | n/a |
| Fargate start latency | About 7 s (desired -> running) | 20-60 s |

**Observed versus reasoned about** (Section 12.1, placed for this build; also
in the notes).

*Observed, beyond the control-plane list:*
- an alarm moving to ALARM because a metric moved
- three scaling activities whose `Cause` names the alarm and the policy
- the step table selecting +3
- the ceiling clamping the result
- ECS starting the tasks
- suspension blocking a scale-out
- the managed alarms' 3 / 15 evaluation asymmetry
- persistence of all of it

*Reasoned about, not observed:*
- the target tracking calculation
- a cooldown holding a second scale-out (the opposite was observed)
- `DisableScaleIn` in action
- the 15-minute scale-in
- any scheduled action
- registration enforcing the floor
- Fargate's real start time and the grace period's effect
- cost

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
./scripts/utilities/verify-lab-06.sh
```

Expected: `PASS=39  FAIL=3`, the three scheduled-action checks.

To roll the emulator back to the pre-Lab 06 state:
1. `floci-down`
2. restore `~/floci-data-lab-05-complete-1.5.34.tar.gz` into `~`
3. set the image back to 1.5.34
4. `floci-up`
