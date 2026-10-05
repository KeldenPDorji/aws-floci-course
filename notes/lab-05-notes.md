# Lab 05 - ECS behind an Application Load Balancer - my notes

**Support path (Step 3): B - control plane, plus a data path inside Docker.**
On Floci 1.5.34 every ELBv2 call this lab uses answers and stores what it is
given: load balancer, target group, attributes, listener, rule and tags. The
build is not quite path A, because the load balancer's DNS name
(`*.elb.floci`) does not resolve from the host and no port besides 4566 is
published. It is better than plain path B, though. Floci runs an ELBv2 data
plane that binds each listener port *inside* its own container. Health
checks really run, so targets went `initial` -> `healthy`. Requests from the
`floci` container and from `usms-web-01`'s container got real `200`s from
nginx in the enrolment tasks (`outputs/lab-05-path-proof.txt`).

Application Auto Scaling is still `not available`, exactly as in Lab 04.

## Step 4 "Your turn" - port 443 is open and nothing serves HTTPS

`usms-alb-sg` has two inbound rules: 80 and 443, both from `0.0.0.0/0`
(`policies/usms-alb-sg-ingress-https.json`). The load balancer still serves
no HTTPS request, because a security group rule only opens the firewall. It
takes two more things:
- **an HTTPS listener on 443**, which you create
- **a TLS certificate** for that listener

AWS gives you the certificate for free: an ACM public certificate costs
nothing. What you must obtain from outside is a **domain name you control**.
ACM will only issue a certificate after you prove control of the name, by
publishing a DNS validation record in that domain's zone.

## Step 6 "Your turn" - the matcher

`modify-target-group --matcher HttpCode=200-399` returned `200-399`, and
setting it back returned `200`. Neither change recreated anything
(`outputs/lab-05-matcher-your-turn.txt`).

(a) An application that redirects `/` to `/login`, such as any portal behind
a sign-in page, answers the health check with a `302`. A strict `200`
matcher then calls it unhealthy forever, while it works perfectly for every
real user.

(b) It would be a bug in my work, not in the script. A verification script
is the written statement of what the architecture is supposed to be. The lab
specified matcher `200`, so a `200-399` target group does not match the
specification, even if it would serve traffic. If the *specification*
changes, the right move is to change the script in the same commit, as in
Exercise 2.

`modify-target-group help` lists only health-check fields. Protocol, port,
VPC and target type are absent, so those four were permanent decisions at
creation.

## Step 11 - the two health opinions, side by side

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| `HEALTHY` | `healthy` | Working |
| `HEALTHY` | `unhealthy` | **The network path is broken**: security group, subnet, or the health check path returning the wrong code |
| `UNHEALTHY` | `unhealthy` | The application is broken. Read the container logs |
| `UNKNOWN` | `healthy` | Not a fault. The task definition has no container health check |
| anything | `unused` | Nothing forwards to this target group |

What I observed (screenshot 01) was the fourth row, shown as `None`. Floci
reports no `healthStatus` at all for the tasks, while both targets are
`healthy`.

## Step 11 "Your turn" - desired 3 and back

Desired 3 gave three `healthy` targets after 45 s. Desired 2 gave two
targets again 5 s later. I never ran `register-targets` or
`deregister-targets` (`outputs/lab-05-desired-3-and-back.txt`).

Without service-managed registration, after every scaling event I would have
had to **run `register-targets`/`deregister-targets` with the new or departed
task's private address**. That would leave a window in which a new task
receives no traffic, or a dead one still does.

## Section 12.1 for this build

*Observed:*
- the `0.0.0.0/0` load-balancer group, with nothing behind it admitting the internet
- a load balancer across two AZs, and Floci *refusing* a one-AZ load balancer
- the target group's `LoadBalancerArns` going 0 -> 1
- the service registering its own targets, including the scale to 3 and back
- **health checks running**: `initial` -> `healthy`. This moves from the guide's conceptual list to observed
- **a request travelling** from `usms-web-01` through the listener to a task, and back as a `200`, from inside the Docker network
- **the priority-10 rule firing** ahead of the default action (`/alb-health` -> `usms-enrolment-alb ok`), and a `503` for a rule whose target group is empty
- persistence across a restart, with every ARN re-derived

