# Lab 01 - IAM - my notes

---

## Step 7 - why is `--persist` almost empty in memory mode?

`--persist` and `FLOCI_STORAGE_MODE` are two different mechanisms, and only the
second one decides whether anything durable gets written. `--persist` mounts a
host directory at `/app/data`, so the mount genuinely exists and the directory
genuinely appears - but in `memory` mode Floci keeps its state in RAM and treats
that state as disposable, so it writes almost nothing into the mount and deletes
the Docker volumes it created when it tears down.

The directory is therefore not evidence of anything. A correct mount with the
wrong storage mode produces exactly the symptom students report: a folder that
exists, is nearly empty, and loses everything on restart, while a new volume
appears on each start. Confirmed in Step 14 - with `hybrid` set,
`~/floci-data` reached 320K and held real `*.json` files, and
`persistence-check` survived a full `docker compose restart`.

---

## Attached vs inline policies (checklist item)

| | Managed (attached) | Inline |
|---|---|---|
| Has an ARN | Yes | No |
| Reusable on other identities | Yes | No - embedded in exactly one |
| Versioning / rollback | Yes, up to 5 versions | No |
| Lifetime | Independent of the identity | Deleted with the identity |
| Listed by | `list-attached-user-policies` | `list-user-policies` |

The listing difference is the practical trap and I saw it directly:
`list-attached-user-policies` on `usms-dev-01` returns an **empty list**, while
`list-user-policies` returns `USMSSelfManageCredentials`.

![Inline vs attached listings on usms-dev-01, with aws:username unexpanded and v2 set default](../screenshots/09-inline-and-versions.png)

An auditor who runs only the first command
concludes the user has no direct permissions, which is false. A complete audit
of a user requires four lookups - group policies, attached user policies, inline
user policies, and (in real AWS) permission boundaries and SCPs.

I used inline here deliberately: `USMSSelfManageCredentials` is scoped to
`${aws:username}`, so it is meaningful for exactly one identity and must never be
accidentally reused. The policy variable is substituted at evaluation time, which
is why the same document would say "your own user" for every caller - and why in
production it would more sensibly be attached to a group.

---

## Access key rotation - the five-step procedure (checklist item)

1. **Create a second access key.** A user may hold two simultaneously, and this
   limit exists precisely to make zero-downtime rotation possible. At this point
   both keys are `Active` and either works.
2. **Deploy the new key everywhere it is used.** Config files, CI/CD secrets,
   SDK profiles, container environments. This is the step that reveals how many
   copies actually exist - usually more than anyone expected.
3. **Set the old key to `Inactive`,** do not delete it:
   `aws iam update-access-key --user-name X --access-key-id AKIA... --status Inactive`
   `Inactive` is reversible; deletion is not.
4. **Wait and watch for breakage.** Anything still holding the old key now fails
   visibly. If something breaks, flip the old key back to `Active` instantly and
   the outage ends - this is the entire reason step 3 does not delete.
5. **Only then delete the old key** with `delete-access-key`, once a full
   business cycle has passed with nothing failing.

The ordering is the whole point: every step before the irreversible one is
reversible, and the irreversible one happens only after evidence that it is
safe. Deleting first and creating second inverts that and guarantees an outage.

Worth noting this procedure is only necessary because a long-lived key exists at
all. `usms-ec2-app-role` never needs it - role credentials rotate themselves.

---

## Step 32 - prediction for `usms-audit-01`, written before running

`usms-audit-01` is in `usms-auditors`, which has `ReadOnlyAccess` attached and
nothing else.

- **`ec2:CreateVpc` → implicit deny.** `ReadOnlyAccess` grants no write actions,
  and no policy anywhere mentions `ec2:CreateVpc` for this user. Nothing allows
  it, so the default deny applies. Note this is *implicit*: there is no `Deny`
  statement naming it. `USMSDeveloperBase`'s `DenyDangerousIdentityChanges`
  covers IAM actions and billing, not EC2.
