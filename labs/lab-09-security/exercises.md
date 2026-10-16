# Lab 09 - Independent Exercises 1-5

**Environment:** Floci **2.2.0**, support path A (the IAM simulator really
evaluates; nothing is enforced on real calls), account `000000000000`, VPC
`vpc-1441470d`.

The screenshots cover Checkpoints 3-4, 8-10 and 11 and the verification. The
exercise evidence is command output under `outputs/` (`lab-09-ex1.txt` to
`lab-09-ex5.txt`, `lab-09-exposure.json`, `lab-09-bucket-policy-draft.json`,
`lab-09-lab10-readiness.txt`), quoted below.

After all five exercises:
- `verify-lab-09.sh`: `PASS=49 FAIL=1` (`outputs/lab-09-verify-final.txt`).
  The failure is Floci's `127.0.0.1` placeholder address on `usms-db-01`.
- The five earlier verify scripts read exactly as at the Step 2 baseline:
  33/0, 31/5, 39/0, 49/1, 39/3.

---

## Exercise 1 - Basic: finish the egress work on the web tier

[`policies/usms-app-sg-egress.json`](../../policies/usms-app-sg-egress.json)
is written by `scripts/utilities/write-lab-09-policies.sh` with an
**unquoted** heredoc. Four values must be real IDs at the moment it is
written (the S3 prefix list, `usms-alb-sg`, `usms-db-sg` and the resolver
address). There are no IAM variables in a rule document, so there is nothing
to protect from expansion.

| # | Requirement | Rule | Why this destination |
|---|---|---|---|
| 1 | S3, for Lab 10's transcripts | tcp/443 -> `pl-63a5400a` | Lab 02's gateway endpoint; the managed prefix list is S3's address ranges, kept current by AWS |
| 2 | AWS endpoints over HTTPS, incl. STS | tcp/443 -> `0.0.0.0/0` | STS, ECR, Logs etc. have no fixed addresses here. On real AWS, interface endpoints would replace this |
| 3 | The enrolment API | tcp/80 -> **`usms-alb-sg`** | Since Lab 05 the API's front door is the load balancer, not the tasks. A group reference stays right as the ALB's nodes change address |
| 4 | The database | tcp/5432 -> `usms-db-sg` | The same pair `usms-db-sg`'s ingress names, seen from the other end |
| 5a | DNS | **udp/53** -> `10.0.0.2/32` | The Amazon resolver is the VPC CIDR's base address **+ 2** (`10.0.0.0/16` -> `10.0.0.2`); Lab 02's five reserved addresses per subnet include it. UDP first, because that is what every resolver tries first |
| 5b | DNS | **tcp/53** -> `10.0.0.2/32` | Answers over 512 bytes, and retries after a truncated (`TC`) UDP answer, use TCP. Without it, large answers fail intermittently |

Every rule has a `Description`. **The replacement was authorized first and
the default revoked second** (`outputs/lab-09-ex1.txt`), so there is no
instant in which the web tier can initiate nothing. Ingress was not touched.

```text
sgr-40cb617265ab9ee79  sgr-096001b7d864e6ecf  sgr-63f27a7c43dd5c2d8  sgr-e27b4de95ef1e1e01  sgr-6bf808dee88aea396  sgr-21d1052a608f28915
then revoke the default: True
allow-all egress left on usms-app-sg: 0
usms-app-sg  (sg-38365af9db7017f8b)   interfaces: 2
    ingress:
        tcp/80        from 0.0.0.0/0
        tcp/443       from 0.0.0.0/0
        tcp/22        from sg:usms-bastion-sg
    egress:
        tcp/443       to   0.0.0.0/0, pl:pl-63a5400a
        tcp/80        to   sg:usms-alb-sg
        tcp/5432      to   sg:usms-db-sg
        udp/53        to   10.0.0.2/32
        tcp/53        to   10.0.0.2/32
    HIGH ingress tcp/80 from 0.0.0.0/0
    HIGH ingress tcp/443 from 0.0.0.0/0
== matrix egress line
  usms-app-sg   tcp/443 -> 0.0.0.0/0, pl-63a5400a ; tcp/80 -> usms-alb-sg ; tcp/5432 -> usms-db-sg ; udp/53 -> 10.0.0.2/32 ; tcp/53 -> 10.0.0.2/32
== audit totals: HIGH=4  MED=7  LOW=6  groups=9
== verify-lab-09: PASS=49  FAIL=1
```

