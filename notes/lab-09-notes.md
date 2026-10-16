# Lab 09 - Securing USMS with IAM roles and security groups - my notes

**Support path (Step 3): A, on Floci 2.2.0.** Every probe answered,
including `simulate-principal-policy`, `get-account-authorization-details`
and Access Analyzer (`outputs/lab-09-probe.txt`).

The simulator **really evaluates**, including conditions and permissions
boundaries:
- `iam:CreateUser` for the developer role is `explicitDeny`
- `ecs:ListClusters` is `implicitDeny`
- the Step 8 results are in the report

Real calls are **not** enforced. Under the Step 9 scoped session, Floci let
me create an IAM user the session policy never allowed.

Two caveats:
- `get-credential-report` answered only because my probe had already run
  `generate-credential-report`
- `simulate-custom-policy --policy-input-list file://...` silently evaluates
  nothing (everything `implicitDeny`); the document has to be passed inline,
  as `"$(cat file)"`

**The bucket did not exist at Step 6.** `head-bucket` on `usms-student-data`
returned `404 Not Found`, exit code 254 (`outputs/lab-09-step6.txt`). Lab 10
creates it.

**Before the baseline I repaired three security groups**
(`outputs/lab-09-step0-repair.txt`). Floci 1.5.34, which ran Labs 02-05,
never stored group-referenced sources. The rules survived as entries with no
source at all:
- three on `usms-db-sg`
- two on `usms-enrolment-sg`, which `describe-security-groups` showed as
  "no ingress at all"
- one tcp/22 on `usms-app-sg`

I cleared the placeholders and re-applied the documents the earlier labs had
committed (`policies/usms-db-sg-ingress.json`,
`policies/usms-enrolment-sg-ingress-alb.json`). `verify-lab-02` went 32/1 ->
33/0 and `verify-lab-04` 38/1 -> 39/0. `verify-lab-05` stays at one failure:
it counts rules through `describe-security-group-rules`, a second store that
Floci never updates on revoke.

## Step 4 "Your turn" - two trust policies side by side

`usms-ec2-app-role` trusts `{"Service": "ec2.amazonaws.com"}`, and
`usms-developer-role` trusts `{"AWS": "arn:aws:iam::000000000000:user/usms-dev-01"}`.
Neither has a condition.

A **service** principal means an AWS service obtains the credentials on
someone's behalf: here, EC2 hands them to whatever runs on an instance
launched with `usms-ec2-app-profile`. So the question "who" becomes "who can
launch an instance with that profile, or run code on one", which is
`iam:PassRole` and the metadata service.

An **AWS** principal names one identity in this account, which must itself
call `sts:AssumeRole` with its own credentials. So "who" is exactly
whoever holds `usms-dev-01`'s access key, which is why Step 10 matters to
this role.

## Step 6 "Your turn" - what each workload needs