- **`ec2:DescribeVpcs` → allowed.** `ReadOnlyAccess` covers `ec2:Describe*`.

The distinction matters for the fix: the first would be resolved by adding an
`Allow`, the second needs nothing. If `CreateVpc` had been an *explicit* deny,
adding an `Allow` would not have helped at all.

**What actually happened, and the more interesting result.** Running the
simulator against `usms-dev-01` returned `implicitDeny` for `ec2:CreateVpc`,
which contradicts the lab's stated expected output of `allowed`. Investigating
rather than assuming an emulator bug showed the simulator is right and the lab is
simplified: `BuildNetworkingForLab02` allows the action only under
`StringEquals: {"aws:RequestedRegion": "us-east-1"}`. With no request context
supplied, the condition cannot evaluate true, the statement does not match, and
the default deny applies. Re-running with
`--context-entries ContextKeyName=aws:RequestedRegion,ContextKeyValues=us-east-1,ContextKeyType=string`
returned `allowed`; `eu-west-1` returned `implicitDeny` again.

![Policy simulator: three decision types, then the same action allowed once the region context is supplied and denied again with the wrong region](../screenshots/12b-simulator.png)

The lesson is bigger than the exercise: a conditional `Allow` is not an `Allow`
until the condition's context key is present. A permission that "works in the
console" can fail from a differently-shaped API call that omits the key.

---

## Exercise 4 - user, group, or role? And how it could still be abused

### The decision: a role

A **role**, assumed by the compute that runs the nightly job - not a user and not
a group.

A user would require a long-lived access key sitting on disk on whatever machine
runs the backup, which is precisely the risk Step 28 exists to teach: that key
survives machine images, backups and snapshots, it does not rotate itself, and
it is the single most common way credentials leak. A group is not even a
candidate - groups cannot be authenticated as; they are containers for users and
carry no credentials of their own. A role gives the job short-lived credentials
delivered at runtime, rotated automatically, with every assumption logged and
attributable. The workload is unattended and machine-driven, which is the exact
case roles were designed for. I trusted `lambda.amazonaws.com` because a nightly
scheduled job is a natural fit for a scheduled Lambda; EC2 or ECS would work
identically by changing only the trust principal to `ec2.amazonaws.com` (plus an
instance profile) or `ecs-tasks.amazonaws.com`.

### The action list, and why `s3:CopyObject` is not on it

There is no such IAM action. An S3 server-side copy is authorised as
`s3:GetObject` on the **source** object ARN and `s3:PutObject` on the
**destination** object ARN - two permissions on two different resources.
Assuming a single "copy" permission exists is a common way to write a policy
that fails at runtime. "Verify what it copied" needs `s3:ListBucket` on **both
bucket** ARNs (not the object ARNs - you cannot list an object), plus
`s3:GetObjectAttributes` to compare size/checksum. The completion log needs
`logs:CreateLogGroup`, `logs:CreateLogStream` and `logs:PutLogEvents`.

Deletion is blocked by **implicit** deny: no statement grants any `Delete`
action, so the default deny stands. I deliberately did not add an explicit
`Deny` - it would be redundant here, and reserving explicit denies for genuine
guardrails (like `DenyDangerousIdentityChanges`) keeps their signal strong.

Four statements, every one carrying
`StringEquals: {"aws:RequestedRegion": "us-east-1"}`, no `Action: "*"` and no
`Resource: "*"` on any `Allow`.

### Three ways this policy could still be abused

1. **`s3:PutObject` on `usms-archive/*` allows overwriting existing archives.**
   The policy does not distinguish "write a new object" from "replace last
   night's backup with garbage", so a compromised job could silently destroy
   history without ever calling a `Delete` action - defeating the point of a
   backup. *Close it:* enable S3 Object Lock in compliance mode, or versioning
   plus a bucket policy denying `s3:PutObject` on keys that already exist; at
   minimum, write to a date-prefixed key (`/2026-08-15/…`) and add a condition
   restricting the prefix.