The default-egress MED on `usms-app-sg` is gone (the SG audit's MED count
went 8 -> 7), and the two remaining HIGHs are its internet ingress
(Exercise 4).

**`169.254.169.254`** needs no rule. The metadata service is link-local,
answered by the hypervisor on the instance's own host. The packet never
leaves for the VPC network where security groups apply. That is also why
IMDSv2 and the hop limit (Step 11), not a security group, are what protect
it.

**`usms-bastion-sg`'s egress is different in kind.** A jump host exists to
*initiate* SSH. Its egress is its function, not a leak to be closed. It
should not be allow-all, though. Its destination should be tcp/22 to the
groups it administers (`usms-app-sg`, and `usms-db-sg` if the database is
administered over SSH) as group references, so a compromised bastion can
reach the servers it manages and nothing else.

---

## Exercise 2 - Intermediate: the break-glass role, and the findings this lab left open

### Part A - `usms-breakglass-role`

| Requirement | How (`outputs/lab-09-ex2.txt`) |
|---|---|
| 1. Assumable only by `usms-admin-01` | [`policies/trust-breakglass.json`](../../policies/trust-breakglass.json): `Principal.AWS = arn:aws:iam::000000000000:user/usms-admin-01` |
| 2. MFA | `"Bool": {"aws:MultiFactorAuthPresent": "true"}` |
| 3. `sts:ExternalId` | `"StringEquals": {"sts:ExternalId": "usms-breakglass-suspend-scaling"}` |
| 4. Shortest maximum session | `--max-session-duration 3600`. IAM refuses anything shorter: `update-role --max-session-duration 900` returned `Invalid value for parameter MaxSessionDuration, value: 900, valid min value: 3600`. A caller can still ask for less with `--duration-seconds` |
| 5. A permissions boundary | `USMSPermissionsBoundary` |
| 6. Only Lab 06's suspend/resume | [`policies/usms-breakglass-policy.json`](../../policies/usms-breakglass-policy.json): `application-autoscaling:RegisterScalableTarget` (Lab 06 suspended scaling with `register-scalable-target --suspended-state`) and `DescribeScalableTargets`. No wildcard actions |

```text
3600   arn:aws:iam::000000000000:policy/USMSPermissionsBoundary   arn:aws:iam::000000000000:user/usms-admin-01   Bool,StringEquals
-- what the role may do (simulate-custom-policy, boundary applied):
   application-autoscaling:RegisterScalableTarget   allowed
   application-autoscaling:DescribeScalableTargets  allowed
   application-autoscaling:PutScalingPolicy         implicitDeny
   application-autoscaling:DeleteScalingPolicy      implicitDeny
   ecs:UpdateService                                implicitDeny
   iam:CreateUser                                   explicitDeny
```

**AND, not OR.** Both conditions sit in one `Condition` block under
different operators (`Bool`, `StringEquals`). IAM ANDs every operator in a
block, and every key within an operator, so the caller needs MFA *and* the
external ID. (Values listed inside one key are ORed, which is not what this
uses.)

**What `sts:ExternalId` buys in a single account.** It was designed against
the cross-account confused deputy. Here it is a **deliberate act**: the
value is not in anyone's profile or script, so the role cannot be assumed
by accident, by a copied command, or by a tool that "tries every role". The
person has to look up the break-glass runbook, and the assume call then
records `ExternalId` in CloudTrail. It is not a secret; it is friction with
an audit trail.

The `Resource "*"` on `RegisterScalableTarget` is a known compromise. The
scalable-target ARN is an opaque ID, which would have to be looked up and
pinned per environment. The audit's mutating-verb heuristic does not list
`Register`, so it does not flag it; I am recording it here instead.

### Part B - the three unconditioned service trusts