Lab 01's policy here has **five** actions, not the guide's three:
`s3:ListBucket` and `s3:GetBucketLocation` on the bucket, and
`s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on the objects.

- **The enrolment API displaying a transcript:** `s3:GetObject` on
  `usms-student-data/*`, plus `s3:ListBucket` on `usms-student-data`.
  `ListBucket` is there so a missing key comes back as `404 NoSuchKey`
  instead of `403 AccessDenied`. Without it, the API cannot tell "this
  student has no transcript yet" from "we are not allowed to look".
- **The registry's upload workflow storing one:** `s3:GetObject`,
  `s3:ListBucket` and `s3:PutObject`.
- **The one action in the second list and not the first:** `s3:PutObject`.

`s3:DeleteObject` is in neither list, though both roles carry it. No USMS
workflow deletes a transcript, and that is a second finding the read-only
split also closes.

## Step 8 - why the audit does not flag the boundary's `Resource "*"`

The audit reads `attachedPolicies` and `inlinePolicies`. A permissions
boundary is in neither: it sits in the role's `PermissionsBoundary` slot,
and its `AttachmentCount` is 0. A ceiling written as `Resource "*"` grants
nothing, so it is not a wildcard finding. The audit would only flag it if
somebody attached it as an ordinary policy, which is also when it would
become dangerous (Review Question 2).

## Step 9 - the session policy, worked by hand and by the simulator

The session allowed `ec2:DescribeVpcs`, `ec2:DescribeSubnets`,
`ec2:DescribeSecurityGroups`, `sts:GetCallerIdentity` and `ecs:ListClusters`.

`USMSDeveloperBase` v3 already allows `sts:GetCallerIdentity`, and `s3:List*`
covers the guide's fallback (`s3:ListAllMyBuckets`). So I used
`ecs:ListClusters`, which the role has never had, as the action that must
come out denied.

Both methods agree (`outputs/lab-09-step9-session.txt`):

| Action | Hand intersection | `simulate-custom-policy` (identity + session as the cap) |
|---|---|---|
| `ec2:DescribeVpcs`, `DescribeSubnets`, `DescribeSecurityGroups` | ALLOWED | allowed |
| `sts:GetCallerIdentity` | ALLOWED | allowed |
| `ecs:ListClusters` | NOT in the identity policy -> denied | implicitDeny |
| `ec2:CreateVpc` (identity yes, session no) | - | implicitDeny |
| `iam:CreateUser` | denied | explicitDeny |

A session policy cannot grant what the role lacks (`ecs:ListClusters`), and
it removes what the role has but the session does not list
(`ec2:CreateVpc`). The session's credentials were removed from `outputs/`
straight away.

## Step 10 - the rotation, and what Floci does not tell you

The four steps ran in order (`outputs/lab-09-step10-keys.txt`):
1. **Create:** `AKIAL96...` was created straight into
   `outputs/usms-dev-01-access-key-new.json` (mode 600,
   `.gitignore:8:outputs/*`).
2. **Move:** the `usms-dev` profile was repointed, and still answered as
   `user/usms-dev-01`.
3. **Deactivate:** two keys, one `Inactive`, and the profile still worked.
4. **Delete:** one key, created on 2026-10-16.

In a real rotation there would be days of silence between steps 3 and 4.
This lab compressed that pause to seconds.

**What the probe found about Floci:**
- an **`Inactive` key still authenticates**
- a **deleted key silently becomes root**: `get-caller-identity` returns
  `arn:aws:iam::000000000000:root` instead of an error

So on this build, a rotation done in the wrong order would not fail. It
would quietly give the profile *more* power. Only the order, and reading the
profile's key back, protected it.

## Step 11 "Your turn" - `usms-db-01`

`usms-db-01` has no instance profile (`IamInstanceProfile` is `None`), so it
has no credentials for the metadata service to leak. I switched the endpoint
off entirely: `--http-endpoint disabled` reads back as `disabled`.

**The same setting on `usms-web-01`** would break the one thing its metadata
service is for. Its SDK gets `usms-ec2-app-role`'s credentials from IMDS, so
every AWS call from the web tier would fail with no credentials. That
includes Lab 10's reads from `usms-student-data`.

## Step 17 - if one control failed

- **If control 3 failed** (an internet gateway route appeared on the
  private subnet), `usms-db-01` would still be unreachable on real AWS:
  - it has no public address for the internet to send to (Floci's
    `127.0.0.1` is a placeholder; Lab 03 gave it none)
  - `usms-db-sg` admits tcp/5432 only from `usms-app-sg`, so a packet from
    the internet is dropped at the instance
- **If control 4 failed** (someone added tcp/5432 from `0.0.0.0/0`), there
  would still be no route back to the internet and no public address, so
  the open rule would admit traffic that cannot arrive. Inside the VPC,
  though, every other workload could now reach the database. Control 4 is
  the only one that also stops lateral movement.

## Review questions (Section 14)

### 1. Why "the five earlier verify scripts report what they did" is strong

Those scripts were written before this lab, by different steps, to assert
what each lab built. They know nothing about Lab 09. Identical summary lines
after the review (screenshot 03) therefore mean that no property any earlier
lab asserted moved: no ingress rule, no service setting, no route. That is
independent evidence, which a check I wrote myself for my own change could
not be.

**A plausible break:** Step 15 revokes `usms-db-sg`'s allow-all egress. If
Lab 02's verify had asserted "the data tier can reach the NAT for updates"
by looking for an `all/all` egress rule, it would have failed.

**What I would have done:** decided whether the old assertion was about the
architecture or about an accident of defaults. Here, the intent was "OS
updates over the NAT", which tcp/443 still satisfies. So I would update the
check to assert tcp/443, and say so in that lab's notes. I would not delete
the check.

In this lab the five lines were identical.

### 2. Attaching the boundary as an ordinary policy

`attach-role-policy` with `USMSPermissionsBoundary` puts it in the identity
slot, where its `Allow` statement **grants**. The deploy role would gain
everything in it that `USMSDeployBase` did not have:
- `ecs:*` instead of seven ECS actions
- `elasticloadbalancing:*`
- `application-autoscaling:*`
- `logs:*` and `cloudwatch:*`
- `s3:Get*`, `s3:List*` and `s3:PutObject` **on every bucket**

The deny statements would still apply. So its permissions *grow*, and
nothing caps them any more if the boundary slot is also emptied.

It becomes dangerous the day the role is attached elsewhere, or the boundary
is edited to widen a "ceiling". Every widening then grants directly.

The Section 8 check that catches it is **"the boundary is attached to
NOTHING as an ordinary policy"** (`AttachmentCount = 0`). The guide's own
version of that check could not have caught it: its quoting passed a literal
backslash-quote to `--query`, so it never matched. I fixed it to a helper
function.

### 3. Correct ingress, and still a breach

Every ingress rule is right, but `usms-web-01` runs an application with a
remote-code-execution bug on its public port 80. The attacker runs code on
the instance and does not need another way in. They read transcripts through
the instance's own role (`usms-ec2-app-role` carries
`USMSStudentDataReadWrite`), then send them out over an **outbound**
connection the attacker's server waits for.

Before Exercise 1, `usms-app-sg` allowed all egress. With Exercise 1's rules
it allows only:
- tcp/443 to anywhere
- tcp/80 to the load balancer
- tcp/5432 to the database
- DNS to `10.0.0.2`

That removes plain-HTTP, SSH, SMTP, IRC and arbitrary-port exfiltration, and
DNS to any resolver but the VPC's. It is **narrower, not closed**: an HTTPS
POST to any server on the internet still works.

**What would prevent it entirely:**
- hostname-based egress filtering (AWS Network Firewall, or an explicit
  forward proxy) allowing only named AWS endpoints
- VPC interface endpoints for STS, ECR and Logs, so `0.0.0.0/0` could be
  removed altogether

This course cannot build either. Floci models neither Network Firewall nor
interface endpoints, and carries no traffic to filter.

### 4. An attacker calling `sts:AssumeRole` from their own machine

- **`usms-ecs-task-role` and `usms-transcripts-reader-role`:** the principal
  is `ecs-tasks.amazonaws.com`. Only that service can be the caller; an
  attacker's own credentials are not that principal, so a direct call is
  refused whatever conditions say. The conditions defend against the other
  route, the confused deputy: tricking ECS into assuming the role for a
  task in *another* account. `aws:SourceAccount = 000000000000` and the
  `aws:SourceArn` pattern refuse that.
- **`usms-deploy-role`:** the principal is `user/usms-admin-01`. A call
  succeeds if the attacker holds that user's credentials, and nothing else
  in the trust policy stands in the way. That is why the next control is the
  boundary, which caps what the stolen session can do: no IAM changes, no
  network deletion, no passing roles to EC2. Its trust hardening would be
  MFA, which Exercise 2's break-glass role shows.

The answers differ because a service principal can only be the service
itself, while a user principal is anyone who holds that user's key.

### 5. Five controls versus one

They are not simply five times better, because the five on `usms-db-01` do
not fail independently in practice:
- **Two depend on one person's change.** Controls 1 and 2 (a public address,
  auto-assign) would fail together in a single "launch it in the public
  subnet" mistake.
- **Three live in one subnet configuration.** Controls 2, 3 and 5 (the
  subnet, its route table and its NACL) are owned by the same
  infrastructure code.

The useful property is that the **load-bearing** pair, routing (3) and the
security group (4), are owned and changed separately.

Are the enrolment tasks less well protected? The matrix says
`usms-enrolment-sg` has **one** ingress rule, but it models security groups
only. The tasks also:
- sit in the same private subnets
- have no public address (`assignPublicIp DISABLED`, Lab 04)
- have no internet gateway route (the exposure report: `ISOLATED`)

So on the axis the matrix does not see, they share the database's controls
1-3 and 5. The single point of control is real only for traffic from
*inside* the VPC, where the security group is the whole defence.

### 6. The two extra rotation steps

- **"Move every consumer" before deactivating** protects against an outage:
  nothing that still holds the old key is cut off while it is the only key.
- **"Deactivate" before deleting** protects against an irreversible mistake.
  If something forgotten was still using the old key, reactivation is one
  call. A deleted secret can never be re-issued. The incident it prevents
  is a nightly job failing the morning after a rotation, with no way back
  except issuing new keys everywhere.

On Floci both steps were also the only protection, because nothing failed
loudly: a deleted key silently became root (Step 10).

A long-lived key is a compromise, because it is valid until someone
remembers to rotate it, wherever it has been copied. A real system would
use:
- **for a human:** IAM Identity Center (SSO) or federation, with short
  session credentials and MFA
- **for a workload:** a role (instance profile, task role, IRSA or Pod
  Identity), never a key

### 7. Is review an adequate substitute for testing?

For a claim about what **cannot** happen, review is the only available
proof. No finite set of tests covers every principal, action and resource.

**A defect that reading catches and testing would miss:** Lab 01's policy
grants `s3:DeleteObject`, which no workflow uses. A test of "can the API
read a transcript" passes either way. Only reading finds the extra verb.

**A defect that testing catches and reading would miss:** this lab's own
guide wrote ``IpProtocol==`-1` ``. It reads perfectly, but in JMESPath the
backticks make `-1` a number, so the count of allow-all rules is always 0,
and every "no allow-all egress" check passes even before anything is
changed. Only running it against a group that still had the rule exposed
that.

For student transcripts I would want **review first**: the access list,
the bucket policy and the trust policies, read against the intended model,
plus the simulator to test the documents' logic. Then **tests** of the
specific paths that must work and must fail, run continuously, because
review describes the documents and only tests show what the system actually
does.
