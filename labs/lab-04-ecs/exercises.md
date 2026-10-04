# Lab 04 - Independent Exercises 1-5

Environment: Floci 1.5.34, AWS CLI 2.36.23, account `000000000000`,
`us-east-1`, cluster `usms-ecs-cluster`, support path B (ECS only). Evidence:
`screenshots/lab04-09-exercises-1-2.png`, `lab04-10-exercise-3-inventory.png`,
`lab04-11-exercise-4-cleanup.png`, `lab04-12-exercise-5-linkage.png`.

All commands assume `configs/course.env` and `lab-01` to `lab-04.env` are
sourced. On this Floci build `aws ecs wait services-stable` crashes (the
service's `deployments` array is `null`), so waits use
`aws ecs wait tasks-running` on the listed tasks instead.

---

## Exercise 1 - A second service, deployed

`usms-results-svc`: same blueprint as the enrolment service, a lower floor.

```bash
aws ecs create-service --cluster "$USMS_ECS_CLUSTER" --service-name usms-results-svc --task-definition usms-enrolment:1 --desired-count 1 --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=DISABLED}" --enable-ecs-managed-tags --propagate-tags SERVICE --tags key=Name,value=usms-results-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 key=Service,value=results --query 'service.serviceArn' --output text
```

**What changes and what must not.** These change: the name, the desired count
(1), and the `Service=results` tag. These must not change: the task
definition family, both private subnets, the security group and
`assignPublicIp=DISABLED`. Every ID comes from a sourced env file, and nothing
is typed by hand. The service is not recorded in `configs/lab-04.env`, because
Exercise 4 removes it.

**Result:**

```text
usms-enrolment-svc   ACTIVE  2  2  usms-enrolment:2
usms-results-svc     ACTIVE  1  1  usms-enrolment:1
```

There are two `ACTIVE` services with different names and different desired
counts, and each is running its desired number of real containers.

---

## Exercise 2 - A new revision, and a deployment

Revision 2 was built from a **copy** of the template, so the file that
produced revision 1 is preserved, just as revision 1 itself is:

```bash
jq '.memory = "1024" | .containerDefinitions[0].environment += [{name:"USMS_LOG_LEVEL",value:"info"}]' templates/lab-04-taskdef.json > templates/lab-04-taskdef-v2.json
aws ecs register-task-definition --cli-input-json file://templates/lab-04-taskdef-v2.json --query 'taskDefinition.taskDefinitionArn' --output text
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --task-definition usms-enrolment:2 --query 'service.taskDefinition' --output text
aws ecs wait tasks-running --cluster "$USMS_ECS_CLUSTER" --tasks $(aws ecs list-tasks --cluster "$USMS_ECS_CLUSTER" --query 'taskArns[]' --output text)
```

`256` CPU with `1024` MiB is a valid Fargate pair, and it is a string, like
every `cpu` and `memory` value.

**Result:**
- `diff` of the two templates shows exactly two changes: `memory` `512` to
  `1024`, and the added `USMS_LOG_LEVEL`/`info`.
- The service reports `taskDefinition` `usms-enrolment:2`.
- `revision 1: ACTIVE 512 | revision 2: ACTIVE 1024`. Revision 1 is still
  describable and still `ACTIVE`, because deregistering is a separate action
  this exercise does not take.
- Revision 2's environment holds `USMS_SERVICE`, `USMS_BUCKET`, `AWS_REGION`
  and `USMS_LOG_LEVEL`.

**One sentence:** a task-definition revision is immutable, so
`update-service --task-definition` changes only the service's *pointer*, its
`taskDefinition` field, and not the revision itself, the service's name, its
network configuration or its desired count.

**What Floci did not do.** `describe-tasks` afterwards shows both running
enrolment tasks still on `usms-enrolment:1` (started 11:12:55 and 11:13:25,
before the update), and their containers have no `USMS_LOG_LEVEL` variable.
Floci moved the pointer and rolled nothing. On real AWS, the default rolling
deployment (`minimumHealthyPercent` 100, `maximumPercent` 200) starts two
`:2` tasks, waits for them to be healthy, then stops the two `:1` tasks.
Capacity never drops below the desired count, which is what "a deployment
that does not drop traffic" means.

---

## Exercise 3 - An ECS configuration drift report

[`scripts/utilities/lab-04-ecs-inventory.sh`](../../scripts/utilities/lab-04-ecs-inventory.sh)

It works in three steps:

1. It lists services from the cluster (no hard-coded service name) and
   describes them all in one call.
2. It describes each service's task definition.
3. It prints one line per service and writes the same rows to
   `outputs/lab-04-ecs-inventory.json`.

Each verdict is computed, never taken from a name or tag:

| Column | Computed from |
|---|---|
| `roles` | `SAME` / `SEPARATE` by comparing `executionRoleArn` with `taskRoleArn`; `INCOMPLETE` if either is missing |
| `publicip` | `RISK` / `OK` from `assignPublicIp`; `N/A` when there is no `networkConfiguration` (an `EC2` launch-type service) instead of an error |

Constraints:
- It runs from any directory: `REPO_ROOT` comes from `${BASH_SOURCE[0]}`.
- It uses `set -uo pipefail` **without `-e`**, justified in the header. One
  service whose task definition can't be described should become an explicit
  `N/A` on its own line. It must not abort the run and silently omit every
  service after it, because an inventory that drops a risky service is worse
  than one that never ran.
- The two calls it cannot work without (`list-services`,
  `describe-services`) are checked explicitly and `die` with a message.

**Result:**

```text
usms-enrolment-svc     desired=2   running=2   taskdef=usms-enrolment:2   roles=SEPARATE   publicip=OK
usms-results-svc       desired=1   running=1   taskdef=usms-enrolment:1   roles=SEPARATE   publicip=OK
IDENTICAL output from ~ and from labs/lab-04-ecs/
```

The JSON rows match.

**Its blind spot, found by this lab.** `taskdef` reports the service's
pointer. After Exercise 2 that says `:2` while both running tasks are `:1`
(above). A real drift report should also compare each running task's
`taskDefinitionArn` with the service's, and flag `DEPLOYING` or `STUCK` when
they differ. That check would have caught Floci's missing rollout, and on
real AWS it catches a deployment wedged on a failing health check.

---

## Exercise 4 - The enrolment-week capacity plan

### Why a fixed `desiredCount` of 2 cannot answer the 08:03 problem

`usms-enrolment-svc` is a controller with one input, `desiredCount`, and
nothing in what this lab built ever changes it. The service reads no metric
(there is no scalable target or policy, and on this build not even a
Container Insights CPU metric to read). It reads no clock (there is no
scheduled action). The only way its capacity changes is a person running
`update-service`, as in Step 11. At 08:00 on enrolment Monday it therefore
runs exactly 2 tasks, the same as at 03:00 on a Sunday in July.

Last year's failure at 08:03 is what a fixed count does under a spike. The
load arrived in minutes and the capacity was decided weeks earlier. Even a
human watching a dashboard would be too slow, because Fargate tasks take
20-60 seconds to start and the spike is front-loaded into the first few
minutes. The same fixed 2 is also the "3am in July" complaint, since it
cannot go *down* either.

### Proposed plan for whoever builds Lab 6

Every number is derived. The two inputs marked *assumption* must be replaced
with measured values before Lab 6 encodes them.

| Input | Value | Source |
|---|---|---|
| Students in the first 20 minutes | 4,000 | Lab 04 Section 1 |
| Requests per registration | 10 | *assumption*: page loads plus API calls for module search, selection and confirmation |
| Average rate, first 20 minutes | 4,000 x 10 / 1,200 s = **33 req/s** | derived |
| Peak-to-average in the first minutes | 3x | *assumption*: the 08:03 failure says the load is front-loaded |
| Peak rate | 33 x 3 = **100 req/s** | derived |
| Throughput per task (256 CPU, at a 70% CPU target) | 25 req/s | *assumption*: to be measured by load-testing one task |

| Setting | Value | Derivation | If too high | If too low |
|---|---|---|---|---|
| **Minimum** | **2** | One task per AZ, so the loss of one AZ never takes the service to zero | Pays for idle tasks around the clock (each extra task is about USD 10.64/month) | 1 means a single AZ failure is a full outage |
| **Scheduled floor** (Mon 07:30-09:30 in enrolment week) | **6** | 100 req/s / 25 = 4 tasks, + 1 headroom, rounded to 6 so each AZ has 3 | 1.5-2 hours of extra tasks, only on enrolment Mondays: cents | The spike arrives faster than reactive scaling plus a 20-60 s start, which is the 08:03 failure again |
| **Maximum** | **10** | Double the computed need of 5, for a year-on-year surprise | Lets a runaway policy or a traffic flood multiply cost, and can exhaust database connections (`usms-db-01` takes the load next) | Caps the service below real demand. The policy wants more and cannot have it |
| **Target tracking** | CPU **70%** | Leaves headroom to absorb a burst during the 20-60 s it takes a new task to start | Scales late; requests queue while tasks start | Scales on noise; flapping capacity and cost |

What to tell the scaling team: start the floor *before* 08:00, because the
floor exists precisely to beat start latency. Make scale-in cooldowns longer
than scale-out cooldowns, so a dip at 08:10 doesn't drop capacity before the
next wave. And re-derive the two assumed numbers from a load test of one
task. On this Floci build they will have to work from a custom CloudWatch
metric, because `containerInsights` was not stored (report Section 3.2).

### Monthly cost (us-east-1, Linux/x86, Fargate on-demand)

Source: AWS Fargate pricing, aws.amazon.com/fargate/pricing (us-east-1):
**USD 0.04048 per vCPU-hour** and **USD 0.004445 per GB-hour**. These are list
prices as published; re-check them on that page before quoting them to
finance. A month is 730 hours.

| Task size | Per task-hour | Per task-month |
|---|---|---|
| Revision 2 (0.25 vCPU, 1 GB) | 0.25 x 0.04048 + 1 x 0.004445 = USD 0.01457 | **USD 10.64** |
| Revision 1 (0.25 vCPU, 0.5 GB) | 0.25 x 0.04048 + 0.5 x 0.004445 = USD 0.01234 | USD 9.01 |

| Option | Calculation | Monthly |
|---|---|---|
| **Fixed at today's 2** | 2 x 10.64 | **USD 21.27** - and it falls over at 08:03 |
| **Fixed at the proposed peak, 6** | 6 x 10.64 | **USD 63.82** - survives the spike, idle 99.9% of the month |
| **Floor 2 + scheduled 6 for 2 h on an enrolment Monday** | 21.27 + (4 extra x 2 h x 0.01457) | **USD 21.39** in an enrolment month; USD 21.27 otherwise |

The scheduled floor buys the peak capacity for about 12 cents an enrolment
Monday, about a third of the fixed-peak bill. Fixing the count at the peak
is the "3am in July" complaint, multiplied by three. Real numbers will also
include NAT data processing for image pulls on every scale-out, which is the
argument for an ECR pull-through cache or VPC endpoints from Lab 2.

### What to switch off, in dependency order

> **DANGER - scale `usms-results-svc` to zero, then delete it**
> **What will be deleted:** the ECS service `usms-results-svc` and its running task. The task definition family and the cluster are untouched.
> **What depends on it:** nothing; it is Exercise 1's practice service, absent from `configs/lab-04.env` and from Section 16's KEEP column.
> **Reversible?** The service is not, since it goes `INACTIVE`. It can be recreated from the same command in seconds.
> **Effect on later labs:** none. Lab 05 and Lab 06 use `usms-enrolment-svc` only.

```bash
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc --desired-count 0 --query 'service.[serviceName,desiredCount]' --output text
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service usms-results-svc --query 'service.[serviceName,status]' --output text
aws ecs list-services --cluster "$USMS_ECS_CLUSTER" --query 'serviceArns[]' --output text
./scripts/utilities/verify-lab-04.sh | tail -1
```

Scaling to 0 before deleting is the graceful order: delete without it needs
`--force`, which kills tasks without draining them. On real AWS a
`wait services-stable` sits between the two calls. On Floci that waiter
crashes, and `delete-service` succeeded directly.

**Result (screenshot 11):** `usms-results-svc 0`, then `INACTIVE`. Only
`usms-enrolment-svc` remains listed, and verify is `PASS=37 FAIL=1`,
unchanged by the deletion. Nothing in the KEEP column was touched.

---

## Exercise 5 - Close the loop back to Lab 3, and hand Lab 05 what it needs

[`lab03-linkage.sh`](lab03-linkage.sh) writes `outputs/lab-04-lab03-linkage.txt`.

**1. Resolve the source group.** The live rule should name it, but Floci
stores no group reference (`tcp 80 None None`, report Section 3.4). The
script therefore reads the live rule first and falls back to the document
the rule was written from, `policies/usms-enrolment-sg-ingress.json`,
recording which source it used. That gives `sg-38365af9db7017f8b`, which is
`usms-app-sg`.

**2. Reverse lookup.** It runs `describe-instances --filters
"Name=instance.group-id,Values=sg-38365af9db7017f8b"
"Name=instance-state-name,Values=running"`, then asks the same question
client-side (`SecurityGroups[].GroupId`), because Lab 2 found Floci ignores
some EC2 filters.

| Lookup | Returned |
|---|---|
| Filter | `i-16073b1702bcb7feb i-780a8f3d907d26922 i-80faf975c25aad581 i-f66018e669eb1530a`: **all four** running instances, including both database instances. Floci ignored the filter |
| Verified | `i-80faf975c25aad581 (usms-web-02), i-f66018e669eb1530a (usms-web-01)`: the correct two |

**3. Verdict.** `$USMS_WEB_INSTANCE` is `i-f66018e669eb1530a`, which is in
the verified list:

```text
verdict : LOOP CLOSED - usms-web-01 carries the group; also carried by: i-80faf975c25aad581 (usms-web-02)
```

The second carrier is the case the exercise anticipates: `usms-web-02` from
Lab 3 Step 18's "Your turn" carries the same group, so it is explained rather
than counted as a mismatch. The file states that the rule is temporary, and
that Lab 05 removes it once the load balancer becomes the only caller.
Because two web servers carry the group, that cutover changes what *both* of
them can reach.

**4. Tag audit.** `list-tags-for-resource` takes an **ARN**, not a name, so
it uses `$USMS_ECS_CLUSTER_ARN` and `$USMS_ENROLMENT_SERVICE_ARN`:

```text
cluster  tags: Project=USMS Tier=app Name=usms-ecs-cluster
service  tags: Project=USMS Tier=app Lab=04 Name=usms-enrolment-svc
```

Both carry `Project=USMS`, so Floci stores ECS tags on clusters and services.
A `tag-resource` call was made on the service anyway; it was not needed,
and re-applying tags is harmless. What Floci does *not* store is task
definition tags (`describe-task-definition` returns no `tags`), and the
`--propagate-tags SERVICE` copies onto tasks could not be observed.

**Why this file matters to someone else.** A reader preparing Lab 05's
cutover can open `outputs/lab-04-lab03-linkage.txt` and know four things:
which rule is about to be removed, which group it names, which two instances
lose their path to the enrolment service when it goes, and that on this
emulator the rule was never enforced anyway.