| Role | Decision | Detail |
|---|---|---|
| `usms-ecs-exec-role` | **Fixed** | `update-assume-role-policy` with `policies/trust-ecs-tasks-scoped.json`. `SAME PRINCIPAL, NEW CONDITION`. ECS documents `aws:SourceAccount` and `aws:SourceArn` for task execution roles |
| `usms-lambda-exec-role` | **Fixed** | `policies/trust-lambda-scoped.json` (`aws:SourceAccount` + `aws:SourceArn arn:aws:lambda:us-east-1:000000000000:function:*`). `SAME PRINCIPAL, NEW CONDITION`. Floci enforces nothing, so Lab 10 cannot be affected here. On real AWS, confirm Lambda's support for these keys on the execution role before relying on it, because a key the service never sends denies every assumption |
| `usms-ec2-app-role` | **Accepted** | EC2 sends no `aws:SourceArn` when it assumes an instance profile's role, so the condition cannot be written. Compensating controls: IMDSv2 required with hop limit 1 (Step 11); the role is reachable only through `usms-ec2-app-profile`; `USMSDeployBase` explicitly denies `iam:PassRole` to `ec2.amazonaws.com` |

The before-documents are kept as the undo
(`outputs/lab-09-ex2-<role>-trust-before.json`).

**The audit now reports decisions.**
[`configs/usms-iam-accepted-findings.tsv`](../../configs/usms-iam-accepted-findings.tsv)
is committed, one line per accepted finding: role, finding prefix, reason.
An entry with an empty reason is ignored, so nothing can be accepted
silently. `usms-iam-audit.sh` reads it and prints the reason under each
`ACCEPTED` line.

Beyond the guide's three, it accepts four roles the guide does not cover:
- `usms-eks-node-role` (the EC2 reason)
- `usms-eks-cluster-role` (Lab 07-08 scope)
- `usms-backup-operator-role` (a Lab 01 exercise role with no function;
  apply the Lambda conditions when it gets one)
- the service-linked role (AWS owns its trust policy)

```text
with configs/usms-iam-accepted-findings.tsv :  HIGH=0  MED=35  ACCEPTED=5  roles=13   exit 0
with no accepted-findings file (/dev/null)  :  HIGH=5  MED=35  ACCEPTED=0  roles=13   exit 1
```

An unaccepted HIGH still makes the audit exit 1. The IAM audit's history:
- **Step 5:** `HIGH=8 MED=33` (10 roles)
- **After Steps 7-8:** `HIGH=7` (12 roles)
- **After this exercise:** `HIGH=0 ACCEPTED=5` (13 roles)

---

## Exercise 3 - Problem solving: the exposure report

[`scripts/utilities/usms-exposure-report.sh`](../../scripts/utilities/usms-exposure-report.sh)
classifies every network interface in `usms-vpc` from three computed facts:
1. does the subnet's route table send `0.0.0.0/0` to an `igw-`
2. does the interface have a public address
3. does any of its groups admit `0.0.0.0/0`

Names, tags and descriptions are used only to *label* a line, never to
decide it.

```text
enrolment task f97bf7ec      10.0.3.10    -           ISOLATED     no igw route on subnet-cbeebb5f
enrolment task a89bed71      10.0.3.11    -           ISOLATED     no igw route on subnet-cbeebb5f
usms-db-02                   172.19.0.3   127.0.0.1   ISOLATED     no igw route on subnet-2b5f6829  [127.0.0.1 = Floci placeholder]
usms-web-02                  172.19.0.4   127.0.0.1   EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0  [127.0.0.1 = Floci placeholder]
usms-web-01                  172.19.0.5   127.0.0.1   EXPOSED      igw route + sg allows 443,80 from 0.0.0.0/0  [127.0.0.1 = Floci placeholder]
usms-db-01                   172.19.0.7   127.0.0.1   ISOLATED     no igw route on subnet-cbeebb5f  [127.0.0.1 = Floci placeholder]

interfaces=6  EXPOSED=2  ISOLATED=4
not listed: usms-nat and the load balancer - Floci 2.2.0 gives neither a network interface
IDENTICAL from ~ and from labs/lab-09-security/
outputs/lab-09-exposure.json valid JSON
```

**The constraints:**
- **Runs from any directory, with no arguments:** `REPO_ROOT` comes from
  `${BASH_SOURCE[0]}`, and the output was byte-identical from the
  repository, `~` and `labs/lab-09-security/`.
