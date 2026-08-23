# Lab 02 - VPC and Networking - my notes

## Understanding checks (Section 14, answered before submitting)

**Can I say what makes a subnet public without using the word "public"?**
A subnet's route table contains a route for `0.0.0.0/0` whose target is an
internet gateway attached to the same VPC. That is the entire definition.
Nothing else - not a name, not a tag, not an auto-assigned address - makes it
true.

**Why does usms-db-sg name a group instead of an address range?**
Because the thing that is actually allowed to connect is "whatever instance is
in usms-app-sg", not "whatever instance happens to hold an address in this
range". The group reference stays correct as the application tier is
rebuilt, rescaled, or re-addressed; a CIDR has to be manually kept in sync
with every one of those changes and silently stops matching the moment it
falls behind.

**What breaks if a custom NACL has no ephemeral-port rule?**
A request that is allowed in gets a reply that is silently dropped on the way
out, because the reply leaves on a high-numbered ephemeral port (1024-65535)
that no rule permits. The connection establishes and then hangs - the single
most confusing symptom in AWS networking, because every allow rule involved
looks correct in isolation.

---

## Step 7 exercises - the reconstructed policy audit

Before building anything, Step 3 asks you to read `USMSDeveloperBase`'s
default version and confirm it actually covers this lab's EC2 actions. It
reads `v3` in this repository (Lab 1 Exercise 5 added `ec2:CreateNatGateway`
and `ec2:AllocateAddress` specifically to prepare for this lab), not the `v2`
the lab text expects - that is expected and explained in `README.md`, problem
1.

Reading the policy properly rather than skimming it turned up a real gap:
`USMSDeveloperBase` v3 is still missing `ec2:ModifySubnetAttribute`,
`ec2:CreateNetworkAcl`, `ec2:CreateNetworkAclEntry`,
`ec2:ReplaceNetworkAclAssociation` and `ec2:CreateVpcEndpoint` - five actions
this lab calls that the policy never grants. Floci does not enforce IAM, so
nothing failed, but a real AWS account would have stopped at Step 8. Full
write-up in `README.md`, problem 2.

---

# Review Questions

### 1. The subnet that looks public but isn't

Nothing about the name `public-subnet`, the tag `Tier=public`, or
`MapPublicIpOnLaunch=true` has any effect on where traffic actually goes.
What is missing is a route: the subnet's route table has no `0.0.0.0/0`
entry pointing at an internet gateway (either the subnet was never associated
with a route table that has one, or no internet gateway was ever attached to
the VPC in the first place). Public IPv4 addressing and internet reachability
are two completely independent mechanisms that happen to usually appear
together, which is exactly what makes this mistake so common: the instance
gets a real public IP, DNS resolves it, and the packets still have nowhere to
go, because routing - not addressing, and certainly not a label - is what
makes a subnet public. Step 13 in this lab exists for precisely this reason:
it reads the *route table*, not the name or the tag, and that is the only
place the answer actually lives.

### 2. Stateful vs stateless, and a specific request path

Trace a browser request to the USMS web server that then queries the
database: `client:ephemeral -> usms-app-sg:80` (inbound), the reply back out
on the same connection, `usms-app-sg -> usms-db-sg:5432` (outbound from the
app tier, inbound to the data tier), and the database's reply back. That is
four direction-crossings across two security groups, and because groups are
stateful, exactly **two** rules cover all four: one inbound 80 on
`usms-app-sg`, one inbound 5432 on `usms-db-sg`. The return traffic in both
directions needs no rule at all.

Put the same path through NACLs instead and the count roughly doubles: an
inbound rule for 80, a matching *ephemeral-port* inbound rule for the reply
leaving the client's side, an inbound 5432 on the private subnet, and its own
ephemeral-port return rule - four rules minimum for the same four
direction-crossings, because nothing is remembered between them.

For a new requirement I reach for a **security group** first, essentially
always: it is stateful (half the rule-writing), it can reference another
group instead of an address range, and it is scoped to exactly the instances
that need it. I reach for a NACL only when the requirement is "no instance
in this subnet should ever be able to do X, regardless of what a future
security-group change permits" - a subnet-wide backstop, not day-to-day
access control. That is exactly why `usms-private-nacl` exists in this lab
even though `usms-db-sg` already does the real access-control work.

### 3. Two ways the CIDR version silently breaks

`usms-db-sg` allows PostgreSQL from `usms-app-sg` rather than from
`10.0.1.0/24`. Two concrete architecture changes that would silently defeat
the CIDR version while leaving the group-referenced version correct:

1. **A second public subnet is added for the app tier and an instance is
   launched into it.** (This lab does exactly that in the Step 11 "Your
   turn" task, `usms-public-subnet-b`.) A CIDR rule scoped to
   `10.0.1.0/24` never covers the new subnet's `10.0.2.0/24` range, so an app
   server there silently cannot reach the database - a false negative that
   looks like a networking bug and takes real time to trace back to a
   forgotten security-group range. The group-referenced rule needs no
   change at all: any instance placed in `usms-app-sg`, in any subnet, in any
   AZ, is covered automatically.
2. **The app tier's subnet is re-addressed** (a VPC redesign, or the subnet
   is deleted and recreated with a different CIDR, which this lab's own
   interlude notes is otherwise irreversible). The CIDR rule now points at
   addresses nothing lives in any more - worse than simply missing, because
   it *looks* like access is still controlled while actually granting nothing
   and denying nothing meaningfully. The group reference is unaffected,
   because it was never about an address range to begin with.