2. **`s3:GetObject` on `usms-student-data/*` is total read access to every
   student record.** The brief says "copy every object", so the breadth is
   legitimate, but the credential is now a complete exfiltration path for the
   entire transcript store - it can read to anywhere the network allows, not
   only to the archive bucket. *Close it:* add an `aws:SourceVpce` condition so
   the role only works from the VPC endpoint, restrict egress at the network
   level, and enable S3 access logging with alerting on read volume far above
   the nightly baseline.

3. **The region condition constrains the caller, not the destination.** Nothing
   stops `usms-archive` from being a bucket in another account. If an attacker
   who can modify the job's configuration repoints the destination - or if
   someone creates a same-named bucket in an account they control - data leaves
   the organisation while every API call still satisfies `us-east-1`. *Close it:*
   add `StringEquals: {"aws:ResourceAccount": "000000000000"}` to the `PutObject`
   statement so the destination must belong to this account, and enforce the same
   at the organisation level with an SCP.

---

## Exercise 3 - should this role use `sts:ExternalId`?

Yes, in any real deployment. The partner is a third party running a service on
behalf of many customers, which is exactly the **confused deputy** problem
`ExternalId` exists to solve: without it, anyone else who is also a customer of
that partner could ask the partner to assume *our* role, and the partner -
holding a legitimate credential and following instructions - would comply. The
`ExternalId` is a secret the partner agrees with us and passes on every
`AssumeRole` call, proving the request originates from our engagement
specifically. It is not a password and does not need to be secret from us; it
needs to be unguessable by the partner's *other* customers.

It is omitted from what I built only because the exercise's four stated
requirements do not include it and there is no partner-supplied value to use.

Related finding: the exercise asks for `--max-session-duration 1800`, which AWS
rejects - the valid range is 3600-43200. I enforced the 30-minute cap with a
`NumericLessThanEquals` condition on `sts:DurationSeconds` in the trust policy
instead, which is a stronger control because it *denies* an oversized request
rather than silently truncating it. Full write-up in
`labs/lab-01-iam/README.md`, problem 7.

---

# Review Questions

### 1. Trust vs permissions

What is missing is the **trust policy** - or rather, the trust policy does not
name the principal trying to use the role. A permissions policy answers "what may
this role do once someone is it?"; a trust policy answers "who is allowed to
become it?". A role with perfect permissions and no matching trust entry is
simply unassumable, so nobody can exercise those permissions.

IAM separates the two documents because they answer questions owned by different
people and changing at different rates. The permissions policy is written by
whoever understands the workload; the trust policy is a boundary decision about
who may cross into that workload, often owned by security. Keeping them separate
means widening what a role can do never accidentally widens who can assume it,
and vice versa. It also enables cross-account access, which cannot be expressed
at all in a permissions policy: the trust policy is the only place a principal
from another account can be named.

In practice the failure has two halves, and I hit both sides of the handshake in
Step 30: the role's trust policy must name `usms-dev-01`, **and**
`usms-dev-01` must hold `sts:AssumeRole` permission on that role ARN
(`USMSAssumeAppRoles`). Either one missing produces an identical `AccessDenied`.

### 2. Explicit vs implicit deny

Both surface to the user as `AccessDenied`, but they differ in how the evaluation
engine reached that answer.

- `iam:CreateUser` is an **explicit deny**. `USMSDeveloperBase`'s
  `DenyDangerousIdentityChanges` statement names it directly. Explicit deny wins
  over every `Allow`, everywhere, unconditionally - it cannot be overridden.
- `dynamodb:PutItem` is an **implicit deny**. No statement anywhere mentions
  DynamoDB, so no `Allow` matches and the default deny applies.