- **No hard-coded IDs.**
- **The awkward cases:**
  - a group missing from the VPC-filtered cache is fetched by ID
  - an interface with no description falls back to its ID and type
  - a subnet with no explicit association uses the VPC's main route table
    (and says so)
  - an interface attached to a terminated instance is labelled
    `(terminated, eni lingers)`
- **`set -uo pipefail` without `-e`, with a comment:** it is a report. One
  unreadable interface or group must produce a line saying so, not abort
  the run half-way.
- **It also writes** `outputs/lab-09-exposure.json`.
- **Unchanged by Exercise 1:** the verdict reads only ingress, routes and
  addresses, and Exercise 1 changed egress.

**The public interface with no ingress rule at all** is classified
**`ADDRESSABLE`**, not `EXPOSED`. The internet can address it and has a
route, so packets arrive. But a security group admits nothing by default,
so every new inbound connection is dropped, and replies to connections the
interface *initiated* are allowed only because security groups are stateful.
That is a NAT gateway's whole job. Calling it `EXPOSED` would rank it with
a web server that accepts connections.

Calling it `ISOLATED` would hide that **one added rule** makes it reachable.
`ADDRESSABLE` says exactly that: reachable in principle, closed in practice,
one rule away. On this build the case does not appear, because Floci gives
the NAT gateway no interface.

Floci's addresses are worth stating:
- interfaces have no public association
- instances report the placeholder `127.0.0.1`

The report treats the placeholder as an address (the verdicts are what real
AWS would give, since `usms-web-01` has the Lab 03 Elastic IP) and flags it
on every line.

---

## Exercise 4 - Challenge: the security review, for the information security officer

> **To:** Information Security Officer **From:** Platform team
> **Subject:** USMS security review, the four questions

### 1. The second front door

`usms-web-01` is the web server Lab 03 built before there was a load
balancer. `usms-app-sg` admits tcp/80 and tcp/443 from the whole internet,
and the instance has a public Elastic IP in a public subnet. The exposure
report classes it `EXPOSED` (Exercise 3).

Since then, Lab 05 put the enrolment API behind `usms-enrolment-alb`. That
load balancer is the front door we designed, reviewed and can attach
protections to. The web server's own public port is a second door that
bypasses all of it.

**Should it still be reachable?** No. Moving it behind the load balancer
needs:
- a target group for the web tier (`target-type instance`, port 80,
  health check `/`)
- a listener rule on the existing HTTP listener (for example host
  `www.usms...` or path `/portal/*`) forwarding to that target group
- `usms-app-sg`'s ingress changed from `0.0.0.0/0` to `usms-alb-sg` on 80
- the Elastic IP released

**What would break:**
- anything that reaches the server by its public IP or DNS name
  (bookmarks, monitoring, an integration partner) until it is pointed at
  the load balancer
- SSH via the public address. It is already restricted to the bastion
  group (Step 16), so nothing legitimate breaks there

**The other side, in two sentences.** The web tier is a static portal with
no student data on it, and a second ALB rule plus target group adds a hop,
an hour's work and a small LCU cost to protect something that has nothing
to steal. But the instance carries `usms-ec2-app-role`, which can read
**and write** every transcript. So "nothing to steal" is false the moment
the server is compromised, and that settles it.

The sequence, written and **not run**:

```text
1. aws elbv2 create-target-group --name usms-web-tg --protocol HTTP --port 80 \
     --vpc-id vpc-1441470d --target-type instance --health-check-path /
2. aws elbv2 register-targets --target-group-arn <usms-web-tg> --targets Id=i-f66018e669eb1530a
3. aws elbv2 create-rule --listener-arn <usms-enrolment-alb HTTP:80> --priority 20 \
     --conditions Field=path-pattern,Values='/portal/*' --actions Type=forward,TargetGroupArn=<usms-web-tg>
4. aws ec2 authorize-security-group-ingress --group-id sg-38365af9db7017f8b \
     --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=sg-8f6bfa2a32f0f9d39}]'
   (and add tcp/80 -> usms-app-sg to usms-alb-sg's EGRESS, written in Step 14)
5. aws ec2 revoke-security-group-ingress --group-id sg-38365af9db7017f8b \
     --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]'
6. aws ec2 revoke-security-group-ingress --group-id sg-38365af9db7017f8b \
     --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]'
7. aws ec2 disassociate-address --association-id <usms-web-eip association>
   aws ec2 release-address --allocation-id <USMS_WEB_EIP_ALLOC>
```