*Reasoned about, not observed:*
- a target draining, because a forced deployment replaced nothing
- in-flight requests surviving deregistration
- `least_outstanding_requests` choosing a target
- the security group chain being *enforced*. Floci stores no group references and enforces nothing
- the cutover itself, because revoke is a no-op on this build
- target addresses inside `10.0.3.0/24` / `10.0.4.0/24`. Floci uses `172.19.x`
- the grace period, which was not stored
- public DNS
- HTTPS
- 2-4 minute provisioning
- cost

---

# Review Questions

### 1. A security group rule and a load balancer solve the same problem

Lab 04's rule named `usms-app-sg` instead of an address, and this lab put a
load balancer in front of the tasks. Both answer the same problem. **A
client needs a stable way to refer to something whose concrete identity
keeps changing.** Fargate tasks are created and destroyed by a controller.
Each one gets a fresh ENI and a fresh address, so any reference written
against an address goes stale.

Both solutions introduce a *stable name* and hand the job of mapping that
name to the current members to the system that already knows when members
change:
- For the security group, the name is the group, and membership follows
  every ENI that carries it.
- For the load balancer, the name is a DNS name and a target group, and the
  ECS service, which starts and stops the tasks, keeps the target list true.

Neither makes the tasks any more permanent. They put something permanent in
front of them, with an owner who keeps it accurate. DNS itself is a third
solution to exactly this problem, mapping a stable host name onto addresses
that change. So is service discovery (Cloud Map, Consul), where instances
register themselves under a service name.

### 2. "The health check says unhealthy, so the app is broken" is unsound

The target group health check is a request sent **from the load balancer,
across the network**. It fails just as readily when the application is fine
and the path is not. It cannot tell these two states apart:
1. the process is down or returning errors
2. the process is healthy but unreachable, because a security group doesn't
   admit the load balancer, the port is wrong, or the path returns a code the
   matcher rejects

The field that does tell them apart is the task's ECS `healthStatus`,
reported by the container health check that runs *inside* the task. In the
`HEALTHY` + `unhealthy` combination, the application is alive, so the fault
is the path.

The diagnostic sequence I would follow:
1. Read `describe-target-health` `Reason`. `Target.Timeout` points at the
   network, `Target.FailedHealthChecks` at the application or matcher.
2. Compare it with `describe-tasks` `healthStatus` for the same address.
3. If ECS says `HEALTHY`, check that `usms-enrolment-sg` admits `usms-alb-sg`
   on the target port.
4. Check that the health check path really returns a code the matcher
   accepts.
5. Only then read the container logs.

### 3. Configuration versus identity

There is no `update-target-group-target-type`, because the target type is
part of what the target group *is*, not a setting on it. An `ip` target
group and an `instance` target group register different kinds of thing,
validate differently, and integrate with ECS differently. Changing the type
would silently invalidate every registration in it. So AWS makes it identity:
fixed at creation, and changed only by creating a new object with a new ARN.
That is the same idea as Lab 04's immutable task-definition revisions. What
a running thing *is* never changes underneath it. You make a new one and
move the pointer.

Two more fields in this lab behave the same way:
- the load balancer's **`Scheme`** (`internet-facing` vs `internal`)
- its **`Type`** (`application`)

Both can only be changed by recreating the load balancer. The target group's
`VpcId` is another.

One field that looks as if it should be permanent and is not: the load
balancer's **security groups**. They are fundamental to what can reach it,
yet `set-security-groups` changes them in place. Health-check settings and
the matcher, as Step 6's "Your turn" showed, are also plain configuration.

### 4. A request in flight when its task is stopped

The request arrives on the listener and is forwarded to task T. ECS then
decides to stop T, whether for a deployment, a scale-in or a failed check.

1. **ECS deregisters T.** The load balancer marks it `draining`: it sends T
   no *new* requests, and lets the in-flight one continue.
2. **The load balancer waits.** It waits up to
   `deregistration_delay.timeout_seconds`, set on the target group to **30**
   in this lab, or until T's connections close.
