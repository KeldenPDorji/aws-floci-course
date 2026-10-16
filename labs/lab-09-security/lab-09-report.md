# Lab 09 - Securing USMS with IAM roles and security groups

## 1. Summary

This lab reviewed the system Labs 01-08 built, on both axes of access control:
- **who may call what (IAM)**
- **what may reach what (security groups and routing)**

It then fixed what the review found, without changing what the system does.

**Identity:**
- **Read-only split:** `USMSStudentDataReadOnly` (Get + List, with an
  explicit Deny on every write), carried by a new
  `usms-transcripts-reader-role`.
- **Confused-deputy fix:** `usms-ecs-task-role`'s trust policy now has the
  `aws:SourceAccount` and `aws:SourceArn` conditions, with the **same
  principal**.
- **Deployment identity:** `usms-deploy-role`, the first identity the course
  has had that is not root. It trusts `user/usms-admin-01`, carries
  `USMSDeployBase` (`iam:PassRole` scoped to three named roles, ECS tasks
  only, and an explicit Deny on passing anything to EC2), and is capped by
  `USMSPermissionsBoundary`. The boundary itself is attached to nothing.
- **Key rotation:** `usms-dev-01`'s Lab 01 access key was rotated (create,
  move, deactivate, delete).
- **IMDSv2:** required, with a hop limit of 1, on `usms-web-01`. The
  endpoint is switched off on `usms-db-01`, which has no role.

**Network:**
- **Written egress** on `usms-alb-sg` (tcp/80 to `usms-enrolment-sg`
  only), `usms-enrolment-sg` (tcp/443 to the S3 prefix list and HTTPS) and
  `usms-db-sg` (tcp/443 only), and in Exercise 1 on `usms-app-sg`. The
  allow-all default is gone from all four.
- **SSH:** `usms-app-sg`'s tcp/22 is now sourced from `usms-bastion-sg`, not
  `10.0.0.0/16`.
- **The data tier's isolation**, proved by five independent controls.

**Support path A, on Floci 2.2.0.** On this build the IAM simulator
**really evaluates** conditions and permissions boundaries. So the PassRole
scope and the boundary were shown with IAM's own decisions (`allowed`,
`explicitDeny`, `implicitDeny`), not only by reading the documents. Nothing
is *enforced* on real calls: Floci authorises nothing and carries no
traffic. Every network claim is therefore a claim about rules, read back.

**Verification:**
- `verify-lab-09.sh`: **`PASS=49 FAIL=1`**. The one failure is
  `usms-db-01 has NO public address`, because Floci gives every instance
  the placeholder `127.0.0.1`.
- **Persistence:** `PERSISTENCE PROVEN` across a restart.
- **Regression:** `NOTHING BROKE`. The five earlier verify scripts read
  exactly as at the baseline.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| Policies | `USMSStudentDataReadOnly`, `USMSDeployBase`, `USMSPermissionsBoundary` (a boundary only, 0 attachments), `USMSBreakGlassSuspendScaling` (Exercise 2) |
| Roles | `usms-transcripts-reader-role`, `usms-deploy-role` (+ boundary), `usms-breakglass-role` (+ boundary, MFA + ExternalId; Exercise 2) |
| Trust policies rewritten | `usms-ecs-task-role` (Step 7); `usms-ecs-exec-role` and `usms-lambda-exec-role` (Exercise 2). Same principals, new conditions |
| Credentials | `usms-dev-01`: one access key, created 2026-10-16; the Lab 01 key deleted; the `usms-dev` profile repointed |
| Instances | `usms-web-01` `HttpTokens required`, hop limit 1; `usms-db-01` `HttpEndpoint disabled` |
| Security groups | Written egress on `usms-alb-sg`, `usms-enrolment-sg`, `usms-db-sg`, `usms-app-sg`; `usms-app-sg` tcp/22 from `usms-bastion-sg` |
| Repaired before the baseline | `usms-db-sg` and `usms-enrolment-sg` ingress re-applied from their committed documents (Section 3.1) |
| Files | 15 new documents in `policies/` (Section 3.10); `configs/lab-09.env` (17 exports, no key ID); `configs/usms-iam-accepted-findings.tsv`; the scripts in Section 3.10; `scripts/cleanup/lab-09-cleanup.sh` (never run) |

---

## 2. Evidence index

The guide's checklist asks for screenshots of Checkpoints 4, 8 and 10. Four
screenshots cover those, plus Checkpoint 3, Checkpoint 9, persistence and
verification, without repeating each other.