!!! danger "Step 5 - revoke HTTP from the internet"
    **What will be deleted:** tcp/80 from `0.0.0.0/0` on `usms-app-sg`.
    **What depends on it:** every client reaching the web server by its own address.
    **Reversible?** Yes: re-authorize the same rule.
    **Effect on later labs:** none, provided step 4 was done first.

!!! danger "Step 6 - revoke HTTPS from the internet"
    **What will be deleted:** tcp/443 from `0.0.0.0/0` on `usms-app-sg`.
    **What depends on it:** HTTPS clients of the web server directly.
    **Reversible?** Yes: re-authorize the same rule.
    **Effect on later labs:** none; TLS moves to the load balancer's listener.

!!! danger "Step 7 - release the Elastic IP"
    **What will be deleted:** the web server's public address, permanently.
    **What depends on it:** any DNS record or allow-list naming that address.
    **Reversible?** **No.** A released address is gone; a new one will differ.
    **Effect on later labs:** Lab 03's `USMS_WEB_PUBLIC_IP` becomes stale; regenerate `configs/lab-03.env`.

### 2. What restricting egress actually bought

We replaced "may connect anywhere on anything" with written rules on four
groups (Steps 13-15, Exercise 1).

**Three attacker behaviours this now prevents:**
1. **Exfiltration from the database over any protocol but HTTPS.** A
   compromised `usms-db-01` can no longer open SSH, PostgreSQL, SMTP, FTP
   or plain HTTP to an attacker's server. Only tcp/443 out remains.
2. **DNS tunnelling to an attacker's name server.** The web tier may send
   DNS only to the VPC resolver at `10.0.0.2`. The data tier has no DNS at
   all.
3. **A compromised load balancer, or anything wearing its group, reaching
   anything except the enrolment tasks.** `usms-alb-sg` may initiate only
   tcp/80 to `usms-enrolment-sg`.

**Two it does not:**
1. **Exfiltration by HTTPS POST to any internet server.** tcp/443 to
   `0.0.0.0/0` remains on the database, the tasks and the web tier, and
   most modern exfiltration uses exactly that. Closing it needs
   hostname-based filtering: **AWS Network Firewall** with a domain
   allow-list, about **USD 0.395 per firewall-endpoint hour plus USD 0.065
   per GB** in us-east-1 (aws.amazon.com/network-firewall/pricing). That is
   roughly USD 290 a month per AZ before traffic.
2. **Abuse of the permissions a workload legitimately has.** An attacker on
   the web server can read every transcript through its own role and send
   it to an S3 bucket *they* own, through the very S3 prefix list we
   allowed. Stopping that needs a **VPC endpoint policy** on
   `usms-s3-endpoint` restricted to our bucket (no extra charge for gateway
   endpoints; aws.amazon.com/vpc/pricing), plus the bucket policy drafted in
   Exercise 5.

What we bought is a narrower set of exits and an end to the "allow
everything" default. We did not buy data-loss prevention.

### 3. Who can read and write a transcript today

I derived this from the identity inventory, `policies/`, and
`get-account-authorization-details`, which lists every user, group, role and
policy in one call. On this build that call works; the guide expected it
not to. Users and groups were checked as well as roles.

