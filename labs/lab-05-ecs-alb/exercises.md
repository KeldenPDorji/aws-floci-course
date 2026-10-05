# Lab 05 - Independent Exercises 1-5

Environment:
- Floci 1.5.34, AWS CLI 2.36.23, account `000000000000`, `us-east-1`
- load balancer `usms-enrolment-alb`, listener HTTP:80, target group `usms-enrolment-tg`

This lab has no exercise screenshots: Section 14.2 asks only for Checkpoints
4, 5 and 7. The evidence is the command output, saved under `outputs/` as
`lab-05-ex1.txt` to `lab-05-ex5.txt`, `lab-05-lb-report*.txt/.json` and
`lab-05-lab04c-readiness.txt`, and quoted below.

All commands assume `configs/course.env` and `lab-01` to `lab-05.env` are
sourced, with `$LISTENER_ARN` from Step 8. Floci's ELBv2 data plane is
reachable only inside the Docker network, so request tests use
`docker exec floci curl http://localhost:80/...`.

---

## Exercise 1 - A second path through the same load balancer

```bash
RESULTS_TG_ARN=$(aws elbv2 create-target-group --name usms-results-tg --protocol HTTP --port 80 --vpc-id "$USMS_VPC_ID" --target-type ip --health-check-path / --matcher HttpCode=200-399 --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn "$RESULTS_TG_ARN" --attributes Key=deregistration_delay.timeout_seconds,Value=15
jq -n --arg tg "$RESULTS_TG_ARN" '[{Type:"forward",TargetGroupArn:$tg}]' > templates/lab-05-results-rule-actions.json
RESULTS_RULE_ARN=$(aws elbv2 create-rule --listener-arn "$LISTENER_ARN" --priority 20 --conditions file://templates/lab-05-results-rule-conditions.json --actions file://templates/lab-05-results-rule-actions.json --tags Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results --query 'Rules[0].RuleArn' --output text)
```

How it was built:
- The **conditions** document (`/results`, `/results/*`) contains no variable,
  so it is a static file.
- The **actions** document needs the new target group's ARN, so it is
  generated with `jq --arg`, which makes it valid JSON by construction.
- Both ARNs are captured with `$(...)` and `--query`. Neither is recorded in
  `configs/lab-05.env`, because Exercise 4 removes them.

**Result** (`outputs/lab-05-ex1.txt`), the rules in evaluation order:

```text
10       /alb-health,/alb-health/*   fixed-response   -
20       /results,/results/*         forward          usms-results-tg
default  -                           forward          usms-enrolment-tg
usms-results-tg  ip  HTTP  80  /  200-399  1
dereg delay: 15  targets: 0
/results 503
```

**Sorting the rules.** `describe-rules` returns `Priority` as a *string*, and
the default rule's priority is the word `default`. A plain string sort would
put `"10"` after `"5"`, and would put `default` wherever the alphabet places
it. The listing above sorts in `jq` instead: numbered rules use their number
(`tonumber`), and `default` is mapped to `1e9` so it always comes last.

**The empty target group.** `usms-results-tg` is attached to one load
balancer and holds 0 targets: neither healthy nor unhealthy, because there is
nothing to judge. A request to `/results` therefore gets **503 Service
Temporarily Unavailable**. Rule 20 matched and forwarded to a target group
with no healthy target. That is the `503` case in Section 11's `curl` entry,
which says "the listener and rule worked; the problem is entirely on the
target side". Floci's data plane returned exactly that `503`.

---

## Exercise 2 - Repairing the verification script Step 13 broke

**The property the old check asserted.** "The enrolment tasks accept traffic
only from a *named group*, their single upstream tier, and never from an
address range." The old expression,
`IpPermissions[0].UserIdGroupPairs[0].GroupId == $USMS_APP_SG`, tied that
property to one architecture, Lab 04's. It also read only the first pair of
an unordered list, so it would have been wrong as soon as Step 9 added a
second source.

**The change** (`scripts/utilities/verify-lab-04.sh`):