Everything else is command output under `outputs/` (git-ignored), quoted
where used. The steps with no screenshot are covered by those files:
- the inventory, the audits and the baseline (Checkpoints 1-2 and 7)
- the session policy
- the key rotation (Checkpoint 5)
- IMDS (Checkpoint 6)

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoints 3-4: `SAME PRINCIPAL, NEW CONDITION`; the reader role's `ecs-tasks` trust with `StringEquals,ArnLike` and `USMSStudentDataReadOnly`; `usms-deploy-role` with the boundary, 3600 s, trusting `user/usms-admin-01`; PassRole on three named ARNs to `ecs-tasks` plus `NeverPassAnythingToEC2`; the boundary at `AttachmentCount=0`, `0/0/0`; six simulator decisions | [3.4](#34-checkpoints-3-4---identity) |
| 02 | Checkpoints 8-10: the compact reachability matrix (ingress unchanged; SSH `<-sg:usms-bastion-sg`; egress written on three groups; the single points of control) and the five-control negative proof for `usms-db-01` | [3.7](#37-checkpoints-8-10---network) |
| 03 | Checkpoint 11: nine controls re-derived after a Floci restart, `PERSISTENCE PROVEN`; the five earlier verify lines; `NOTHING BROKE` | [3.8](#38-checkpoint-11---persistence-and-regression) |
| 04 | Section 8 and Checkpoint 12: `PASS=49 FAIL=1`; `lab-09.env` populated; no access key ID; no unexpanded shell variable in `policies/`; nothing under `outputs/`; `check-ignore` naming the rule for both the key file and the inventory | [3.9](#39-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-20)

### 3.1 Starting point, and a repair before the baseline (Steps 1-2)

**Seventeen values, all populated.** One repository difference matters:
`lab-01.env`'s `USMS_ROLE_EC2`, `USMS_ROLE_DEVELOPER` and `USMS_ROLE_LAMBDA`
hold **ARNs**, not names. The guide's `--role-name $USMS_ROLE_EC2` would
fail, so every script derives the name with `${VAR##*/}`.

**The security groups needed a repair first** (`outputs/lab-09-step0-repair.txt`).
Labs 02-05 ran on Floci 1.5.34, which never stored group-referenced sources.
The rules survived as entries with **no source at all**:

```text
usms-db-sg         tcp/5432 from NO SOURCE | tcp/5432 from NO SOURCE | tcp/5432 from NO SOURCE
usms-enrolment-sg  (no ingress rule at all)   [rules API: 2 x tcp/80 with no source]
usms-app-sg        ... tcp/22 from 10.0.0.0/16 | ... | tcp/22 from NO SOURCE
```

Floci 2.2.0 stores group references, so for each group I cleared the
placeholders and re-applied the document the earlier lab had committed:
- `policies/usms-db-sg-ingress.json` (tcp/5432 from `usms-app-sg`)
- `policies/usms-enrolment-sg-ingress-alb.json` (tcp/80 from `usms-alb-sg`)
- `usms-app-sg`'s tcp/22 from `10.0.0.0/16` re-authorized, the starting
  state Step 16 expects

**Two Floci behaviours** found on throwaway groups shaped how:
- **A revoke with no source matches every rule on that port,** including a
  group reference. So the placeholders went first, and the correct rule
  went second.
- **Floci keeps two stores.** `describe-security-groups` (`IpPermissions`)
  is updated by revoke. `describe-security-group-rules` is **never**
  updated by revoke, and still lists cleared rules. Every Lab 09 script
  reads `describe-security-groups`.

Results of the repair:
- `verify-lab-02`: 32/1 -> **33/0**
- `verify-lab-04`: 38/1 -> **39/0**
- `verify-lab-05`: stays at one failure. Its "exactly one ingress rule"
  check reads the stale rules store

**Step 2's baseline** was recorded *after* the repair
(`outputs/lab-09-pre-verify.txt`). It uses `grep '^PASS='` rather than the
guide's `tail -1`, because Labs 05 and 06 print a remedy paragraph after
their summary line:

```text
lab-02 PASS=33 FAIL=0   lab-03 PASS=31 FAIL=5   lab-04 PASS=39 FAIL=0   lab-05 PASS=49 FAIL=1   lab-06 PASS=39 FAIL=3
```

Labs 03, 05 and 06 carry their documented Floci failures:
- **Lab 03:** placeholder addresses, no `AttachVolume`
- **Lab 05:** the stale rules store
- **Lab 06:** no scheduled actions

The guide asks for `FAIL=0` from Labs 02, 03, 05 and 06. That is not
reachable on this build for 03, 05 and 06, and the baseline records what is
true.

### 3.2 Probe, inventory and the IAM audit (Steps 3-6)

**Step 3** (`scripts/utilities/lab-09-probe.sh`, `outputs/lab-09-probe.txt`):
every call answered. These are the guide's "expected `not available`":
- `get-account-authorization-details`
- `simulate-principal-policy`
- Access Analyzer

The simulator gave real decisions for the developer role:
`ec2:DescribeVpcs allowed`, `iam:CreateUser explicitDeny`,
`ecs:ListClusters implicitDeny`. That makes this **path A**.

`get-credential-report` answered only because the probe had run
`generate-credential-report` first.

**Step 4** (`scripts/utilities/usms-identity-inventory.sh`) inventoried
**10 roles**, not the guide's five, because Labs 06-07 and Lab 01's
exercises added roles:
- the service-linked role
- `usms-eks-cluster-role` and `usms-eks-node-role`
- `usms-analytics-partner-role` and `usms-backup-operator-role`

No role had a permissions boundary. The inventory uses `get-role` per role,
because `list-roles` omits the boundary.

**Step 5** (`scripts/utilities/usms-iam-audit.sh`, the guide's four checks):
**`HIGH=8 MED=33`**, exit 1. All eight HIGHs are the same shape, a service
principal with no condition:
- **ec2:** `usms-ec2-app-role`, `usms-eks-node-role`
- **ecs-tasks:** `usms-ecs-task-role`, `usms-ecs-exec-role`
- **lambda:** `usms-lambda-exec-role`, `usms-backup-operator-role`
- **eks:** `usms-eks-cluster-role`
- **application-autoscaling:** the service-linked role

The MEDs are mostly mutating actions on `Resource "*"`, in Lab 01's
developer policy and Lab 07's EKS stand-ins. This is a convention, not one
mistake.

**Step 6** (`outputs/lab-09-step6.txt`): `USMSStudentDataReadWrite` v1 has
**five** actions:
- `ListBucket` and `GetBucketLocation` on the bucket
- `GetObject`, `PutObject` and `DeleteObject` on the objects

It also has an explicit Deny on `DeleteBucket`, and **three** holders,
because Lab 07 added the EKS node role. The bucket did not exist:
`head-bucket` returned 404, exit 254.

### 3.3 The read-only split and the confused-deputy fix (Step 7)

The policy and rule documents were written **by lookup**.
`scripts/utilities/write-lab-09-policies.sh` writes every document that
embeds an ID with an unquoted heredoc, and refuses to write one if any
value is empty. The documents without variables are plain files. All are
valid JSON with zero unexpanded `$`.

- **`USMSStudentDataReadOnly`:** `ListBucket` on the bucket, `GetObject` on
  the objects, and an explicit Deny on `PutObject`, `DeleteObject`,
  `DeleteBucket` and `PutBucketPolicy`. The Deny adds nothing today, but it
  still wins if someone later attaches a broader policy, so it is
  deliberately not "redundant".
- **`usms-transcripts-reader-role`:** trusts `ecs-tasks.amazonaws.com` with
  the two conditions, 3600 s, and carries the read-only policy.
- **`usms-ecs-task-role`:** the original trust document was saved first
  (`outputs/lab-09-ecs-task-role-trust-before.json`, the undo), then
  replaced. Its permissions are untouched; Lab 10 still needs
  `USMSStudentDataReadWrite`.

`scripts/utilities/lab-09-compare.py trust` reads both documents and
prints `SAME PRINCIPAL, NEW CONDITION` (screenshot 01).

### 3.4 Checkpoints 3-4 - identity

**Step 8** created three things:
- `USMSPermissionsBoundary`, attached to nothing
- `USMSDeployBase`
- `usms-deploy-role`, with `--permissions-boundary` (this build stores it)
  and `USMSDeployBase` attached

To prove the documents behave as intended,
`scripts/utilities/lab-09-passrole-proof.sh` reads the **live** default
versions of both policies and asks `simulate-custom-policy`. The identity
is `USMSDeployBase`, the boundary is `USMSPermissionsBoundary`, and
`iam:PassedToService` is supplied as context.

![Checkpoints 3-4: SAME PRINCIPAL, NEW CONDITION; usms-transcripts-reader-role ecs-tasks.amazonaws.com StringEquals,ArnLike; USMSStudentDataReadOnly; usms-deploy-role arn:aws:iam::000000000000:policy/USMSPermissionsBoundary 3600 arn:aws:iam::000000000000:user/usms-admin-01; PassOnlyTheseThreeRolesAndOnlyToTheseServices Allow usms-ecs-exec-role,usms-ecs-task-role,usms-transcripts-reader-role ecs-tasks.amazonaws.com; NeverPassAnythingToEC2 Deny * ec2.amazonaws.com; USMSPermissionsBoundary AttachmentCount=0 roles/users/groups attached=0/0/0; simulator: PassRole task-role to ecs-tasks allowed, to ec2 explicitDeny, unlisted ec2-app-role implicitDeny, ecs:UpdateService allowed, iam:AttachRolePolicy explicitDeny, ec2:RunInstances implicitDeny](../../screenshots/lab09-01-checkpoints3-4-identity.png)

The six decisions are the escalation path from Step 8, closed at each
point:

| Request | Decision | Why |
|---|---|---|
| PassRole `usms-ecs-task-role` -> ecs-tasks | `allowed` | Named ARN, the right service |
| PassRole `usms-ecs-task-role` -> **ec2** | `explicitDeny` | `NeverPassAnythingToEC2`, so an instance can never inherit the task role |
| PassRole **`usms-ec2-app-role`** -> ecs-tasks | `implicitDeny` | Not one of the three named ARNs |
| `ecs:UpdateService` | `allowed` | In the identity policy and inside the ceiling |
| `iam:AttachRolePolicy` | `explicitDeny` | The boundary forbids identity changes, whatever is attached later |
| `ec2:RunInstances` | `implicitDeny` | In neither document, so step 1 of the escalation is gone too |

I also showed the boundary is a ceiling and not a grant. A test identity
policy allowing `ec2:RunInstances` and `iam:*` evaluated as `allowed`
everywhere without the boundary. With it: `RunInstances implicitDeny`,
`CreateUser explicitDeny`, `ListRoles allowed`. The intersection, computed
by IAM.

**One harness detail.** `simulate-custom-policy --policy-input-list
file://...` silently returned `implicitDeny` for everything. The documents
have to be passed inline, as `"$(cat file)"`, so the proof script reads
them from IAM instead.

`AttachmentCount=0` and `0/0/0` show the boundary is attached to nothing:
the one control capping the pipeline, and the one a tidy colleague would
delete. Section 15's KEEP column says the same.

**Checkpoints 3 and 4** hold.

### 3.5 The session policy (Step 9)

`outputs/lab-09-step9-session.txt` records the session.

I used `usms-dev` to assume `usms-developer-role`, with a session policy,
for 900 s. `USMSDeveloperBase` v3 already allows `sts:GetCallerIdentity`,
and its `s3:List*` covers the guide's fallback, so the session policy adds
`ecs:ListClusters` as the action the role does not have.

The hand intersection and the simulator (identity = `USMSDeveloperBase`
v3, session policy as the cap) agree:

| Action | Result |
|---|---|
| `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`, `sts:GetCallerIdentity` | allowed (both) |
| `ecs:ListClusters` | denied: in the session, never in the role |
| `ec2:CreateVpc` | denied: in the role, not in the session |
| `iam:CreateUser` | `explicitDeny` |

Real calls are not enforced. The scoped session **created an IAM user**
(`usms-session-probe`, deleted at once), which the session policy never
allowed. The credentials file was removed straight after use, and the
three variables were never exported in a shell that outlived the step.

### 3.6 Credentials and metadata (Steps 10-11)

**Step 10** (`outputs/lab-09-step10-keys.txt`):

```text
before:  AKIAPLD...  (old)  Active   2026-08-15
create:  AKIAL96...  (new)  -> outputs/usms-dev-01-access-key-new.json (600, .gitignore:8:outputs/*)
move:    profile usms-dev uses AKIAL96... -> arn:aws:iam::000000000000:user/usms-dev-01
deact.:  AKIAL96... Active / AKIAPLD... Inactive    -> still user/usms-dev-01
delete:  AKIAL96...  Active   2026-10-16            -> still user/usms-dev-01
```

The key IDs are truncated here for the same reason `configs/lab-09.env`
leaves them out. The full IDs are in `outputs/lab-09-step10-keys.txt`,
which is git-ignored.

The guide's pause between deactivate and delete was compressed to seconds.

The probe found two Floci behaviours that make the order the *only*
protection here:
- **An `Inactive` key still authenticates.**
- **A deleted key silently becomes root.** `get-caller-identity` returned
  `arn:aws:iam::000000000000:root` for a throwaway user's deleted key, not
  an error.

A profile left on the old key would not have failed. It would have quietly
gained root.

On a real account, humans would use IAM Identity Center (short sessions,
MFA) and workloads would use roles. The course keeps one key only because
Lab 02's assume-role handshake needs a named user. The key ID is
deliberately absent from `configs/lab-09.env` (screenshot 04).

**Step 11** (`outputs/lab-09-step11-imds.txt`):
- **`usms-web-01`:** `HttpTokens optional -> required`, hop limit 1,
  endpoint enabled (it has a role and needs it). Result: `IMDSv2 REQUIRED,
  HOP LIMIT 1`. This build stores the option.
- **`usms-db-01`** ("Your turn"): no instance profile, so
  `--http-endpoint disabled`.

What each setting does:
- **`--http-tokens required`** prevents the **SSRF** credential theft
  (a forged GET to `169.254.169.254` can obtain no token).
- **The hop limit of 1** prevents a **container on the instance** from
  reaching the host's credentials.
- **The safe rollout on real AWS:** watch the per-instance
  `MetadataNoToken` metric reach zero, upgrading old SDKs, before requiring
  tokens.

### 3.7 Checkpoints 8-10 - network

**Step 12's audit** (`scripts/utilities/usms-sg-audit.sh`) reads
`describe-security-groups` only (Section 3.1) and also flags rules with no
source. Before any change: **`HIGH=4 MED=12 LOW=6`** over 9 groups
(`outputs/lab-09-sg-findings-before.txt`). The default allow-all egress
was on every group.

Verdicts on the HIGHs:
- **`usms-alb-sg`'s internet ingress:** accepted (Lab 05 argued it)
- **`usms-app-sg`'s internet ingress:** open (Exercise 4)

**Steps 13-15.** Each group's replacement egress was **authorized first,
then the default revoked** with `policies/usms-egress-allow-all.json`. That
undo document existed before the first revoke.
- **`usms-enrolment-sg`:** tcp/443 to `pl-63a5400a`. The S3 prefix list
  was found by `describe-prefix-lists`; the private route table carries no
  prefix-list route on this build. Plus tcp/443 to `0.0.0.0/0` for the
  image pull and logs.
- **`usms-alb-sg`:** tcp/80 to **`usms-enrolment-sg`**, a group
  reference, so it stays right as tasks scale.
- **`usms-db-sg`:** tcp/443 to `0.0.0.0/0`, for OS updates through the
  NAT. On real AWS, `dnf` would also need UDP/TCP 53 to the resolver
  (Exercise 1 writes that pair for the web tier).

**Step 16.** The bastion-sourced rule was added first
(`policies/usms-app-sg-ssh-bastion.json`, reusing Lab 02 Exercise 2's
`usms-bastion-sg`). The `10.0.0.0/16` rule was then revoked **by its CIDR
with `--ip-permissions`**. The guide's `--security-group-rule-ids` revoke
returns `True` and removes nothing on Floci 2.2.0 (tested on a throwaway
group).

**A bug in the guide's own checks.** Every allow-all count is written
``length(IpPermissionsEgress[?IpProtocol==`-1`])``. In JMESPath, backticks
make `-1` a **number**, but `IpProtocol` is the **string** `"-1"`, so the
count is always 0. Every "no allow-all egress" check would pass before
anything was changed. I caught it because my pre-change read-back said 0
on groups the audit showed still had the default. My scripts use
``"-1"`` (a JSON string literal inside backticks). With that fix, the
counts went 1 -> 0 as each step ran.

![Checkpoints 8-10: compact reachability matrix - usms-alb-sg tcp/80,443 from 0.0.0.0/0; usms-app-sg tcp/80,443 from the internet and tcp/22 from sg:usms-bastion-sg; usms-db-sg tcp/5432 from sg:usms-app-sg; usms-enrolment-sg tcp/80 from sg:usms-alb-sg; egress usms-alb-sg tcp/80 -> usms-enrolment-sg, usms-db-sg tcp/443 -> 0.0.0.0/0, usms-enrolment-sg tcp/443 -> pl-63a5400a and 0.0.0.0/0, app/bastion/eks/exam still all/all; single points of control bastion, db, eks-cluster, enrolment, exam; negative proof for usms-db-01: 127.0.0.1, False, None nat-dc59b1563c5597c36, 5432 sg-38365af9db7017f8b None, acl-74767cad80f9e8304 False](../../screenshots/lab09-02-checkpoints8-10-network.png)

`scripts/utilities/usms-reachability-matrix.sh` gives every verdict from
`IpPermissions` and `IpPermissionsEgress` alone. Its `--usms --compact`
form fits one screen. What the screenshot shows:

- **Ingress is unchanged** except the SSH cutover (Checkpoint 9).
  `usms-app-sg`'s tcp/22 now names `sg:usms-bastion-sg`, with no CIDR.
  `usms-db-sg` and `usms-enrolment-sg` admit only a group.
- **Egress is written on three groups** (Checkpoint 8). `usms-app-sg`
  still shows `all/all` here; Exercise 1 wrote it afterwards (`MED` 8 -> 7).
  `usms-bastion-sg`'s egress is a jump host's job (Exercise 1).
- **Two groups admit the internet:** `usms-alb-sg` (accepted) and
  `usms-app-sg` (the second front door, Exercise 4).
- **Single points of control include `usms-enrolment-sg` and
  `usms-db-sg`.** The matrix models security groups only, though. The
  tasks and the database also sit in private subnets with no internet
  route (the exposure report classes them `ISOLATED`), so a one-axis tool
  understates the defences on the other axis.

**The negative proof** (`scripts/utilities/lab-09-negative-proof.sh`).
Every identifier is looked up. Four of the five controls hold as designed:
- **Control 2:** the subnet does not auto-assign (`False`).
- **Control 3:** `0.0.0.0/0` goes to `nat-...`, with no `igw-` (the
  load-bearing one).
- **Control 4:** tcp/5432 from `sg-38365af9db7017f8b` (`usms-app-sg`) and
  no CIDR.
- **Control 5:** the custom NACL `acl-74767cad80f9e8304`, not the default.

**Control 1 reads `127.0.0.1`**, Floci's placeholder public address for
every instance (Lab 03 problem 13). It is loopback, not internet-routable.
On real AWS `usms-db-01` would have no public address. This is also
`verify-lab-09`'s one failure.

**Checkpoint 10** holds, with control 1 read as a Floci limitation.

After Step 17 the SG audit read **`HIGH=4 MED=8 LOW=6`**
(`outputs/lab-09-sg-findings-after.txt`): three egress MEDs and the SSH
MED closed. The IAM audit read **`HIGH=7 MED=35`** over 12 roles
(`outputs/lab-09-iam-findings-after.txt`): the task role fixed, and the
reader role conditioned from birth.

### 3.8 Checkpoint 11 - persistence and regression

`scripts/utilities/lab-09-restart-facts.sh` reads nine controls, every
identifier re-derived. Security groups are found by group name, the web
instance by its `Name` tag. It ran before `floci-down` and after
`floci-up`.

The five earlier verify scripts were re-run after the restart
(`outputs/lab-09-post-verify.txt`).

![Checkpoint 11: after restart - usms-ecs-task-role trust condition keys 2; usms-deploy-role boundary USMSPermissionsBoundary; usms-transcripts-reader-role with USMSStudentDataReadOnly; usms-dev-01 access keys 1; allow-all egress 0 on usms-alb-sg, usms-enrolment-sg, usms-db-sg; usms-app-sg CIDR sources on tcp/22 0; usms-web-01 HttpTokens required; PERSISTENCE PROVEN; lab-02 33/0, lab-03 31/5, lab-04 39/0, lab-05 49/1, lab-06 39/3; NOTHING BROKE](../../screenshots/lab09-03-checkpoint11-persistence.png)

- **`PERSISTENCE PROVEN`:** the condition, the boundary, the reader role
  and its policy, one key, three zeros of allow-all egress, zero CIDR SSH
  sources, and `required` all survived a `docker compose stop`/`start`.
- **`NOTHING BROKE`:** no property any earlier lab asserted changed. The
  regression check was written before this lab and knows nothing about
  it.

The re-run after Exercises 1-2 also changed nothing: 33/0, 31/5, 39/0,
49/1, 39/3.

### 3.9 Verification and hygiene

`configs/lab-09.env` is written by `scripts/utilities/write-lab-09-env.sh`.
Every value is a lookup. The computed allow-all count is worked out first
(the guide's "readable alternative" to escaping `\$` inside the heredoc),
and the key's **creation date** is recorded, never its ID. After
Exercise 5 it adds `USMS_BUCKET_POLICY_DRAFT`, making **17** exports.

`scripts/utilities/verify-lab-09.sh` is the guide's 50 checks with five
changes, each for a reason found in this repository or this build:
1. **Role names derived from ARNs.**
2. **IAM variables allowed in the "no unexpanded variable" check.** Lab
   01's `usms-self-manage-credentials.json` uses `${aws:username}` on
   purpose, so the check looks for shell-style variables only.
3. **The `.gitkeep` fix**, as in Labs 04-08.
4. **The ``"-1"`` string literal.**
5. **An `attachcount` helper** in place of the guide's `\\\"...\\\"`
   quoting. That quoting passed a literal backslash-quote to `--query` and
   made the boundary check fail although the data read 0.

![Section 8 and Checkpoint 12: FAIL usms-db-01 has NO public address (expect FAIL on Floci: placeholder 127.0.0.1), PASS=49 FAIL=1; lab-09.env all values populated; no access key ID in configs/lab-09.env; no unexpanded shell variable in any policies/ document; nothing under outputs/, no root .env, no .bak in git status; .gitignore:8:outputs/* for usms-dev-01-access-key-new.json and lab-09-identity-inventory.json; git ls-files outputs/ only outputs/.gitkeep](../../screenshots/lab09-04-verify-env-and-hygiene.png)

- **Verify:** `PASS=49 FAIL=1`, and the one failure is labelled as Floci's
  placeholder in the check's own name.
- **The env file:** no empty values and **no access key ID**.
- **`policies/`:** no unexpanded shell variable in any document.
- **Git hygiene:**
  - nothing under `outputs/` in `git status`
  - `check-ignore` names `.gitignore:8:outputs/*` for **both** the new key
    file and the inventory
  - `ls-files outputs/` lists only `.gitkeep`

The exports line was not captured in this screenshot (the empty-value
`grep` was run twice). The file's 17 exports are quoted in
`configs/lab-09.env` itself and in `outputs/lab-09-ex5.txt`.

**Checkpoint 12** is complete up to the commit, which I make myself.

### 3.10 Files

- **`policies/` (15 new):**
  - Steps 7-8: `usms-student-data-ro-policy`, `trust-ecs-tasks-scoped`,
    `usms-permissions-boundary`, `usms-deploy-policy`, `trust-deploy`
  - Steps 13-16: `usms-enrolment-sg-egress`, `usms-alb-sg-egress`,
    `usms-db-sg-egress`, `usms-egress-allow-all` (the undo),
    `usms-app-sg-ssh-bastion`
  - Exercise 1: `usms-app-sg-egress`
  - Exercise 2: `trust-lambda-scoped`, `trust-breakglass`,
    `usms-breakglass-policy`
- **Scripts:**
  - `scripts/utilities/`: `lab-09-probe.sh`, `usms-identity-inventory.sh`,
    `usms-iam-audit.sh`, `usms-sg-audit.sh`, `usms-reachability-matrix.sh`,
    `write-lab-09-policies.sh`, `lab-09-compare.py`,
    `lab-09-passrole-proof.sh`, `lab-09-negative-proof.sh`,
    `lab-09-restart-facts.sh`, `write-lab-09-env.sh`, `verify-lab-09.sh`,
    `usms-exposure-report.sh` (Exercise 3),
    `usms-bucket-policy-draft.sh` (Exercise 5)
  - `scripts/cleanup/lab-09-cleanup.sh`: never run; it uses
    `--ip-permissions` revokes, and keeps `usms-bastion-sg`, which Lab 02
    owns
- **Config:** `configs/lab-09.env` (17 exports) and
  `configs/usms-iam-accepted-findings.tsv` (Exercise 2).

---

## 4. Exercises 1-5

Full commands and output are in [`exercises.md`](exercises.md).

| # | Deliverable | Result |
|---|---|---|
| 1 | Web-tier egress | `usms-app-sg`: tcp/443 to the S3 prefix list and `0.0.0.0/0`; tcp/80 to **`usms-alb-sg`**; tcp/5432 to `usms-db-sg`; **udp/53 and tcp/53 to `10.0.0.2/32`** (VPC base + 2). Authorized before revoking; ingress untouched; SG audit MED 8 -> 7. IMDS needs no rule (link-local). The bastion's egress is its function, and should be tcp/22 to the groups it administers |
| 2 | Break glass and open findings | `usms-breakglass-role`: admin user only, MFA **AND** ExternalId in one block, 3600 s (IAM refuses 900), boundary, two Application Auto Scaling actions. Simulator: Register/Describe allowed, PutScalingPolicy and UpdateService denied. Fixed `usms-ecs-exec-role` and `usms-lambda-exec-role`; accepted `usms-ec2-app-role` with compensating controls. The audit reads a committed accepted-findings TSV: `HIGH=0 ACCEPTED=5`, still exit 1 without it |
| 3 | Exposure report | Six interfaces from routes, addresses and rules: web tier `EXPOSED`, database and tasks `ISOLATED`; identical from three directories; JSON written; no `-e`, justified. A public interface with no ingress rule = `ADDRESSABLE` (defended). Floci gives the NAT and the ALB no interface, and says so |
| 4 | Review for the ISO | The second front door and the seven-step move behind the ALB (not run, three danger blocks); egress: three behaviours stopped, two not (HTTPS POST, own-role abuse), with Network Firewall and endpoint-policy costs; the transcript access table: **`usms-audit-01` reads every transcript through `ReadOnlyAccess`** and every EKS pod can write; completeness via `get-account-authorization-details`; detection with CloudTrail, Config, Access Analyzer, GuardDuty and alarms, and the order to read them |
| 5 | Bucket policy draft | Bucket name read from the policy (`${BUCKET_ARN##*:::}`); **eight** roles computed, not three; Allow per role at existing actions; insecure-transport Deny with `Principal "*"`; `NotPrincipal` Deny for everyone else; mechanical checks pass; readiness file; `USMS_BUCKET_POLICY_DRAFT` -> 17 exports. Identity Deny versus resource Deny contrasted |

---

## 5. Review questions

Answered in full in [`../../notes/lab-09-notes.md`](../../notes/lab-09-notes.md).
Summarised:

1. **Independent regression evidence.** Scripts written before this lab
   reported identical lines. Removing allow-all egress could have broken an
   egress assertion; the fix is to re-state the intent (tcp/443), not
   delete the check.
2. **Attached as a policy, the boundary grants.** `ecs:*`, `s3:Get*` and
   more on every resource. The `AttachmentCount = 0` check catches it, but
   only after fixing the guide's quoting, which could never have matched.
3. **Correct ingress, RCE on port 80, exfiltration by HTTPS.** Egress rules
   narrow the exits. Only hostname filtering or interface endpoints close
   them, and Floci models neither.
4. **A service principal cannot be impersonated from a laptop; a user
   principal can.** The conditions defend against the cross-account deputy,
   and the boundary limits a stolen admin session.
5. **Five controls are not five independent ones.** Routing and the
   security group are the pair owned apart. The tasks share the subnet
   controls that the security-group-only matrix cannot see.
6. **"Move" prevents the outage; "deactivate" prevents the irreversible
   delete.** On Floci a deleted key silently became root. Humans should use
   Identity Center and workloads should use roles.
7. **Review proves negatives; tests find what reading misses.** The guide's
   own ``IpProtocol==`-1` `` read correctly and was wrong. Review first,
   then continuous tests.

---

## 6. Problems encountered

### 6.1 The earlier labs' security groups had no sources

Floci 1.5.34 kept group references as sourceless entries. The audit, the
matrix and verify-lab-09's "ingress unchanged" checks would all have
reported nonsense. The fix (Section 3.1) was itself shaped by two Floci
behaviours:
- a sourceless revoke matches every rule on the port
- `describe-security-group-rules` is a second store that revoke never
  updates

### 6.2 Three of the guide's checks cannot work as written

- **``IpProtocol==`-1` ``** compares to a number, so it always counts 0.
- **The boundary's `\\\"...\\\"` quoting** never matches.
- **"No unexpanded variable"** would fail on Lab 01's legitimate
  `${aws:username}`.

All three are fixed in `verify-lab-09.sh` and explained in its header. The
first would have produced a verify that **passed with nothing done**, which
is worse than one that fails.

### 6.3 Revoking by rule ID is a no-op on Floci 2.2.0

`revoke-security-group-ingress` and `-egress` with
`--security-group-rule-ids` return `True` and remove nothing. Step 16 and
the cleanup script revoke with `--ip-permissions` instead, naming the exact
CIDR, which removes exactly that rule and spares a group reference on the
same port (tested on a throwaway group).

### 6.4 A skipped step, found by an error, not hidden by it

When the Stage 1 blocks were run, the trust-policy "before" capture was
skipped, so Step 7's comparison failed with `No such file or directory`.
State showed the read-only policy and the reader role created, and the
task role's trust still unconditioned. I removed the partial outputs, then
ran the remaining steps in order (save the undo, replace, compare). From
there the build ran as one sequence, and only the screenshot commands were
run separately.

### 6.5 Smaller ones

- **I restarted Floci by accident** during probing (`docker restart floci`
  left in a test command). State is in hybrid storage. Floci, EKS (all
  Deployments ready) and ECS (2/2) were confirmed healthy before
  continuing.
- **`simulate-custom-policy` with `file://`** in a list parameter evaluates
  nothing; documents must be passed inline.
- **macOS's bash 3.2 rejects `"${empty[@]}"` under `set -u`.** The PassRole
  proof uses `${extra[@]+"${extra[@]}"}`.
- **zsh history expansion.** The "other key ID" lookup uses `jq --arg ...
  select(.AccessKeyId != $n)` inside single quotes, not JMESPath's `!=`
  inside double quotes.

---

## 7. Floci limitations versus real AWS

| Behaviour | Floci 2.2.0 (observed) | Real AWS |
|---|---|---|
| IAM policy evaluation on API calls | **None**: a scoped session created an IAM user its policy never allowed | Every call |
| `simulate-principal-policy` / `simulate-custom-policy` | **Implemented, with conditions and boundaries**; `file://` in a list parameter silently evaluates nothing | Full |
| `get-account-authorization-details`, Access Analyzer, `generate-credential-report` | Available | Available |
| Permissions boundary on `create-role` / `put-` / `delete-role-permissions-boundary` | Stored and returned; `AttachmentCount` stays 0 | Same, and enforced |
| Trust `Condition` blocks, `update-assume-role-policy` | Stored as written (a replace) | Same, evaluated at `AssumeRole` |
| `MaxSessionDuration` | Minimum 3600 enforced | Same |
| Access keys | Two-key flow works; **an `Inactive` key still authenticates; a deleted key falls back to root** | Inactive is refused; deleted is `InvalidClientTokenId` |
| `get-access-key-last-used` | Fields present, `N/A` | Real date, service, region |
| Security group group references | Stored on 2.2.0 (lost by 1.5.34) | Stored |
| `revoke-...` by `--ip-permissions` | Works; a **sourceless** permission matches every rule on the port | Exact match only |
| `revoke-...` by `--security-group-rule-ids` | **Returns `True`, removes nothing** | Removes that rule |
| `describe-security-group-rules` | A second store, **not updated by revoke** | One consistent view |
| Egress to a prefix list / group | Stored and returned | Same, enforced per packet |
| S3 prefix list | `pl-63a5400a` via `describe-prefix-lists`; no prefix-list route on the private table | Managed list plus an endpoint route |
| Security group and NACL enforcement | None (no traffic) | Every packet |
| `modify-instance-metadata-options` | Stored and returned; no metadata service exists | Enforced at the hypervisor |
| Instance public address | **Placeholder `127.0.0.1` on every instance** | None unless assigned |
| NAT gateway, ALB network interfaces | Not modelled | Present, with public addresses |
| CloudTrail, Config, GuardDuty, Network Firewall, interface endpoints | Not modelled | Available, billed |

**Observed, recorded only, conceptual** (Section 11's distinction, for this
build):
- **Observed:**
  - every document and rule, read back
  - IAM's own decisions for the PassRole scope, the boundary and the
    session intersection (the simulator)
  - the key lifecycle, including Floci's two credential quirks
  - persistence of all nine controls
  - no regression in five earlier labs
- **Recorded only:**
  - every security group rule (there is no traffic)
  - IMDSv2 (there is no metadata service)
  - the trust conditions (never evaluated at `AssumeRole`)
- **Conceptual:**
  - enforcement of any of the above
  - SSRF and the hop limit in action
  - prefix-list routing
  - hostname egress filtering
  - every detective control
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
source configs/lab-09.env
./scripts/utilities/verify-lab-09.sh
./scripts/utilities/usms-identity-inventory.sh > /dev/null && ./scripts/utilities/usms-iam-audit.sh | tail -1
./scripts/utilities/usms-sg-audit.sh | tail -1
```

Expected: `PASS=49  FAIL=1` (the `127.0.0.1` placeholder); IAM `HIGH=0`
with five accepted findings; SG `HIGH=4 MED=7 LOW=6`.
