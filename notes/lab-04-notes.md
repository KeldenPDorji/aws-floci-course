# Lab 04 - Amazon ECS - my notes

**Support path (Step 3): B - ECS only.** On Floci 1.5.34, ECS, CloudWatch and
CloudWatch Logs answer. Application Auto Scaling returns
`UnknownOperationException` for `describe-scalable-targets`,
`describe-scaling-policies` and `describe-scheduled-actions`. Nothing in
Lab 04 needs it. Lab 06 will, and should take its documented fallback for
this path.

## The sentence Step 7 asks for

The task role and Lab 3's instance profile are two different mechanisms for
delivering the same thing: temporary credentials to code that never sees a
key. Both carry `USMSStudentDataReadWrite`, byte-identical (`diff` printed
nothing), and both start working at the moment a bucket appears at
`arn:aws:s3:::usms-student-data`, with neither one changed.

## Understanding checks (Section 14)

**The four objects, and which one scaling changes.** A cluster is a
namespace, a task definition is an immutable versioned blueprint, a task is
one running copy of it, and a service is the controller that keeps
`runningCount` equal to `desiredCount`. Scaling changes one integer on the
service, `desiredCount`, and nothing else.

**Which symptom points at which role.** "The task never starts" (an image
pull or log-driver error in `stoppedReason`) points at the execution role.
"It started fine, then the code got AccessDenied" points at the task role.

**Why the rule names a group.** Because the requirement is "callers that
*are* the web tier", not "callers that happen to hold these addresses". The
group stays true as the web tier is rebuilt or re-addressed, and a CIDR does
not.

**What Fargate removed from Lab 3's model, and what it did not.** It removed
the instances: no AMI, no patching, no capacity to plan, no SSH key. It did
not remove the network: every task still has its own ENI, security group and
route table.

---

# Review Questions

### 1. "I put auto scaling on the task definition"

Every part of that sentence is wrong. Auto scaling in Lab 06 is attached to
the **service**: the scalable target is
`service/usms-ecs-cluster/usms-enrolment-svc` in the `ecs` namespace, with
dimension `ecs:service:DesiredCount`, not the task definition, which is an
immutable blueprint with no notion of "how many". What it modifies is a single
integer, the service's `desiredCount`. It starts no tasks and talks to no
containers. The object that does the work of making reality match is the
**service**, whose controller starts or stops tasks until `runningCount`
catches up. This lab watched that lag directly: desired moved to 3 instantly,
and running followed on Floci's next reconcile cycle.

The observable consequence of ECS knowing nothing about the scalable target
is that the two can fight. If someone runs `update-service --desired-count 5`
by hand while a scaling policy is active, ECS accepts it without complaint.
At the next evaluation Application Auto Scaling writes its own number back
over it. If the scalable target's min/max range excludes 5, the hand-set
value is silently clamped. The manual change "works" and then quietly
disappears, and nothing on the service says why. You have to look at
`describe-scaling-activities` to find the cause.

### 2. One policy, two delivery mechanisms

`USMSStudentDataReadWrite` was written in Lab 1 for a bucket that did not
exist. In Lab 3 it reached an EC2 instance through an **instance profile**.
At runtime, the EC2 service assumes `usms-ec2-app-role` on the instance's
behalf and serves the resulting temporary credentials from the Instance
Metadata Service at `169.254.169.254`. The SDK finds them there with no
configuration, and AWS rotates them several times a day.

