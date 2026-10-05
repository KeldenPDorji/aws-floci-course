# Lab 05 - ECS behind an Application Load Balancer

## 1. Summary

This lab put a stable front door on the enrolment service Lab 04 left
unreachable. It created:

- `usms-alb-sg`, the only security group in the design that admits
  `0.0.0.0/0` (tcp/80, plus tcp/443 from the Step 4 "Your turn")
- `usms-enrolment-alb`: internet-facing, type `application`, one node in
  each public subnet (`us-east-1a`, `us-east-1b`)
- `usms-enrolment-tg`:
  - target type `ip`, HTTP/80, in `usms-vpc`
  - health check `GET /` every 30 s, timeout 5, healthy 2, unhealthy 2,
    matcher `200`
  - deregistration delay 30 s, `least_outstanding_requests`
- an HTTP:80 listener forwarding to it, plus a priority-10 rule answering
  `/alb-health` with a fixed `200`
- `usms-enrolment-svc` attached to the target group (`enrolment-api`, port
  80, grace period 60 requested), still on `usms-enrolment:2` with desired 2
- a new ingress rule on `usms-enrolment-sg` sourced from `usms-alb-sg`, and
  an attempted removal of Lab 04's rule sourced from `usms-app-sg`

The central idea held up in practice. **The service, not me, owns the
target list.** I never ran `register-targets`. The service registered its
two tasks, registered a third when desired went to 3, dropped it when desired
returned to 2, and the target group followed every change on its own.

**What this Floci build (1.5.34) does better than the guide expected.** It
has a real ELBv2 data plane inside its container:
- health checks really run, so targets moved `initial` -> `healthy`
- a request from `usms-web-01`'s container through the listener reached
  nginx in a task and came back `200`
- the `/alb-health` rule answered ahead of the default action
- a rule pointing at an empty target group returned `503`

**What it does worse**, each recorded in Section 7:
- `update-service --load-balancers` is accepted and not stored, so the
  service was recreated by the guide's fallback
- `healthCheckGracePeriodSeconds` is not stored
- group references in security group rules are not stored
- **`revoke-security-group-ingress` is a no-op**: it returns `True` and
  removes nothing. The Step 13 cutover therefore could not take effect, and
  both tcp/80 rules remain on `usms-enrolment-sg`