**Telling them apart:** `simulate-principal-policy` returns `explicitDeny` versus
`implicitDeny` as distinct values, and I saw both in the simulator output shown
earlier in these notes. Without the simulator, read every policy in
scope for the principal (group, attached, inline, boundary, SCP) and search for
the action in `Deny` statements; if it appears in none, the denial is implicit.

**Why the fixes differ:** implicit deny is fixed by *adding* an `Allow` -
straightforward. Explicit deny cannot be fixed by adding `Allow` at all; adding
one is wasted effort and a classic time sink. You must locate the `Deny`
statement and decide whether to narrow it, scope it with a condition, or
(usually) accept that the block is intentional and the request should not be
made. That is exactly what `DenyDangerousIdentityChanges` is for: it holds even
if someone later attaches `AdministratorAccess` to the group by mistake.

### 3. Roles over keys

**Reason 1 - nothing secret is ever stored on the machine.** An access key in a
config file is a permanent credential at rest. It is captured by every disk
image, AMI, snapshot, container layer and backup of that server; it survives the
server itself; and it is readable by anyone who gains file access or a path
traversal. With `usms-ec2-app-role` attached via the instance profile, the
instance retrieves short-lived credentials from the instance metadata service at
runtime. There is no file to steal, and credentials obtained from a compromised
instance expire on their own within hours.

**Reason 2 - automatic rotation and precise blast radius.** Role credentials
rotate continuously with no deployment or downtime, whereas rotating a static key
means the five-step procedure in Step 31 across every place it was copied - and
in practice keys stay in place for years because rotating them is risky. The
scopes also differ: `usms-dev-01` is a human developer whose permissions are
broad by role and will grow over time, so putting *that* key in the application
grants the app every developer permission, now and in future. The role carries
only `USMSStudentDataReadWrite`. Additionally, every assumption is logged with
the session identity, so CloudTrail attributes actions to that instance rather
than to a person who was not involved.

### 4. The S3 ARN trap

`arn:aws:s3:::usms-student-data` names the **bucket**, and
`arn:aws:s3:::usms-student-data/*` names the **objects inside it**. They are
different resources, and each action applies to only one of them.

Downloads fail because `s3:GetObject` acts on an *object*, and the policy grants
it only on the bucket ARN - a resource `GetObject` is never evaluated against, so
no statement matches and the implicit deny applies. Symmetrically,
`s3:ListBucket` acts on the *bucket*; granting it on `…/*` is a no-op, because
you cannot list an object.