| Principal | How it gets access | Read | Write | Granting document |
|---|---|---|---|---|
| `usms-ec2-app-role` | EC2 instance profile on `usms-web-01` | yes | **yes** (Put, Delete) | `USMSStudentDataReadWrite` |
| `usms-ecs-task-role` | Task role of `usms-enrolment-svc` | yes | **yes** | `USMSStudentDataReadWrite` |
| `usms-eks-node-role` | Every pod on every EKS node (Lab 07) | yes | **yes** | `USMSStudentDataReadWrite` |
| `usms-transcripts-reader-role` | Task role for future reporting (this lab) | yes | no (explicit Deny) | `USMSStudentDataReadOnly` |
| `usms-lambda-exec-role` | Lambda execution role (Lab 10) | yes | no | `USMSLambdaBasic` |
| `usms-backup-operator-role` | Lambda (Lab 01 exercise), `us-east-1` only | yes | no | `USMSBackupOperator` |
| `usms-analytics-partner-role` | Assumed by `usms-audit-01`, sessions of 30 min or less | `reports/*` only | no | `USMSAnalyticsPartnerRead` |
| **`usms-audit-01`, via group `usms-auditors`** | AWS managed `ReadOnlyAccess`: `s3:Get*` on `*` | **yes, every transcript** | no | `arn:aws:iam::aws:policy/ReadOnlyAccess` |
| `usms-developer-role`, groups `usms-developers` / `usms-admins` / `usms-qa` | `s3:List*` on `*` | lists object **names** (student IDs), not contents | no | `USMSDeveloperBase` |
| The account root | Everything, always | yes | yes | (root) |

**Two findings for the committee:**
- **An auditor can read every student's record.** `ReadOnlyAccess` is
  read-only for *configuration*, but it also reads *data*. The auditors
  should have `SecurityAudit` or a scoped policy instead.
- **Every pod on the EKS cluster can write transcripts,** because the node
  role carries the read-write policy (Lab 07 left IRSA unfinished).

**How I know the list is complete.** On real AWS the authoritative answer
comes from the **resource's side**: **IAM Access Analyzer** (for access from
outside the account) and the **`s3:GetBucketPolicy` / Access Analyzer for
S3** view, combined with `get-account-authorization-details` for everything
inside the account. This course cannot run the resource-side half: the
bucket does not exist yet, so it has no bucket policy and nothing to
analyse. Floci also authorises nothing, so no access test can confirm a
denial.

What I did instead:
1. **Enumerated every principal in the account** in one call
   (`get-account-authorization-details`), so none was missed by listing
   roles only.
2. **Scanned every Allow statement** for an `s3:` action whose resource is
   the bucket, an object path, or `*`.
3. **Drafted the bucket policy** (Exercise 5), whose `NotPrincipal` Deny
   would make the table *enforced*, not just observed, once applied.

The list is complete **for identity policies in this account**. The bucket
policy is what turns "complete as far as we can read" into "nobody else,
by construction".

### 4. Knowing when any of this changes

Everything in this review is **preventive**; none of it tells us when
someone tries, or when a rule quietly changes. The **detective** half:

| Service | Reports | Cost (us-east-1, list price) |
|---|---|---|
| **AWS CloudTrail** | Every API call: who changed a group, attached a policy, assumed a role, from where | First copy of management events to S3 **free**; data events (S3 object reads) USD 0.10 per 100,000 (aws.amazon.com/cloudtrail/pricing) |
| **AWS Config** + managed rules (`restricted-ssh`, `iam-policy-no-statements-with-admin-access`, ...) | A security group or policy that drifts from the rules, with history | About USD 0.003 per configuration item, plus USD 0.001 per rule evaluation (aws.amazon.com/config/pricing) |
| **IAM Access Analyzer** (external access) | A bucket or role newly shared outside the account | **Free** for external-access analyzers (aws.amazon.com/iam/access-analyzer/pricing) |
| **Amazon GuardDuty** | Unusual `AssumeRole` patterns, credentials used from unexpected places, instance credential exfiltration | 30-day free trial, then per million events analysed (aws.amazon.com/guardduty/pricing) |
| **CloudWatch metric filters + alarms on CloudTrail** | A page within minutes of `AuthorizeSecurityGroupIngress` from `0.0.0.0/0`, `AttachRolePolicy`, or a root login | USD 0.10 per alarm per month (aws.amazon.com/cloudwatch/pricing) |

The free combination (CloudTrail management events, Access Analyzer, a
handful of alarms) costs a few dollars a month and covers group changes,
policy attachments and assumed roles.

**The morning after an incident, in this order:**
1. **CloudTrail for the affected principal:** every `AssumeRole`,
   `GetObject` (if data events are on) and IAM or EC2 change, and the
   source IP of each.
2. **Every security group and IAM change in the window:** did a rule or a
   trust policy change just before?
3. **GuardDuty findings** for the instance or role involved.
4. **Access Analyzer:** did anything become reachable from outside the
   account?