- a forced deployment replaces nothing, and `deployments` is always `null`
- the DNS name doesn't resolve from the host

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| Security groups | `usms-alb-sg` `sg-8f6bfa2a32f0f9d39` (in: 80, 443 from `0.0.0.0/0`); `usms-enrolment-sg` `sg-2bbe1b1e99ac4c923` (in: `sgr-6bde17306c6762bd2` from `usms-alb-sg` as written, and Lab 04's `sgr-620d28baab7e7ef1c`, which the revoke could not remove) |
| Load balancer | `usms-enrolment-alb` `app/usms-enrolment-alb/219a302e65154d3c`, `active`, 2 AZs, DNS `usms-enrolment-alb-219a302e65154d3c.elb.floci`, idle timeout 60, invalid headers dropped |
| Listener / rule | HTTP:80 `221ea146b7a34946`, default `forward`; rule `519874ba7da745f1`, priority 10, `/alb-health`, `/alb-health/*` -> fixed-response 200 |
| Target group | `usms-enrolment-tg` `5676809faf504f3d`, as above |
| Service | `usms-enrolment-svc` (recreated with the same name, settings and `Lab=04` tag), one `loadBalancers` entry |
| Files | `policies/usms-alb-sg-ingress.json`, `-ingress-https.json`, `usms-enrolment-sg-ingress-alb.json`; `templates/lab-05-*.json` (6); `configs/lab-05.env` (16 exports with Exercise 5); scripts `verify-lab-05.sh`, `write-lab-05-env.sh`, `lab-05-probe.sh`, `wait-targets.sh`, `lab-05-path-proof.sh`, `lab-05-deploy-snapshot.sh`, `lab-05-restart-facts.sh`, `usms-lb-report.sh`, `usms-resource-label.sh`, `labs/lab-05-ecs-alb/lab06-readiness.sh`, `scripts/cleanup/lab-05-cleanup.sh` (never run); `verify-lab-04.sh` repaired (Exercise 2) |

---

## 2. Evidence index

Section 14.2 asks for screenshots of Checkpoints 4, 5 and 7. The other
evidence items are files under `outputs/` (git-ignored), quoted where they
are used. Each screenshot was cleared before capture.

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoint 4: service attached (`enrolment-api`/80/tg), unchanged revision, private subnets, no public IP; two targets **registered by the service** and `healthy`; ECS health beside target health | [3.5](#35-checkpoint-4---the-service-registers-its-own-targets) |
| 02 | Checkpoint 5: a forced deployment, and the reason no `draining` was observable | [3.8](#38-checkpoint-5---a-deployment-behind-the-load-balancer) |
| 03 | Checkpoint 7: `PERSISTENCE PROVEN` across a Floci restart, every ARN re-derived | [3.10](#310-checkpoint-7---persistence) |
| 04 | Step 13's cutover attempt and the `verify-lab-04` diff; Step 17's `MISMATCH` / `LOOP CLOSED`; ELBv2 tag audit | [3.7](#37-the-cutover-step-13), [3.11](#311-closing-the-loop-step-17) |
| 05 | Section 9: `verify-lab-05.sh` `PASS=46 FAIL=4`; `lab-05.env` populated, 15 exports; cleanup `bash -n`; Git hygiene | [3.9](#39-verification-and-recording-state) |

---

## 3. Build walkthrough (Steps 1-19)

### 3.1 Resuming, Checkpoint 1 and the support probe

Floci was resumed and the five env files sourced. Both public subnets exist
in two different zones (`outputs/lab-05-public-subnets.txt`):

```text
subnet-5048cd0c   us-east-1a   10.0.1.0/24
subnet-c34fe540   us-east-1b   10.0.2.0/24
```

`verify-lab-04.sh` was captured before any change
(`outputs/lab-05-pre-verify-04.txt`): `PASS=37 FAIL=1`. The one failure is
the documented Lab 04 state, Floci not storing group references. `FAIL=0` is
not reachable on this build, and the guide's "do not start" rule is about
*unexplained* failures. Lab 02 is at its documented `PASS=32 FAIL=1`.
`usms-web-01` was put through an API start first, because Lab 3 found its
container can be dead while the API says it is running.

**The probe.** I used the same text-classifying probe as Lab 04
(`scripts/utilities/lab-05-probe.sh`), because the guide's exit-code version
misreads a `ValidationError` as "not available". Every ELBv2 and EC2 call
answered. `application-autoscaling` is `not available`. Before writing any
command, I tested the whole chain once on throwaway `usms-probe-*` objects,
all deleted afterwards. That found the four behaviours this walkthrough is
built around: `update-service` not storing `--load-balancers`, the in-Docker
data path, the no-op revoke, and the forced deployment that rolls nothing.

**Support path: B, plus a data path inside Docker** (`notes/lab-05-notes.md`,
first line). The DNS name doesn't resolve from the host, so this is not path
A. But health checks and request forwarding do work inside the Docker
network.

### 3.2 The load balancer's security group, and the load balancer (Steps 4-5)

`usms-alb-sg` was created in `usms-vpc` with `Tier=edge`. Both ingress
documents are static, so they were written as files with no variable in
them:
- **80 from `0.0.0.0/0`**: the one deliberate internet-wide rule in the
  course
- **443 from `0.0.0.0/0`**: the "Your turn". The port is now open, and
  nothing listens on it (notes, Step 4)

`usms-enrolment-alb` came back `active` from `wait load-balancer-available`
on the first poll. Real AWS takes 2-4 minutes. Its two zones are
`us-east-1a` / `subnet-5048cd0c` and `us-east-1b` / `subnet-c34fe540`
(`outputs/lab-05-alb.json`). `idle_timeout.timeout_seconds=60` and
`routing.http.drop_invalid_header_fields.enabled=true` were stored.

**Floci enforces the two-AZ rule.** Creating a second load balancer with
only `usms-public-subnet-a` was refused
(`outputs/lab-05-one-az-test.txt`), and nothing was created:

```text
InvalidConfigurationRequest: Application Load Balancers must be attached to subnets in at least two Availability Zones.
```

The ARN suffix `app/usms-enrolment-alb/219a302e65154d3c` is the first half
of Exercise 5's `ResourceLabel`.

### 3.3 Target group, attributes and listener (Steps 6-8)

`usms-enrolment-tg` was created exactly as specified. Every value read back
as written (`outputs/lab-05-tg.json`):
- `TargetType ip`, HTTP/80, `VpcId vpc-1441470d`
- `HealthCheckPath /`, `traffic-port`, 30 / 5 / 2 / 2, matcher `200`

The time to remove a dead task is interval x unhealthy threshold = **60 s**.

`deregistration_delay.timeout_seconds=30` and
`load_balancing.algorithm.type=least_outstanding_requests` were set as
attributes and stored. The Step 6 "Your turn" widened the matcher to
`200-399` and restored it to `200`, both in place.

The listener's default action document needs `$TG_ARN`. I generated it with
`jq -n --arg` instead of an unquoted heredoc: valid JSON by construction, and
`grep -c '\$'` gives 0. After `create-listener`, the target group's
`LoadBalancerArns` went from 0 to 1. That is the evidence that the two
objects are connected.

### 3.4 The tasks' new ingress rule, and the in-place attach (Steps 9-10)

**Step 9.** `policies/usms-enrolment-sg-ingress-alb.json` names
`usms-alb-sg` (`sg-8f6bfa2a32f0f9d39`) in `UserIdGroupPairs`, again written
with `jq --arg`. `authorize-security-group-ingress` returned rule ID
`sgr-6bde17306c6762bd2`, and I kept that ID in the shell. Floci stores the
rule as `tcp 80` with **no source**, just like the Lab 04 rule beside it. So
on this build the only way to tell the two rules apart is their rule IDs,
which is how Step 13 had to work.

**Step 10, the in-place attach.** `update-service --load-balancers ...
--health-check-grace-period-seconds 60` succeeded and returned
(`outputs/lab-05-inplace-attach.json`):

```json
{ "LB": null, "Grace": null, "TaskDef": "usms-enrolment:2" }
```

This is the case the guide's warning describes, so its fallback was taken.
I adapted it in three ways:
1. The fallback calls `aws ecs wait services-stable`, which crashes on this
   build (Lab 04, problem 6). The old tasks' ARNs were captured first, and
   `wait tasks-stopped` waited on them.
2. It passes `--deployment-configuration
   file://templates/lab-04-deployment-config.json`, a file that doesn't
   exist in this repository. The same values went inline instead:
   `maximumPercent=200,minimumHealthyPercent=100`.
3. Everything else is Lab 04's own value: the name, the cluster,
   `usms-enrolment:2`, desired count `$USMS_ECS_DESIRED_BASELINE`, both
   private subnets, `usms-enrolment-sg`, `DISABLED`, managed and propagated
   tags, and `Lab=04`.

`create-service` *does* store `loadBalancers` (the probe confirmed this
before I relied on it). It still drops `healthCheckGracePeriodSeconds`. The
attachment changed no task definition. `usms-enrolment:2` is unchanged,
because where traffic comes from is a property of the service.

### 3.5 Checkpoint 4 - the service registers its own targets

`scripts/utilities/wait-targets.sh` waited until the target group held
exactly two `healthy` targets. No aws waiter can do that:
`target-in-service` returns as soon as the *current* targets are healthy,
which is immediately true before a task has registered.

![Checkpoint 4: usms-enrolment-svc ACTIVE 2 2 usms-enrolment:2, grace None; loadBalancers enrolment-api 80 usms-enrolment-tg; subnets cbeebb5f,2b5f6829 DISABLED; targets 172.19.0.3 and 172.19.0.4 healthy on 80; two tasks RUNNING with healthStatus None](../../screenshots/lab05-01-checkpoint4-service-and-targets.png)

- **The service's `loadBalancers` entry** reads `enrolment-api`, `80`,
  `usms-enrolment-tg/5676809faf504f3d`. The task definition is still
  `usms-enrolment:2`.
- **Both private subnets, `DISABLED`.** The tasks did not become public;
  only something in front of them did.
- **Two targets, both `healthy`, put there by the service.** Their `Id` is
  an address, as an `ip` target group requires. The addresses are
  `172.19.0.3` and `.4`, the containers' Docker-network addresses. On AWS
  they would be ENI addresses inside `10.0.3.0/24` and `10.0.4.0/24`, one
  per zone. Floci gives tasks no ENI (Lab 04, Section 7), so the "one address
  in each private subnet" item is reasoned about, not observed. The path
  proof labels them accordingly.
- **The two health opinions side by side.** Both tasks are `RUNNING` with
  `healthStatus` `None`, and both targets are `healthy`. That is row 4 of the
  diagnostic table (`UNKNOWN` + `healthy`): not a fault. Floci reports no
  container health status, and the load balancer independently finds the
  tasks reachable. The table itself is in the notes.
- **Grace period `None`, events 0** (the earlier capture). Both are Floci
  limitations; Floci records no service events.

**Step 11 "Your turn"** (`outputs/lab-05-desired-3-and-back.txt`). Desired 3
gave three healthy targets after **45 s** (`.3`, `.4`, `.6`). Desired 2 gave
two targets 5 s later (`.3`, `.6`). Floci stopped the `.4` task. Not one
`register-targets` call was made.

### 3.6 Proving the path (Step 12)

`scripts/utilities/lab-05-path-proof.sh` re-derives every ARN by name and
walks the chain link by link. It then tries the data path from three places
(`outputs/lab-05-path-proof.txt`):

```text
== 1. listener a client connects to ==   HTTP 80 forward tg/usms-enrolment-tg/5676809faf504f3d
== 2. target group it forwards to ==     usms-enrolment-tg ip HTTP 80 / vpc-1441470d
== 3. targets ==   172.19.0.3 healthy, 172.19.0.6 healthy  (Floci Docker network)
== 4. the service ==  usms-enrolment-svc enrolment-api 80 None  -> names tg/usms-enrolment-tg/...
== 5. the firewall ==  usms-alb-sg = sg-8f6bfa2a32f0f9d39
                       sgr-6bde17306c6762bd2 tcp 80 None
                       sgr-620d28baab7e7ef1c tcp 80 None
== 6. data path ==
  host -> http://usms-enrolment-alb-219a302e65154d3c.elb.floci/   does not resolve (no public DNS on Floci)
  floci -> http://localhost:80/      HTTP/1.1 200 OK Server: nginx/1.30.5
  usms-web-01 -> http://floci:80/    HTTP/1.1 200 OK Server: nginx/1.30.5
```

Blocks 1-4 are the chain:
- the listener names the target group
- the target group holds the targets
- the service names the same target group

Block 5 is where this build can't prove the last link. Both rules show no
source, so "`usms-enrolment-sg` admits `usms-alb-sg`" is true only *as
written* in `policies/usms-enrolment-sg-ingress-alb.json`.

The data path is the result the guide said I might not get, and on this
build it is a qualified yes:
- **From the host:** no. The name doesn't resolve.
- **From inside the Docker network:** yes, end to end. Floci's
  `ElbV2DataPlane` binds each listener port inside its own container (its log
  reads `ELBv2 listener port started on 80`). A request from **`usms-web-01`'s
  own container**, the portal, the real client in the story, went through
  the listener to an nginx task and came back `200 OK`.

So I'm recording a served request. I'm careful to say *where* it was served
from: the Docker network, not the internet.

### 3.7 The cutover (Step 13)

Step 13's lookup filters rules by `ReferencedGroupInfo.GroupId ==
usms-app-sg`. It would return `None` here, because no rule has a stored
source. I identified the Lab 04 rule as "the ingress rule that is **not**
`$ALB_RULE_ID`", which was captured from Step 9's own output. Then I tried
both revoke forms the API offers:

| Attempt | Returned | Rule removed? |
|---|---|---|
| `revoke-security-group-ingress --security-group-rule-ids sgr-620d28baab7e7ef1c` | `True` | No |
| `revoke-security-group-ingress --ip-permissions file://policies/usms-enrolment-sg-ingress.json` (Lab 04's own document) | `True` | No |

The probe had already shown, on a throwaway group, that this build's revoke
removes nothing in any form: by rule ID, by group pair, by CIDR, or by the
source-less stored form. **So the cutover could not be carried out on
Floci 1.5.34.** Both tcp/80 rules remain. On a real account the first call
alone would have removed exactly one rule.

Here, two habits mattered:
- I **read the rule list back after a revoke that said `True`**, which is
  Lab 4's lesson that a command reporting success is not evidence.
- I **did not work around it**, for example by recreating `usms-enrolment-sg`.
  That would have changed an ID Lab 04, Lab 06 and both verify scripts depend
  on, to fake a result the emulator cannot produce.

The guide expected `verify-lab-04.sh` to flip from `49/0` to `48/1` on
exactly one line. Here, `diff` of the before and after captures printed
**nothing**: `PASS=37 FAIL=1` both times. That check was already failing,
because group references were never stored, so the architecture change was
invisible to it. A check that can't distinguish the old design from the new
one is the deeper version of Section 13's point. Exercise 2 rewrites it
against the property.

Screenshot 04 (in [3.11](#311-closing-the-loop-step-17)) shows the before,
the two `True`s and the identical after.

### 3.8 Checkpoint 5 - a deployment behind the load balancer

Steps 14 and 15. `lab-05-deploy-snapshot.sh` recorded the revision, the
counts, the target addresses and the task IDs before and after
`--force-new-deployment`. Instead of the guide's `sleep` loop, a bounded
deterministic wait asked the one question that matters: "does any target
reach `draining` within 60 s?"

![Checkpoint 5: force-new-deployment returns usms-enrolment:2 with 0 deployments; wait-targets TIMEOUT after 60s, 0 targets draining; pre and post snapshots identical - same revision, 2 2, same addresses 172.19.0.3 172.19.0.6, same task IDs](../../screenshots/lab05-02-checkpoint5-forced-deployment.png)

- `update-service --force-new-deployment` was accepted on `usms-enrolment:2`.
  Its deployment count is **0**, because `deployments` is `null` on this build.
- **No target drained** in 60 s.
- **Before and after are identical:** same revision, `2 2`, same addresses
  (`172.19.0.3 172.19.0.6`), same task IDs. Nothing was replaced.

So the states `initial` -> `healthy` -> `draining` from a deployment were
**not observable**. `initial` -> `healthy` *was* observed, during attachment
and the scale to 3. The Lab 04 finding "Floci does not roll a deployment"
now holds for forced deployments too. On real AWS the post snapshot would
show new addresses, and a poll would catch `draining` beside `healthy` for
up to the 30-second deregistration delay.

The snapshots list five task IDs, not two, because Floci's `list-tasks`
returns stopped tasks too: Lab 04's two originals and the one from the scale
to 3. Only the two IDs behind live targets are running.

**Step 15, the rule** (`outputs/lab-05-rule.txt`). The priority-10 rule
matches `/alb-health` and `/alb-health/*` and returns a fixed-response
`200`. `describe-rules` lists it above the default action, which appears
with priority `default` and `IsDefault True`. Unlike the guide's expected
result, it was **tested against the data plane**:

```text
usms-enrolment-alb ok      <- /alb-health 200   (the rule's own body: no task involved)
/ 200                      (default action: forwarded to nginx)
```

The body is the one in `templates/lab-05-rule-actions.json`, which shows the
rule fired before the default action.

### 3.9 Verification and recording state

`configs/lab-05.env` is generated by `scripts/utilities/write-lab-05-env.sh`.
That is the guide's Step 18 heredoc moved into a script, with every value a
lookup.

Two fixes went in after the first run produced a wrong file:
1. **The listener ARN line was empty.** In the guide's heredoc, the escaped
   backticks around `80` reach JMESPath still escaped, inside a `$(...)` in an
   unquoted heredoc. The query fails and `USMS_ALB_LISTENER_ARN=` is written
   blank. The script now looks the listener up *before* the heredoc, as it
   does the ALB ARN.
2. **The guide's own empty-value check could not see it.** `grep -n 'export
   .*=$\|None'` uses `\|`, which macOS's BSD `grep` treats literally in a basic
   regex, so it printed "all values populated" over an empty value. It was
   replaced with `grep -nE 'export [A-Z_]+=$|=None$'`. `verify-lab-05.sh`
   already used `-E`, and it was verify's `configs/lab-05.env has no empty
   values` FAIL that exposed the bug.

The grace period is the one value Floci doesn't store. The file records the
value the service was created with (60) and says so in a comment. Verify
still reads the API, and still fails that check.

`verify-lab-05.sh` is the guide's script with three changes:
1. The `no secret is tracked by git` check gets the same `.gitkeep` fix as
   Lab 04.
2. The `LoadBalancerNotFound` stderr is silenced before the load balancer
   exists.
3. **One added check: `usms-enrolment-sg has exactly ONE ingress rule`.** The
   guide's "no longer admits `usms-app-sg`" check passes *vacuously* when no
   group references are stored, so on Floci it can't tell "cut over" from
   "two paths". Counting rules can.

![verify-lab-05.sh: four FAILs - admits from usms-alb-sg, exactly ONE ingress rule, grace period, exactly ONE deployment - PASS=46 FAIL=4; lab-05.env all values populated, 15 exports, target type ip, lb container enrolment-api, grace 60; cleanup syntax OK; nothing under outputs/ in git status; check-ignore .gitignore:8:outputs/*; ls-files outputs/ shows only .gitkeep](../../screenshots/lab05-05-verify-env-and-hygiene.png)

| Failing check | Cause | Real AWS |
|---|---|---|
| `usms-enrolment-sg admits tcp/80 from usms-alb-sg` | Group references accepted, never stored (Lab 02; fifth group) | Stored and enforced |
| `usms-enrolment-sg has exactly ONE ingress rule` | `revoke-security-group-ingress` is a no-op; the Lab 04 rule could not be removed (3.7) | One rule after Step 13 |
| `healthCheckGracePeriodSeconds is set` | Accepted on `create-service`, not stored | Stored; ECS ignores target health for 60 s |
| `exactly ONE deployment` | `deployments` always `null` | One `PRIMARY` deployment when stable |

The two the guide calls **not benign** are "two public subnets in two AZs"
and "cutover done". The AZ check passes. The cutover is the second failure
above, a real gap in the architecture as deployed *on this emulator*, caused
by the emulator. On real AWS, Step 13's single revoke closes it.

The rest of the screenshot is Step 19's look-before-you-add:
- 15 exports, populated
- target type `ip`, container `enrolment-api`, grace 60
- `lab-05-cleanup.sh` parses with `bash -n` and has never been run
- nothing under `outputs/` and no root `.env` in `git status`
- `git check-ignore -v` names `.gitignore:8:outputs/*`
- `git ls-files outputs/` lists only `.gitkeep`

The `listener:` field printed blank because that shell variable was set
before the fixed file was re-sourced. The file's value is correct (the grep
above it, and `outputs/lab-05-verify.txt`). Exercise 5 later appended the
`ResourceLabel`, making **16 exports**.

### 3.10 Checkpoint 7 - persistence

`scripts/utilities/lab-05-restart-facts.sh` derives every identifier from the
API:
- the load balancer and target group **by name**
- the listener by walking down from the load balancer
- the security group by tag

It prints the configuration facts across three services. It ran before
`floci-down.sh` and after `floci-up.sh`. `runningCount` and target health
are deliberately left out, because they are allowed to move.

![Checkpoint 7: re-derived alb, tg, listener and alb-sg identifiers; load balancer internet-facing application active 2 AZs 1 SG; target group ip HTTP 80 / 200 30 2; listener 80 HTTP forward; rules 10 fixed-response and default forward; service ACTIVE 2 enrolment-api 80 None; usms-alb-sg 443,80; usms-enrolment-sg ingress sgr-620d28baab7e7ef1c sgr-6bde17306c6762bd2; PERSISTENCE PROVEN](../../screenshots/lab05-03-checkpoint7-persistence.png)

`diff` printed nothing: **PERSISTENCE PROVEN**. Everything survived the
restart:
- the load balancer and its two AZs
- both security groups
- the full health check configuration
- the listener and the rule, in priority order
- the service's `loadBalancers` entry
- the two-rule state of `usms-enrolment-sg`

The sorted ports `443,80` and the sorted rule IDs keep the comparison
order-independent.

**One thing did change, outside the compared facts.** After the restart,
Floci started two *new* task containers for the service and did not stop the
two old ones. All four registered, and the target group now holds four
`healthy` targets for a service at 2/2 (`outputs/lab-05-post-restart-targets.txt`,
Exercise 3's report). That is the orphan state Lab 04's question 6 predicted
for a restart, now visible because a target group counts the containers.
The service record says 2; the data plane forwards to 4.

### 3.11 Closing the loop (Step 17)

![Step 13 cutover file: keep sgr-6bde17306c6762bd2, remove sgr-620d28baab7e7ef1c; before both; revoke by rule id True; revoke by permission True; after both still present; verify-lab-04 diff no check changed state PASS=37 FAIL=1; TASK_SOURCE MISMATCH expected sg-8f6bfa2a32f0f9d39 found None; LOOP CLOSED usms-web-01 i-f66018e669eb1530a carries usms-app-sg and now calls the ALB DNS name; describe-tags Lab=05 on loadbalancer, targetgroup, listener and listener-rule](../../screenshots/lab05-04-cutover-and-loop.png)

- **`MISMATCH: expected sg-8f6bfa2a32f0f9d39 (usms-alb-sg), found None`.**
  This is Step 17's equality test, run as written. On this build it can only
  print `MISMATCH`, because the source is never stored. It is honest: "only
  the load balancer can reach the tasks" is **not** demonstrable here,
  neither by source group nor by rule count.
- **`LOOP CLOSED`.** `usms-web-01` (`i-f66018e669eb1530a`) still carries
  `usms-app-sg`. As designed, that group no longer opens anything on the
  tasks, and the portal now reaches enrolment through
  `usms-enrolment-alb-219a302e65154d3c.elb.floci`. In 3.6 the portal's
  container really did call the load balancer and get a `200`.
- **The tag audit.** `describe-tags --resource-arns` took **four ARNs in one
  call**: load balancer, target group, listener and rule. Each carries
  `Lab=05`, so Floci stores ELBv2 tags on all four object types.

---

## 4. Exercises 1-5

Full commands, output and the Exercise 4 security review are in
[`exercises.md`](exercises.md).

| # | Deliverable | Result |
|---|---|---|
| 1 | Second path, same load balancer | `usms-results-tg` (ip, HTTP/80, matcher `200-399`, delay 15) and a priority-20 `/results` rule; evaluation order 10, 20, default; `/results` returns **503** (no healthy targets) |
| 2 | Repair `verify-lab-04.sh` | Check rewritten against the property ("sourced from its one upstream group, never a CIDR"), follows `lab-05.env` if present, plus a "no longer admits the retired group" check; 39 checks, `PASS=38 FAIL=1` with and without `lab-05.env`, from any directory |
| 3 | `usms-lb-report.sh` | Full decision table, rules in evaluation order with `default` last; identical from `~` and `labs/lab-05-ecs-alb/`; JSON written; exposed the 4-target orphan state |
| 4 | Exposure review | Two-sentence change; `internal` recommended; exposure delta table; **USD 23.73/month idle, USD 24.26 under load** (cited, derived), more than the two tasks it fronts (USD 21.27); six-object HTTPS plan; Exercise 1 objects deleted in dependency order |
| 5 | `ResourceLabel` for Lab 06 | `app/usms-enrolment-alb/219a302e65154d3c/targetgroup/usms-enrolment-tg/5676809faf504f3d`, derived from the API, validated (6 segments, `app` first, both names), appended to `lab-05.env` (16 exports); readiness file written; replacement time **not measurable** (nothing rolled in 90 s), with what to size against instead |

---

## 5. Review questions

Answered in full in [`../../notes/lab-05-notes.md`](../../notes/lab-05-notes.md).
Summarised:

1. **A security group rule and a load balancer are one idea at two layers:** a
   stable name in front of members that keep changing, kept true by the
   system that creates the members. DNS and service discovery are a third
   solution to the same problem.
2. **"Unhealthy, so the app is broken" is unsound.** The target group check
   can't tell a dead process from a healthy but unreachable one. ECS
   `healthStatus` can. The diagnostic order is `Reason`, then ECS health,
   then the security group, then the path and matcher, then logs.
3. **Configuration versus identity.** Target type, scheme, LB type and VPC are
   identity, changed only by a new object, like a task-definition revision.
   Security groups look like identity and are not (`set-security-groups`).
4. **A request in flight succeeds** within 30 s of deregistration delay, then
   SIGTERM and `stopTimeout`. At the default 300 s, every deployment takes up
   to ten minutes.
5. **Update the script or leave it failing.** On a team, update it in the same
   change. Alone, a short documented red is tolerable.
6. **Internet-facing and private at once:** the nodes are in public subnets
   routed to `usms-igw`, the tasks in private subnets routed only out via
   `usms-nat`, and the load balancer terminates and re-originates the
   connection.
7. **Requests per target beats CPU for a web API:** it measures the load
   itself, ahead of CPU. CPU wins for CPU-bound work whose cost per request
   varies.

---

## 6. Problems encountered

Seventeen issues came up; full write-ups are in [`README.md`](README.md). The
three with the most transferable lessons:

**A command that reports success is still not evidence, even when it
returns `True`.** Floci's `revoke-security-group-ingress` returns
`Return: True` for every form of the call and removes nothing. The cutover
looked done until the rule list was read back. A verification check written
as "the old source is absent" also passed vacuously. Only counting the
rules showed that two paths remain.

**A verification script can fail for the wrong reason, and then it can't see
the right one.** `verify-lab-04.sh`'s source check was already red before
this lab, so the architecture change in Step 13 produced an empty diff. A
check that fails in both designs carries no information about either.
Exercise 2 rewrote it against the property.

**An empty environment produces plausible output.** A terminal without the
Lab 02 and Lab 04 env files created `usms-alb-sg` and `usms-enrolment-tg` in
`vpc-default`. Every ECS call went to an empty cluster name, so Floci
auto-created a `default` cluster. Several commands still printed
plausible-looking results. The broken objects were deleted and the lab
re-run, with a one-line echo of every critical variable before Stage 1.

---

## 7. Floci limitations versus real AWS

| Behaviour | Floci 1.5.34 (observed) | Real AWS |
|---|---|---|
| ELBv2 control plane (LB, TG, listener, rule, attributes, tags) | Implemented and stored, including on four object types for tags | Full |
| Two-AZ requirement | **Enforced** (`InvalidConfigurationRequest`) | Enforced |
| Provisioning | `active` immediately | 2-4 minutes |
| DNS name | `*.elb.floci`; does not resolve from the host | Public, resolves to the node addresses |
| Data path | Listener port bound **inside the Floci container**; reachable from containers on the Docker network | From anywhere the scheme allows |
| Target health checks | **Run**: `initial` -> `healthy` in about 45 s | Run from every node |
| Target addresses | Docker bridge addresses `172.19.x` | ENI addresses in the private subnets |
| Fixed-response rule | **Evaluated**: `/alb-health` returned the rule's body | Evaluated |
| Forward to an empty target group | **503** | 503 |
| `update-service --load-balancers` | Accepted, **not stored** | Stored; triggers a deployment |
| `create-service --load-balancers` | Stored; targets registered automatically | Same |
| `healthCheckGracePeriodSeconds` | Accepted, not stored | Stored and enforced |
| Desired count up/down | Targets registered and deregistered by the service | Same |
| `--force-new-deployment` | Accepted; no task replaced, no `draining` | Rolling replacement with draining |
| Service `deployments` / `events` | `null` / empty | Populated |
| `list-tasks` | Includes stopped tasks | Running only, by default |
| Restart of the emulator | Configuration persists; old task containers survive beside new ones (4 targets for 2/2) | n/a |
| Security group group reference | Accepted, never stored (fifth confirmation) | Stored and enforced |
| `revoke-security-group-ingress` | **Returns `True`, removes nothing** (by ID, pair, CIDR or stored form) | Removes the rule |
| Security group enforcement | None | Every packet |
| Application Auto Scaling | `UnknownOperationException` | Full; Lab 06 |

**Observed versus reasoned about** (Section 12.1, placed for this build; also
in the notes).

*Observed:*
- the `0.0.0.0/0` edge group with nothing behind it admitting the internet
- a two-AZ load balancer, and Floci refusing a one-AZ one
- `LoadBalancerArns` 0 -> 1
- the service registering its own targets, including the scale to 3 and back
- **health checks running**
- **a served request from the portal's container through the load
  balancer to a task**
- **the priority-10 rule firing** ahead of the default action
- a `503` from an empty target group
- persistence with every ARN re-derived

*Reasoned about, not observed:*
- draining during a deployment, and in-flight requests surviving it
- the load-balancing algorithm choosing a target
- the security group chain being stored and enforced
- **the cutover itself**
- target addresses inside the Lab 02 private CIDRs
- the grace period
- public DNS
- HTTPS
- provisioning time
- cost

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
source configs/course.env
./scripts/setup/floci-up.sh
source configs/lab-01.env
source configs/lab-02.env
source configs/lab-03.env
source configs/lab-04.env
source configs/lab-05.env
./scripts/utilities/verify-lab-05.sh
./scripts/utilities/verify-lab-04.sh
```

Expected:
- `verify-lab-05.sh`: `PASS=46  FAIL=4`, the four limitations in 3.9
- `verify-lab-04.sh`: `PASS=38  FAIL=1`, as repaired in Exercise 2

After an emulator restart, compare `describe-target-health` with
`describe-services` before trusting either (3.10).
