# Lab 02 - VPC and Networking - completed

Full write-up: [lab-02-report.md](lab-02-report.md) - exercises: [exercises.md](exercises.md)

## What exists after this lab

- VPC: `usms-vpc` (`10.0.0.0/16`), DNS support and DNS hostnames both enabled
- Internet gateway: `usms-igw`, attached
- Subnets: `usms-public-subnet-a` (`10.0.1.0/24`, `us-east-1a`),
  `usms-public-subnet-b` (`10.0.2.0/24`, `us-east-1b`),
  `usms-private-subnet-a` (`10.0.3.0/24`, `us-east-1a`),
  `usms-private-subnet-b` (`10.0.4.0/24`, `us-east-1b`),
  `usms-public-subnet-c` (`10.0.5.0/24`, `us-east-1c`, Exercise 1 practice subnet)
- Route tables: `usms-public-rt` (`0.0.0.0/0 -> usms-igw`), `usms-private-rt`
  (`0.0.0.0/0 -> usms-nat`)
- Security groups: `usms-app-sg` (80, 443, 22), `usms-db-sg` (5432, intended
  group-sourced from `usms-app-sg`), `usms-bastion-sg` (Exercise 2),
  `usms-exam-sg` (Exercise 4)
- Network ACL: `usms-private-nacl`, applied to both private subnets
- NAT gateway: `usms-nat`, with Elastic IP `usms-nat-eip`
- VPC endpoint: `usms-s3-endpoint` (gateway, S3)
- `configs/lab-02.env`, `scripts/utilities/verify-lab-02.sh`,
  `scripts/utilities/lab-02-network-report.sh` (Exercise 3),
  `scripts/cleanup/lab-02-cleanup.sh` (never run)

## Reproduce

    source ~/aws-floci-course/configs/course.env
    ./scripts/setup/floci-up.sh
    source ~/aws-floci-course/configs/lab-01.env
    source ~/aws-floci-course/configs/lab-02.env
    ./scripts/utilities/verify-lab-02.sh

Expected: `PASS=32  FAIL=1` - the one failure is a documented Floci
limitation (problem 5 below), not a build error.

## Evidence

The four items Section 9 of the lab names as evidence, plus the three
required checkpoint screenshots.

- [x] Environment resumed under Compose, storage check green - `screenshots/lab02-02-identity-and-vpc.png`
- [x] Checkpoint 5 - public vs. private route table read-back - `screenshots/lab02-06-checkpoint5-public-vs-private.png`
- [x] Checkpoint 8 - NAT gateway and S3 endpoint - `screenshots/lab02-09-checkpoint8-nat-and-endpoint.png`
- [x] Checkpoint 9 - persistence proof - `screenshots/lab02-11-checkpoint9-persistence.png`
- [x] `verify-lab-02.sh` result - `screenshots/lab02-13-verify-lab-02.png`, `screenshots/lab02-16-exercises-4-5.png`

All 16 screenshots are displayed in context in [lab-02-report.md](lab-02-report.md).

## Problems I hit and how I fixed them

### 1. Step 3 expects policy version v2; this repo is already at v3

Step 3's expected output shows `default version: v2`. This account shows
`v3`, correctly - Lab 1 Exercise 5 advanced `USMSDeveloperBase` to v3
specifically to add `ec2:CreateNatGateway` and `ec2:AllocateAddress` ahead of
this lab. Not a discrepancy to fix; the earlier lab's homework paying off as
designed.

### 2. Even at v3, the policy is missing five actions this lab actually uses

Reading the policy properly (as Step 3 asks) rather than skimming it surfaced
a real gap: `ec2:ModifySubnetAttribute` (Step 8), `ec2:CreateNetworkAcl`,
`ec2:CreateNetworkAclEntry`, `ec2:ReplaceNetworkAclAssociation` (Steps 17-18),
and `ec2:CreateVpcEndpoint` (Step 21) are not in `USMSDeveloperBase` at any
version. Floci does not enforce IAM, so every command still succeeded; on
real AWS the developer role would have been denied at Step 8. The lab does
not ask for a policy fix here, so none was made - documented as a finding,
matching the same "read it, don't just run it" discipline Lab 1 taught.

### 3. Step 18's NACL association initially landed on the wrong subnet