1. `configs/lab-05.env` is sourced *optionally*
   (`2>/dev/null || true`), and `USMS_ALB_SG` defaults to empty with
   `: "${USMS_ALB_SG:=}"`. A student with Lab 04 done and Lab 05 not started
   gets a readable result instead of an unbound-variable abort under `set -u`.
2. The upstream group is chosen from the architecture the repository is in:
   - with `lab-05.env`, the upstream is `usms-alb-sg` and the retired group is
     `usms-app-sg`
   - without it, the upstream is `usms-app-sg` and nothing is retired
3. The original check was changed, not deleted. It now reads "sourced from
   its upstream group `<name>` (not a CIDR)" and greps **all** source pairs
   for the upstream group, not only the first.
4. A new check follows it: "no longer admits `<retired group>`". Without it,
   the first check passes while *both* paths exist, which is exactly the
   unfinished-migration state Step 13 warns about.
5. The header states the count. There are **39 checks** (previously 38),
   with or without Lab 05. On Floci 1.5.34 the expected result is
   `PASS=38 FAIL=1`.

An undocumented count is worse than none. A check that silently stops
running, for example because a quoting change turns it into a no-op, leaves
`FAIL=0` looking just as green. A stated `PASS+FAIL=39` makes a vanished or
duplicated check visible at a glance.

**Result** (`outputs/lab-05-ex2.txt`):

```text
== with lab-05.env (run from /tmp)
  FAIL usms-enrolment-sg is sourced from its upstream group usms-alb-sg (not a CIDR)
  ok   usms-enrolment-sg no longer admits usms-app-sg
PASS=38  FAIL=1
== without lab-05.env
  FAIL usms-enrolment-sg is sourced from its upstream group usms-app-sg (not a CIDR)
  ok   usms-enrolment-sg no longer admits no retired group (pre-Lab 05)
PASS=38  FAIL=1
== verify-lab-05
PASS=46  FAIL=4
```

**Why it cannot reach `FAIL=0` here.** Floci accepts `UserIdGroupPairs` and
stores none. Both rules on `usms-enrolment-sg` read back as `tcp 80` with no
source, so no check that reads the real source group can pass on this build.
The remaining failure is the Lab 02 limitation, now confirmed on a fifth
group, not a script bug. On real AWS the repaired script reports `FAIL=0`
after a completed cutover. It reports `FAIL=1` on the "no longer admits"
line if the old rule is still there, which is the case Floci's no-op revoke
creates (report Section 3.7).

The "no longer admits `usms-app-sg`" check passes *vacuously* on Floci,
because there are no stored pairs to match. That is why `verify-lab-05.sh`
also counts ingress rules (exactly one), and that count is what catches the
two-path state here.

**Commit message:**

```text
verify-lab-04: assert the enrolment tasks' upstream group, not usms-app-sg by name

Lab 05 moved the only client of usms-enrolment-sg from the web tier to the
load balancer. The check now follows the architecture in configs/ and adds
the reverse assertion, so two paths cannot both pass. 39 checks.
```

**When updating a verification script is right, and when it hides a
regression.** Update it when the *specification* changed on purpose, and do
it in the same change that alters the architecture, with a message saying
why. If the script is changed only because it went red, with nothing in the
design behind the change, that is how a regression gets hidden: the check
is rewritten to match the bug.

---

## Exercise 3 - A load balancer report tool

[`scripts/utilities/usms-lb-report.sh`](../../scripts/utilities/usms-lb-report.sh)

The work is split between bash and python:
- **Bash does discovery**, one AWS call per object:
  - load balancers, filtered with `starts_with(LoadBalancerName,'usms-')`
  - listeners per load balancer
  - rules per listener
  - target health per target group
- **`python3` does the joining and formatting**, because four levels of
  nested JSON is where bash stops being readable.

Edge cases, each handled explicitly instead of crashing:

| Case | Output |
|---|---|
| No `usms-*` load balancer | `no usms-* application load balancers found` (seen in the dry run before Step 5) |
| A load balancer with no listeners | `(no listeners - this load balancer answers nothing)` |
| A listener whose rules can't be read | `(no rules returned)` |
| A target group with no targets | `(0 targets, 0 healthy)`, never an empty column |
| An action that isn't `forward` | Its own summary: `fixed-response 200`, `redirect 301 HTTPS:443` |

The rule order is evaluation order, with `default` last. The sort key is
`(0, int(priority))` for numbered rules and `(1, 0)` for the default, as the
comment in the script explains. It runs with `set -uo pipefail` **without
`-e`**: one load balancer with no listeners must print a row saying so,
rather than abort and silently drop every load balancer after it.

**Result** (run after Exercise 1, before Exercise 4):

```text
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  10       path-pattern  /alb-health,/alb-health/*     -> fixed-response 200
    prio  20       path-pattern  /results,/results/*           -> usms-results-tg    (0 targets, 0 healthy)
    prio  default  -             -                             -> usms-enrolment-tg  (4 targets, 4 healthy)
IDENTICAL from ~ and labs/lab-05-ecs-alb/
```

The JSON form is in `outputs/lab-05-lb-report.json`.

The report also exposed something no earlier step showed. **4 healthy
targets** behind a service with desired 2 and running 2. After the Step 16
restart, Floci started two new task containers and did not stop the two old
ones. The old containers stayed registered and stayed healthy. Lab 4's
question 6 predicted this orphan state for a restart: four containers, two
of them managed by nothing. A report that counts targets per target group
caught it, and `describe-services` did not.

---

## Exercise 4 - The exposure review

*To the information security officer.*

### What changed, in two sentences

The network path is now: internet -> `usms-enrolment-alb` (whose nodes are in
the two public subnets) -> a private connection to the enrolment tasks,
which remain in private subnets with no public address. The tasks' security
group now admits tcp/80 from the load balancer's security group. The rule
that admitted the portal's group directly was revoked as the final step, and
`usms-alb-sg` is the only group in the design that admits `0.0.0.0/0`.