5. **The S3 access log or data events** for `usms-student-data`: which
   objects, read by whom.

Each costs nothing to read if it was switched on before the incident, and
cannot be recovered afterwards if it was not.

---

## Exercise 5 - Integration: the bucket policy the S3 configuration lab will apply

[`scripts/utilities/usms-bucket-policy-draft.sh`](../../scripts/utilities/usms-bucket-policy-draft.sh)
(`outputs/lab-09-ex5.txt`) does the following:

1. **Reads the bucket ARN out of `USMSStudentDataReadWrite` v1's
   `Resource`.** The name comes from that ARN with a shell parameter
   expansion, `BUCKET="${BUCKET_ARN##*:::}"` ("delete the longest prefix
   ending in `:::`"), commented in the script. The bucket name is never
   typed.
2. **Re-reads the inventory and finds every role with an Allow for any
   `s3:` action** on the bucket, an object path, or `*`. It found **eight**,
   not the three the guide expects, because six policies name the bucket.
3. **Writes `outputs/lab-09-bucket-policy-draft.json`** with Python:
   - one `Allow` per role, limited to that role's existing actions and
     resources (the analytics partner keeps `reports/*` only)
   - `DenyInsecureTransport`: `Principal "*"`, `aws:SecureTransport false`
   - `DenyEveryoneElse`: a `NotPrincipal` of the eight roles plus
     `arn:aws:iam::000000000000:root`
4. **Checks it mechanically** and writes the readiness file.

```text
outputs/lab-09-bucket-policy-draft.json: valid JSON
  ok   AllowUsmsAnalyticsPartnerRole        principal 1 ARN(s)
  ok   AllowUsmsBackupOperatorRole          principal 1 ARN(s)
  ok   AllowUsmsDeveloperRole               principal 1 ARN(s)
  ok   AllowUsmsEc2AppRole                  principal 1 ARN(s)
  ok   AllowUsmsEcsTaskRole                 principal 1 ARN(s)
  ok   AllowUsmsEksNodeRole                 principal 1 ARN(s)
  ok   AllowUsmsLambdaExecRole              principal 1 ARN(s)
  ok   AllowUsmsTranscriptsReaderRole       principal 1 ARN(s)
  ok   DenyInsecureTransport                principal *
  ok   DenyEveryoneElse                     principal 9 ARN(s)
  ok   bucket ARN appears with and without /*
bucket_name        usms-student-data   (read from USMSStudentDataReadWrite v1's Resource, not typed)
granting_policies  USMSAnalyticsPartnerRead USMSBackupOperator USMSDeveloperBase USMSLambdaBasic USMSStudentDataReadOnly USMSStudentDataReadWrite
principal_count    8 roles granted an s3: action on the bucket (+ the account root in the NotPrincipal)
bucket_exists      no
```

`configs/lab-09.env` now has **17** exports, with `USMS_BUCKET_POLICY_DRAFT`
added by `write-lab-09-env.sh` once the draft exists. The draft and the
readiness file are git-ignored (`.gitignore:8:outputs/*`). Nothing was
applied, and the script works with or without the bucket.

**Two consequences of applying it** (for the S3 configuration lab):
- **The `NotPrincipal` Deny lists roles, not users.** `usms-audit-01`'s
  `ReadOnlyAccess` reads (Exercise 4) would be **blocked**, which is the
  intent.
- **`NotPrincipal` with `Deny` is fragile with assumed-role sessions.** AWS
  evaluates the session ARN (`arn:aws:sts::...:assumed-role/...`), not just
  the role ARN. The production version should use `"Principal": "*"` with a
  `StringNotLike` condition on `aws:PrincipalArn`. That fails this
  exercise's "every Principal is an ARN" check, which is why the draft uses
  `NotPrincipal`.

**The two Denies, contrasted.** `USMSStudentDataReadOnly`'s Deny is an
*identity* policy, so it can stop only the principal it is attached to
(`usms-transcripts-reader-role`), and only in this account. The bucket
policy's Deny is a *resource* policy, so it applies to every request made
to the bucket by anyone, whatever their own policies say. Only the bucket
policy reaches a principal in **another account**. IAM never consults our
identity policies for their requests, but it always consults the policy on
the resource they are asking for.