The private NACL (4 custom rules + 2 implicit denies, 6 total) was first
associated with `usms-public-subnet-a` instead of `usms-private-subnet-a` -
the reverse of what Step 17-18 build. Caught during a routine state audit,
not by any command failing. Fixed with two `replace-network-acl-association`
calls: the private subnet moved onto the custom NACL, the public subnet moved
back onto the VPC's default. Confirmed correct afterward in
`screenshots/lab02-08-nacl.png` and by `verify-lab-02.sh`'s two NACL checks.

### 4. `describe-network-acls --filters Name=tag:...` does not filter at all

Confirmed Floci limitation. `aws ec2 describe-network-acls --filters
"Name=tag:Name,Values=usms-private-nacl"` returns every network ACL in the
VPC - including two with completely empty `Tags: []` - rather than only the
one actually carrying that tag. Because Step 24's env generation takes
`NetworkAcls[0]`, the unfiltered result silently handed back the *default*
ACL's ID instead of the custom one, and `configs/lab-02.env` shipped a wrong
value that nothing about the command's own output indicated was wrong.

Fixed by resolving the private NACL through **subnet association** instead
(`Name=association.subnet-id,Values=<private-subnet-a>`, filtered to
`IsDefault==false`), which is unaffected by the broken tag filter and was
independently confirmed correct. `scripts/utilities/verify-lab-02.sh`'s own
NACL checks already used the association-based approach and were correct
throughout; only the `configs/lab-02.env` generation step needed the fix.

### 5. Floci cannot store group-to-group security group rules

The most significant limitation found in this lab, and one that touches the
lab's central teaching point in Step 15. `authorize-security-group-ingress
--ip-permissions` with a `UserIdGroupPairs` structure is accepted by Floci
and issues a genuine `SecurityGroupRuleId`, but the group reference is never
actually persisted - confirmed independently three times:

1. `usms-db-sg`'s intended rule from `usms-app-sg` (Step 15), via `file://`.
2. The identical rule retried with inline JSON instead of a file - same
   result, ruling out a `file://`-specific parsing bug.
3. `usms-app-sg`'s bastion-referenced SSH rule (Exercise 2) - a completely
   independent rule, same gap.

`describe-security-groups` and the newer `describe-security-group-rules` API
both agree: the rule exists, with the right protocol and port, and an empty
`UserIdGroupPairs` / no `ReferencedGroupInfo`. `revoke-security-group-ingress
--security-group-rule-ids` compounds it - it reports `{"Return": true}` but
does not remove the rule, confirmed twice (once on the `usms-db-sg` retry,
once on `usms-app-sg`'s old CIDR-based SSH rule in Exercise 2).

No workaround exists within the CLI's `--ip-permissions` mechanism, because
the same failure reproduces across both syntaxes the API accepts for
supplying it. `verify-lab-02.sh`'s `usms-db-sg is sourced from usms-app-sg`
check is left exactly as originally written, with a comment explaining the
expected failure, rather than being patched to hide the gap - the command
that was run matches the lab precisely; the emulator's storage layer is what
falls short. Plain CIDR-based rules (`usms-app-sg`'s 80/443/22, the bastion's
`/32`) store and read back correctly in every case - the bug is specific to
the `UserIdGroupPairs` path, not to security groups generally.

### 6. The private NACL was created with no tags at all

A separate issue from problem 4, caught during the tag audit (Step 22):
`usms-private-nacl` had `Tags: []` despite `--tag-specifications` being
present in the `create-network-acl` call. `git add`/CLI output gave no
warning - a tag audit was the only thing that surfaced it, which is exactly
what Step 22 is for. Fixed with `aws ec2 create-tags`, then re-verified with
a fresh `describe-tags` audit (`screenshots/lab02-10-tag-audit.png` shows the
corrected, complete 13-resource list).

### 7. The S3 gateway endpoint's route did not inject

Documented in the lab itself as a possible Floci limitation (Section 7,
"Floci Limitation - the endpoint route may not appear"), and it occurred
here: `usms-s3-endpoint` was created and reached `available`, but
`describe-route-tables` on `usms-private-rt` shows `PL: None` on both routes
rather than a `pl-...` prefix-list entry. Per the lab's own guidance, this
does not block Lab 4 (Floci routes S3 calls to its own endpoint regardless of
whether the route object exists) - recorded here rather than worked around.

### 8. `aws ec2 wait nat-gateway-available` behaviour

Ran to completion without hanging on this build, unlike the lab's
troubleshooting section anticipates for some Floci versions - noted for
completeness, since the fallback poll loop in Step 19 was not needed here.