(On the emulator used here the revoke did not take effect: see "Status on
this environment" below.)

### Internet-facing or internal

**For `--scheme internal`.** The only known client of the enrolment API is
the student portal, `usms-web-01`, which is inside `usms-vpc`. Students
never call the API directly. An internal load balancer removes the internet
from the picture entirely, which is the strongest answer to "should I be
worried".

What would change in Step 5:
- `--scheme internal`
- `--subnets` set to `usms-private-subnet-a` and `-b`
- `usms-alb-sg` admitting tcp/80 from `usms-app-sg` instead of `0.0.0.0/0`

The DNS name would still be published by AWS, but it would resolve only to
private addresses, so it would be usable only from inside the VPC or a
connected network.

What would **not** change at all:
- the target group
- the listener and its rule
- the service attachment
- the tasks
- `usms-enrolment-sg` admitting only `usms-alb-sg`

**My recommendation for USMS enrolment is `internal`**, for as long as the
portal is the only client.

**The other side.** A mobile app or third-party integration that calls the
API directly would need it internet-facing, and putting it behind the load
balancer now saves a later migration. An internet-facing load balancer with
HTTPS and a narrow listener is also a well-trodden, defensible pattern. The
tasks stay private either way.

### The exposure delta

| | Before this lab | After this lab (as designed) |
|---|---|---|
| What can reach the load balancer | Nothing (no load balancer) | Anyone on the internet, tcp/80 (and 443 once a listener exists), via `usms-alb-sg` `0.0.0.0/0` |
| What can reach the tasks | Anything carrying `usms-app-sg` (`usms-web-01`, `usms-web-02`), tcp/80 | Only the load balancer (`usms-alb-sg`), tcp/80 |
| What can reach the tasks **directly** | Both web servers, by task address | **Nothing.** Every request must pass a listener and rule that we configured |

The third row is the answer to the question asked. Nothing new can reach a
task directly. Before this lab, two web servers could. After it, only the
load balancer can, and the internet can reach only the load balancer.

**Status on this environment.** The Floci emulator accepted the revoke of the
old rule, returned `True`, and kept the rule (`outputs/lab-05-cutover.txt`).
So on this emulator both rules still exist. The emulator also enforces no
security groups at all, so neither rule has any effect here. On a real
account, the revoke must be confirmed with `describe-security-group-rules`
showing a single ingress rule before the review is signed off.

### Monthly cost, us-east-1

Sources, as published on the Elastic Load Balancing pricing page
(aws.amazon.com/elasticloadbalancing/pricing):
- **USD 0.0225 per ALB-hour**
- **USD 0.008 per LCU-hour**

Since 1 February 2024 AWS also charges **USD 0.005 per hour for each public
IPv4 address** (Amazon VPC pricing, "Public IPv4 address"). An
internet-facing ALB holds one per Availability Zone, so two here. A month is
730 hours.

**Idle** (running, no traffic):

| Item | Calculation | Monthly |
|---|---|---|
| ALB hours | 730 x 0.0225 | USD 16.43 |
| Public IPv4, 2 nodes | 2 x 730 x 0.005 | USD 7.30 |
| LCUs | 0 | USD 0.00 |
| **Idle total** | | **USD 23.73** |

An internal load balancer avoids the USD 7.30 IPv4 line.

**Under load.** An LCU is billed on the *largest* of four dimensions:
- 25 new connections per second
- 3,000 active connections per minute
- 1 GB processed per hour
- 1,000 rule evaluations per second, of which the first 10 rules processed
  per request are free

Assumptions:
- a baseline of **2 requests per second**, all month, with a 10 KB average
  response and no keep-alive reuse from browsers
- plus an enrolment-week peak of **100 req/s** for 2 hours on one Monday
  (Lab 04 Exercise 4)

| Dimension at baseline | Value | LCU |
|---|---|---|
| New connections | 2/s / 25 | **0.08** |
| Processed bytes | 2 x 10 KB x 3,600 = 72 MB/h / 1 GB | 0.07 |
| Active connections | about 120/min / 3,000 | 0.04 |
| Rule evaluations | 2 rules < 10 free | 0 |

For a low-traffic API, the dominant dimension is **new connections, not
bytes or rules**, because each small request is its own connection. Reusing
connections (keep-alive, or the portal holding a pool) would make it cheaper
still.

| Item | Calculation | Monthly |
|---|---|---|
| Baseline LCUs | 0.08 x 730 x 0.008 | USD 0.47 |
| Peak LCUs (100/s / 25 = 4 LCU, which also beats 3.6 GB/h of bytes) | (4 - 0.08) x 2 h x 0.008 | USD 0.06 |
| **Load balancer total, under load** | 23.73 + 0.47 + 0.06 | **USD 24.26** |
| For comparison: the two Fargate tasks it fronts | Lab 04 Exercise 4: 2 x USD 10.64 | USD 21.27 |

The load balancer costs **more than the two tasks behind it**, and nearly all
of that is the fixed hourly charge plus public IPv4. The traffic itself is
cents. This is why an idle, forgotten load balancer is a classic surprise
line on a bill. Re-check the three prices on the pages named above before
this goes to finance.

### The HTTPS plan

The Step 4 "Your turn" opened tcp/443 on `usms-alb-sg`. That makes the port
*open*. Nothing *listens* on it until the items below exist, in this order:

| # | Object | Provided by | Cost |
|---|---|---|---|
| 1 | A **domain name** students will use, such as `enrol.usms.example.edu` | **Outside**: the university's existing domain, or a registrar (Route 53 Domains or any other) | The university already pays for its domain |
| 2 | A **public TLS certificate** for that name | **AWS Certificate Manager** ("Requesting a public certificate", docs.aws.amazon.com/acm/latest/userguide/gs-acm-request-public.html) | **Free.** ACM public certificates have no charge, and ACM renews them automatically |
| 3 | A **DNS validation CNAME record** that ACM gives you, created in the domain's zone | Whoever runs the domain's DNS. Route 53 can create it with one click if it hosts the zone | Negligible |
| 4 | An **HTTPS:443 listener** on `usms-enrolment-alb`, with the ACM certificate and an SSL policy (for example `ELBSecurityPolicy-TLS13-1-2-2021-06`), default action `forward` to `usms-enrolment-tg` | Elastic Load Balancing ("Create an HTTPS listener", docs.aws.amazon.com/elasticloadbalancing/latest/application/create-https-listener.html) | No extra charge |
| 5 | On the **HTTP:80 listener**, change the default action to **type `redirect`**: `Protocol HTTPS`, `Port 443`, `StatusCode HTTP_301` | Elastic Load Balancing listener rules | None |
| 6 | A **DNS record** pointing the name at the load balancer: a Route 53 alias, or a CNAME to its DNS name elsewhere | Route 53, or the university's DNS | Route 53 alias queries are free |

Step 5 is what keeps HTTP from carrying a login. Every plaintext request is
answered with a 301 to HTTPS, so credentials are only ever sent encrypted.
The priority-10 `/alb-health` fixed-response rule can stay on port 80,
because it carries no data. With these six objects in place, the
plaintext-login concern no longer applies.

### Tidy-up, executed

> **DANGER - delete the priority-20 listener rule**
> **What will be deleted:** the `/results` rule at priority 20 on the HTTP:80 listener. Not the listener, not the `/alb-health` rule, not the default action.
> **What depends on it:** nothing. It forwards to an empty target group, and no service exists for it.
> **Reversible?** Yes, the `create-rule` from Exercise 1 recreates it from `templates/`.
> **Effect on later labs:** none. Section 16 lists it under CLEAN UP.

> **DANGER - delete the `usms-results-tg` target group**
> **What will be deleted:** the target group `usms-results-tg`, which has no targets.
> **What depends on it:** only the priority-20 rule, which must go first, or `delete-target-group` fails with `ResourceInUseException`.
> **Reversible?** Yes, the `create-target-group` from Exercise 1, though the new one gets a new ARN.
> **Effect on later labs:** none. Lab 06 names `usms-enrolment-tg`, which is untouched.

```bash
aws elbv2 delete-rule --rule-arn "$RESULTS_RULE_ARN"
aws elbv2 delete-target-group --target-group-arn "$RESULTS_TG_ARN"
aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query 'Rules[].Priority' --output text
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output text
./scripts/utilities/verify-lab-05.sh | grep -E 'FAIL|PASS='
```

**Result** (`outputs/lab-05-ex4.txt`):
- rules `10 default`
- target groups `usms-enrolment-tg` only
- the KEEP column untouched, `/alb-health` included

Verify printed `PASS=45 FAIL=5` at that moment. The fifth failure,
`configs/lab-05.env has no empty values`, was real: it was the listener-ARN
bug in `write-lab-05-env.sh` (README, problem 7). Once that was fixed and the
file regenerated, verify returns the expected **`PASS=46 FAIL=4`**, all four
documented Floci limitations (report Section 3.9).

---

## Exercise 5 - The ResourceLabel hand-off to Lab 06

[`scripts/utilities/usms-resource-label.sh`](../../scripts/utilities/usms-resource-label.sh)
takes a load balancer name and a target group name. They default to this
lab's two. It derives both ARNs from the API and never reads
`configs/lab-05.env`.

**Why the two suffixes need different treatment.** The `ResourceLabel` wants
everything *after* `loadbalancer/` from the load balancer's ARN, but the
target group part *keeps* its resource type:

```text
...:loadbalancer/app/usms-enrolment-alb/219a302e65154d3c   -> app/usms-enrolment-alb/219a302e65154d3c
...:targetgroup/usms-enrolment-tg/5676809faf504f3d          -> targetgroup/usms-enrolment-tg/5676809faf504f3d
```

So the two parameter expansions differ:
- **load balancer:** `${LB_ARN#*:loadbalancer/}`, stripping the shortest
  prefix up to and including `:loadbalancer/`
- **target group:** `${TG_ARN##*:}`, stripping only the longest prefix
  ending in `:`, which leaves `targetgroup/` in place

That matches the `PredefinedMetricSpecification` reference, which documents
exactly this asymmetry.

**Validation (point 5).** Before printing, the script checks four things and
exits 1 if any fails:
- the label splits into **exactly six** `/`-separated segments
- segment 1 is the literal **`app`**
- segment 2 is the load balancer name
- segments 4 and 5 are `targetgroup` and the target group name

```text
label=app/usms-enrolment-alb/219a302e65154d3c/targetgroup/usms-enrolment-tg/5676809faf504f3d  segments=6  first=app
implausible ResourceLabel 'app/usms-enrolment-alb/219a302e65154d3c/' (lb='arn:...:loadbalancer/app/usms-enrolment-alb/219a302e65154d3c' tg='')
```

The second line is the negative test: a target group that doesn't exist is
refused, instead of producing a half label. The first segment is `app`
because the load balancer ARN encodes its type. For a Network Load Balancer
it would be `net`, and `ALBRequestCountPerTarget` would not apply to it at
all.

**The env file.** `./scripts/utilities/write-lab-05-env.sh
--with-resource-label` appends `USMS_ALB_RESOURCE_LABEL`, derived by the
script, not typed. That brings `configs/lab-05.env` to **16 exports**, with
no empty values and no `None`.

**Readiness file.** [`lab06-readiness.sh`](lab06-readiness.sh) writes
`outputs/lab-05-lab04c-readiness.txt`:

```text
resource_label        app/usms-enrolment-alb/219a302e65154d3c/targetgroup/usms-enrolment-tg/5676809faf504f3d
target_group_arn      arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/usms-enrolment-tg/5676809faf504f3d
load_balancer_arn     arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/usms-enrolment-alb/219a302e65154d3c
scalable_resource_id  service/usms-ecs-cluster/usms-enrolment-svc
scalable_dimension    ecs:service:DesiredCount
desired_count         2
recommended_metric    ALBRequestCountPerTarget - enrolment load arrives as requests, and requests per target is the demand signal itself rather than CPU, a lagging side effect of it
replacement_start     2026-10-05T15:40:17Z
replacement_end       2026-10-05T15:41:50Z
replacement_seconds   93  (no replacement observed within 90s)
```

**The measurement (point 4).** The script works like this:
1. Take a UTC timestamp in `python3`.
2. Force a new deployment.
3. Poll until the set of task ARNs has changed *and* the target group is back
   to exactly `desired` healthy targets. "Exactly one deployment" can't be
   read on Floci, because `deployments` is always `null`.

Nothing was replaced within the 90-second bound. That matches Step 14:
Floci accepts `--force-new-deployment` and rolls nothing. **The number is
meaningless as a capacity-replacement time** and must not be used to size
Lab 06's cooldowns.

What to size against instead:
- **Measured on this build:** registration-to-`healthy` took **45 s** for a
  new task, in Step 11's scale to 3. That is the honest "time until a new
  task carries traffic" here: interval 30 s, healthy threshold 2, minus
  Floci's quick first probe.
- **On real AWS:** a rolling replacement of 2 tasks costs, per task:
  - Fargate start-up, typically tens of seconds and dominated by the image
    pull. AWS's Fargate documentation gives no fixed figure, which is itself
    worth noting.
  - plus at least `interval x healthy threshold` = 60 s to become healthy
  - plus the 30 s deregistration delay on the old task

  That is roughly 2-3 minutes per wave.

Lab 06's scale-out cooldown should be no shorter than that.

**Hand-off.** From that file alone, a Lab 06 reader has everything for the
`put-scaling-policy` call: the `ResourceLabel` for `ALBRequestCountPerTarget`,
the scalable resource ID and dimension, and the current floor. On this Floci
build, Application Auto Scaling is still not implemented (Step 3 probe), so
Lab 06 will take its fallback path. The label is ready for the day it runs on
a build that has it.