In this lab the same policy, unchanged, reached a Fargate task through a
**task role**. When the task starts, ECS assumes `usms-ecs-task-role` (named
in the task definition's `taskRoleArn`) and exposes the credentials on a
task-scoped endpoint. It injects that endpoint's path into the container as
`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, and every SDK checks that variable
before anything else. The credentials are again short-lived and rotated by
AWS.

Neither mechanism needs a key on disk, because in both the credential is
*fetched at runtime from the platform* rather than stored with the code. It
exists only in memory, it expires on its own, and nothing about it can leak
through a repository, an image layer or a screenshot. (Floci shows the
contrast: it injects static `AWS_ACCESS_KEY_ID=test` /
`AWS_SECRET_ACCESS_KEY=test` into its task containers as environment
variables. That is precisely the stored-key pattern both real mechanisms
exist to eliminate.)

The moment a bucket finally exists at `arn:aws:s3:::usms-student-data`, the
following become possible for **both** the instance and the task at once,
with no change to IAM, to the instance or to the task definition:
`s3:ListBucket` and `s3:GetBucketLocation` on the bucket, and
`s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on its objects. Both
remain unable to `DeleteBucket` (explicit deny). Until then, both get "no such
bucket", not "access denied", because the permission was always in place;
only its object was missing. Lab 3's `head-bucket` 404 is the evidence. One
policy, written once, now governs two kinds of compute through two delivery
paths. Changing what *both* may do is a single `create-policy-version`. This
is why identity was designed in Lab 1 before any compute existed.

### 3. Execution role versus task role

**Execution role:** if it is missing or wrong, *the task never reaches
RUNNING*, and `stoppedReason` talks about pulling the image or creating the
log stream. **Task role:** if it is missing or wrong, *the task runs normally,
and the application later gets AccessDenied (or "unable to locate
credentials") when it calls S3*.

They share an identical trust policy because trust answers only one question:
*who is allowed to assume this role?* For both, the answer is the same
service principal, `ecs-tasks.amazonaws.com`. Their different jobs come
entirely from their different *permission* policies (ECR pull and log writes
versus S3 access) and from where the task definition references them
(`executionRoleArn` versus `taskRoleArn`). The trust document determines who
may use a role, and the attached policy determines what it may do. Two roles
can agree on the first and differ completely on the second.

### 4. Group, not CIDR - at a fixed count, and once it moves

**At a fixed task count**, the group reference is still the correct
expression of the requirement. "Only the student portal may call the
enrolment API" is a statement about *what the caller is*, not *where it
sits*. A CIDR such as `10.0.1.0/24` admits anything in the web tier's subnet,
including a NAT gateway, a bastion, or a future unrelated instance placed
there. It also silently stops admitting the real web tier the day the portal
moves to `usms-public-subnet-b`, which Lab 3's `usms-web-02` already did.
The group reference follows the web tier wherever its instances are, and
admits nothing else.

**Once Lab 06 lets the count change**, it becomes close to mandatory. Scaling
creates and destroys network interfaces continuously, with addresses drawn
from two subnets. A CIDR rule that names specific callers would have to be
rewritten on every scaling event. One that names whole subnets becomes so
broad it stops meaning anything. A group reference needs no maintenance at
all: every new task or instance carrying the group is admitted the moment it
exists, and every terminated one stops being admitted the moment it is gone.

(On this Floci build the reference was written correctly and not stored: the
rule reads `tcp 80 None None`. That limitation makes it *more* important to
keep the document, `policies/usms-enrolment-sg-ingress.json`, as the record of
intent.)

### 5. What Fargate removes, and what it does not

**Fargate removes the machines.** In Lab 3, running the web tier meant
choosing an AMI and keeping it patched, sizing an instance type, managing a
key pair, attaching volumes, and owning the fact that the instance would stay
the size it was launched at. With Fargate you state CPU and memory per task
(`256` / `512`), and AWS finds the capacity, patches the host, and bills per
task-second. There is no instance to SSH into and no fleet to scale beneath
the tasks. That second layer of scaling is exactly what the ECS `EC2` launch
type still needs (Section 12.3).

**Fargate does not remove the network.** A task in `awsvpc` mode gets its
own elastic network interface in *your* subnet, and it obeys exactly the
rules Lab 3's instances did:
- It carries its own security group, `usms-enrolment-sg`, and that group, not
  anything about Fargate, is what decides who can call it.
- It obeys Lab 2's route tables. The enrolment tasks sit in
  `usms-private-subnet-a` and `-b`, whose `usms-private-rt` sends `0.0.0.0/0`
  to `usms-nat`. That route is the only way the task can reach
  `public.ecr.aws` to pull its image. Break it, and the service still creates
  but every task fails on an image-pull timeout.
- `assignPublicIp=DISABLED` is the same decision as Lab 3's
  `MapPublicIpOnLaunch=False`, made per service instead of per subnet.

Fargate takes away the *server*. It leaves the *VPC* exactly where Lab 2 put
it.

### 6. Applying Lab 1's scepticism to this lab

**Looks identical in `memory` and `hybrid` mode:**

```bash
aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].[status,desiredCount,runningCount]' --output text
```

Run it right after creating the service, in the same Floci process lifetime,
and it returns `ACTIVE 2 2` in either mode. The service is held in memory in
both. So does `docker ps` showing the two nginx task containers. Those
containers belong to Docker, not to Floci, and they keep running whatever
Floci remembers. Neither proves anything about persistence. Both describe the
*current process*, just as Lab 1's root ARN was a constant of the emulator
rather than evidence of stored state.

**Does not look identical:** the same `describe-services`, looked up **by
name**, after `./scripts/setup/floci-down.sh` and `./scripts/setup/floci-up.sh`.
In `hybrid` mode the service record was flushed to `~/floci-data` and reloads,
so it returns `ACTIVE 2 ...`. In `memory` mode the restarted emulator has no
such service and returns `ServiceNotFoundException` (or `ClusterNotFound`).
The difference is that the second command forces a read from state that had
to survive a process boundary. It must also look the service up by name, not
from a variable such as `$SERVICE_ARN`, which would only prove the shell
remembered a string.

The `docker ps` case deserves the extra sentence, because it is the trap
specific to this build. In `memory` mode a restart would leave the task
containers running with no service record behind them: orphans that look
like a healthy deployment, managed by nothing.