### 4. Why the NAT gateway must sit in the public subnet, and what AZ failure implies

A NAT gateway translates outbound traffic from private instances onto its own
public IP and forwards it to the internet gateway. It can only do that if it
itself has a route to an internet gateway - which only exists in a subnet
whose route table has that `0.0.0.0/0 -> igw` entry, i.e. a public subnet.
Put it in a private subnet and it has no path out either, and the failure is
silent: nothing errors, requests simply never arrive.

A NAT gateway is also zonal - `usms-nat` lives specifically in
`usms-public-subnet-a`, in AZ a. If AZ a becomes unavailable, `usms-nat` goes
with it, and `usms-private-subnet-b` in AZ b loses its outbound path even
though every instance in it, and the AZ itself, is completely healthy. That
is the uncomfortable implication: with a single NAT gateway, the outbound-
internet availability boundary is not "the AZ my instance lives in" but
"the AZ the one NAT gateway happens to live in" - a hidden single point of
failure for a tier that is otherwise built to survive an AZ loss. Production
designs put one NAT gateway per AZ specifically to close this gap, at roughly
double the monthly cost (Exercise 4 works through that trade-off with real
numbers).

### 5. The path with and without the S3 gateway endpoint

**Without the endpoint:** a request from `usms-private-subnet-a` to
`usms-student-data` has to leave the VPC entirely - private subnet -> NAT
gateway -> internet gateway -> the public internet -> S3's public endpoint,
and the reply retraces the same path back in. That path costs NAT
data-processing charges for every byte in both directions (S3 responses,
meaning transcripts, are not small), and for the time the packet is outside
the AWS network boundary it is a marginally larger attack surface, even
though it is still encrypted in transit.

**With the endpoint:** `usms-private-rt` gets a route whose destination is
S3's prefix list and whose target is the gateway endpoint. The same request
now resolves to a route that never involves the NAT gateway or the internet
gateway at all - traffic goes private subnet -> endpoint -> S3, entirely
inside the AWS network, and never touches the public internet.

The path that **leaves the AWS network** is the one without the endpoint. It
costs real money (NAT processing charges on data that never needed to leave
AWS's own network) and represents real, if modest, additional exposure for
no benefit, since S3 and EC2 are in the same region and the endpoint exists
for exactly this reason. (On this Floci build the endpoint object was created
successfully but Floci did not inject the prefix-list route into
`usms-private-rt` - a documented Floci limitation, not a configuration error;
see `README.md`.)

### 6. Why Step 23 looked the VPC up by tag instead of reusing `$VPC_ID`

Reusing `$VPC_ID` after the restart would have proven only that Bash still
remembered a string it was holding before the restart happened - a fact
about the shell's memory, unrelated to whether Floci's state actually
survived. Looking it up fresh, by tag, forces an actual round trip through
the API: the lookup can only succeed if the VPC object genuinely still
exists in Floci's backing store after the container was fully stopped and
restarted. This is exactly the failure mode Lab 1 Step 14 was built to rule
out - that lab's own note is explicit that "the root identity is a constant
that returns identically in memory mode with no disk at all," so a test that
does not force a real lookup proves nothing about persistence, no matter how
convincing it looks. The subnet-count and security-group-count checks
alongside it exist for the same reason at one level down: a VPC that survives
with nothing inside it would pass an ID-only check and still represent
total data loss.

### 7. Confidence without enforcement, and the check verification does and does not catch

Floci does not evaluate security groups, NACLs, or IAM policies against
traffic - every command in this lab reported success regardless of whether
the rule it wrote was correct, meaningfully scoped, or complete. Confidence
has to come from **reading the rule back and reasoning about it**, not from
watching a command succeed: comparing the read-back JSON against the actual
requirement, checking resource type against ARN pattern, and - critically -
checking for the *absence* of something as carefully as its presence (this
lab's own private-rt check, "has NO route to an internet gateway", is a
negative assertion for exactly this reason).

**A mistake this lab's verification would catch:** it caught one for real,
not hypothetically. `usms-db-sg is sourced from usms-app-sg (not a CIDR)`
failed on every run in this repository, because Floci accepts
`authorize-security-group-ingress --ip-permissions` with a `UserIdGroupPairs`
structure, issues a real rule ID, and then never actually stores the group
reference - confirmed with two different submission syntaxes and cross-
checked against `describe-security-group-rules`. The check is specific
enough that it caught a genuine gap between what was requested and what the
backing store actually holds, rather than merely confirming a rule with that
port number exists somewhere.

**A mistake it would not catch:** the check only asserts that port 5432 on
`usms-db-sg` is sourced from a group rather than a CIDR - it says nothing
about whether that group is the *right* one. If the exam-results service's
security group (`usms-exam-sg`, Exercise 4) had accidentally been referenced
on `usms-app-sg`'s port 80 rule instead of its own port 443 rule, every
existence and type check in `verify-lab-02.sh` would still pass, because
nothing in it inspects whether a specific `GroupId` matches the resource it
is semantically supposed to represent versus a different resource of the
same shape. Verification proves structure; it does not prove intent.