Corrected, this needs two statements:

    s3:ListBucket, s3:GetBucketLocation  →  arn:aws:s3:::usms-student-data
    s3:GetObject                         →  arn:aws:s3:::usms-student-data/*

This is why `USMSStudentDataReadWrite` has separate `ListTheBucketItself` and
`ReadWriteObjectsInsideTheBucket` statements rather than one combined statement.

### 5. The Floci illusion

Every command succeeding proves the requests were **syntactically valid and
accepted**, not that the policies are **correct**. Floci does not authorise
requests against IAM policies by default - it reports every caller as the account
root user, and `sts:AssumeRole` succeeds even with the trust policy removed. So
the lab exercised the IAM *control plane* (creating and reading policy objects)
and never once exercised policy *enforcement*. A policy with a typo'd action, a
wrong resource ARN, or an unsatisfiable condition would have been created and
listed exactly as happily. The Step 30 note says this outright, and I saw a
related symptom: an assumed-role identity reported the session name as
`floci-session` rather than the one I supplied.

**Two techniques to gain real confidence before deploying:**

1. **Simulate with explicit request context.** `simulate-principal-policy` runs
   the real evaluation engine without performing the action, and returns
   `allowed` / `explicitDeny` / `implicitDeny`. Crucially, supply
   `--context-entries` for every condition key the policy depends on and test
   both the satisfying and the violating value - that is exactly how I proved
   the `aws:RequestedRegion` condition on `BuildNetworkingForLab02` was live
   rather than assuming an emulator bug. Test the negative cases, not just the
   happy path: a policy that allows what it should is only half-verified until
   you confirm it denies what it should.

2. **Deploy to a real throwaway AWS account and attempt the actions as the
   principal.** Assume the role for real, run both the operations that must
   succeed and the ones that must fail, and read CloudTrail to confirm the
   decision and the `errorCode`. This is the only way to catch enforcement-level
   behaviour an emulator does not model - permission boundaries, SCPs, resource
   policies, and service-specific authorisation quirks. Pair it with IAM Access
   Analyzer's policy validation and, for changes, `--dry-run` where the service
   supports it.

### 6. The persistence trap

Three independent causes, any one of which produces the same symptom:

1. **`--persist` does not set a storage mode.** It mounts a directory; it does
   not change `FLOCI_STORAGE_MODE`, whose default is `memory`. In memory mode
   Floci keeps state in RAM, writes almost nothing durable into the mount, and
   deletes its own volumes on teardown because it correctly regards that state
   as disposable.
2. **Sidecar services use a different variable entirely.** RDS, OpenSearch, MSK,
   ECR, ElastiCache, Lambda and ECS run as child containers whose data does not
   travel through `--persist` at all. They need
   `FLOCI_STORAGE_HOST_PERSISTENT_PATH`, which must be an **absolute** path -
   Floci rejects relative ones, and neither Docker nor Floci expands `~`, so a
   literal `~/floci-data` in a config file creates a directory actually named `~`.
3. **CLI flags are not remembered.** `floci start` stores nothing about the
   previous run. A plain `floci start`, a `floci restart`, a Docker Desktop
   restart, or `floci stop --remove` all bring the container back on defaults -
   memory mode, no bind mount - and nothing warns you. Overnight, a Docker
   Desktop update is enough.

**The one-minute test that catches all three:** create a marker resource,
restart the container fully, and look for it again.

    aws iam create-user --user-name persistence-check
    docker compose restart floci
    aws iam get-user --user-name persistence-check

If the user comes back, persistence is real. The critical point is that the test
must **create something**. Restarting and observing that
`get-caller-identity` still returns the same root ARN proves nothing at all - the
root identity is a constant that returns identically in memory mode with no disk
whatsoever. That is precisely the false-positive that convinced the classmate.

### 7. Configuration as evidence

Committing `docker-compose.yml` converts the environment from a private,
unverifiable sequence of typed commands into a reviewable artefact - and that
change is what makes both security and reproducibility possible rather than
merely convenient.

A typed command is invisible after the fact. It exists only in one person's
scrollback and shell history, and nobody can audit, diff, or review it. When
the environment is a committed file, the settings that actually determine
correctness are stated explicitly and permanently: `FLOCI_STORAGE_MODE: hybrid`
(without which the rest is decoration), the `${FLOCI_HOST_DATA_DIR:?…}` guard
that makes Compose fail loudly rather than mount the wrong thing, and
`FLOCI_STORAGE_PRUNE_VOLUMES_ON_DELETE: "false"`. Each is a security-relevant
decision that can now be reviewed *before* it causes data loss, and changed only
through a commit that carries an author, a timestamp and a diff.

**What an instructor or colleague can verify from the repository that they could
not verify from a typed command:** that persistence was configured deliberately
rather than accidentally, and that it was configured *before* the evidence was
produced - the commit graph makes the ordering checkable, with `.gitignore` as
the oldest commit proving no secret could ever have entered the history. They can
reproduce my exact environment on a different machine from the file alone and get
the same result, which is the definition of reproducibility. They can review what
is deliberately absent - no hardcoded `~`, no top-level `volumes:` block that
could silently orphan state, no credentials. And they can confirm the negative
case: `git log` shows the ignore rules preceded every artefact, so the absence of
secrets is a demonstrable property of the history rather than my assurance. A
command I typed proves only that I once claimed to have typed it.