3. **ECS sends SIGTERM** to the container.
4. **ECS waits `stopTimeout`**, set in the task definition.
5. **ECS sends SIGKILL.**

The third timer, `minimumHealthyPercent` on the service, decides whether a
replacement is already serving before T leaves. At 100, it is.

The request **succeeds**, provided it finishes within 30 s. That is
comfortably true for an API whose requests take milliseconds. If the delay
were left at the default **300**, the request would still succeed. But every
task would sit `draining` for up to five minutes, and since tasks are
replaced one at a time, a two-task deployment would take up to ten minutes.
Draining time should be slightly longer than the slowest legitimate request,
and no longer.

### 5. Update the script now, or leave it failing?

**For updating it immediately:** a verification script is the definition of
"correct". If it is red after an intended change, every later run trains
people to ignore red. A real regression, say `usms-enrolment-sg` suddenly
admitting a CIDR, would then hide behind a failure "we already know about".
The change and its updated assertion belong in the same commit.

**For leaving it failing and documented:** `verify-lab-04.sh` is the record
of what Lab 04 built. Rewriting it to go green erases the evidence that the
architecture changed and *when*. The visible failure is also an honest prompt
that someone must decide what the new property is.

On a system with four other engineers, I would update it in the same change.
They can't read my mind, and a known-red check is noise to everyone else. On
a one-person system, leaving a documented failure for a short while costs
little, because the only person who must remember why is me. I would still
fix it before the next unrelated change. Exercise 2 did the update, written
against the *property* ("sourced from its one upstream group, never a
CIDR"), so the check survives this change and the next one.

### 6. An internet-facing load balancer in front of private tasks

Both are true because the two halves live in different subnets with
different routes:
- **The load balancer's nodes** sit in `usms-public-subnet-a` and `-b`.
  Their route table, `usms-public-rt`, sends `0.0.0.0/0` to `usms-igw`, so
  the nodes have public addresses and are reachable from the internet.
- **The tasks** sit in `usms-private-subnet-a` and `-b` with
  `assignPublicIp DISABLED`. Their route table, `usms-private-rt`, sends
  `0.0.0.0/0` only *outbound*, to `usms-nat`. Nothing on the internet can
  open a connection to them.

The load balancer terminates the client's connection and opens a new one,
from its own private address, inside `usms-vpc`. That second connection is
what `usms-enrolment-sg` admits, sourced from `usms-alb-sg`.

An attacker who compromised the load balancer's configuration could:
- point listeners or rules anywhere the load balancer can reach, which means
  any IP target in the VPC or a peered range, on any port that target's
  security group admits to `usms-alb-sg`
- read and alter the HTTP traffic passing through it

They still could not:
- open a shell on a task
- reach `usms-db-01`, because `usms-db-sg` doesn't admit `usms-alb-sg`
- use the task role's credentials

Had the tasks been given public addresses in public subnets, the load
balancer would no longer be the only path. Any internet client would have
been one security group rule mistake away from talking to a task directly,
and the "only the load balancer can reach the tasks" property would rest on
a firewall rule alone instead of on routing *and* the firewall.

### 7. Requests per target versus CPU

For a web API, request rate is the **load itself**. CPU is a side effect of
it that lags behind. `ALBRequestCountPerTarget` rises the moment the 08:00
enrolment wave arrives, before any task's CPU has climbed. It is also stable
across task sizes: "each task handles 25 requests a second" survives a
change in instance type better than a CPU percentage. And it accounts for
time spent waiting on the database, which CPU doesn't see at all.

CPU is the better signal for **CPU-bound work whose cost per request
varies**. Think of a report or PDF generator, where ten requests can be
trivial or can pin every core.

`ALBRequestCountPerTarget` would scale the enrolment service badly if its
requests were wildly uneven in cost, so a count says nothing about load.
For example, if a few requests triggered long transcript exports while most
were tiny reads. It would also scale badly if the bottleneck were somewhere
else entirely, such as `usms-db-01`. Adding tasks would then add requests
per second to a database that is already saturated, and make things worse.
