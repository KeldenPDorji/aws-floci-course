# Lab 02 - Independent Exercises 1-5

Environment: Floci 1.5.34, AWS CLI 2.36.23, VPC `vpc-1441470d` (10.0.0.0/16),
account `000000000000`, `us-east-1`. Evidence:
`screenshots/lab02-15-exercises-1-2-3.png`,
`screenshots/lab02-16-exercises-4-5.png`,
`screenshots/lab02-16b-exam-sg-and-assumed-role.png`.

---

## Exercise 1 - A third public subnet

Create `usms-public-subnet-c` in `us-east-1c`, CIDR `10.0.5.0/24`, tagged
consistently, auto-assigning public IPv4, associated with `usms-public-rt`.
Not added to `configs/lab-02.env` per the constraint - practice only.

```bash
PUBLIC_SUBNET_C_ID=$(aws ec2 create-subnet --vpc-id "$USMS_VPC_ID" \
  --cidr-block 10.0.5.0/24 --availability-zone "${AWS_REGION_COURSE}c" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-public-subnet-c},{Key=Project,Value=USMS},{Key=Tier,Value=public},{Key=AZ,Value=c}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "$PUBLIC_SUBNET_C_ID" --map-public-ip-on-launch
aws ec2 associate-route-table --route-table-id "$USMS_PUBLIC_RT" --subnet-id "$PUBLIC_SUBNET_C_ID"
```

**Result:** `PUBLIC_SUBNET_C_ID = subnet-...` (`10.0.5.0/24`, `us-east-1c`).
`describe-route-tables` on `usms-public-rt` went from 2 associations to 3.
Confirmed independently by `lab-02-network-report.sh`'s output:
`usms-public-subnet-c 10.0.5.0/24 us-east-1c PUBLIC via igw-b57737b4`.

---

## Exercise 2 - A bastion security group

Create `usms-bastion-sg` allowing SSH from a single `/32`. Repoint
`usms-app-sg`'s SSH rule from the whole VPC CIDR to the bastion group.

```bash
BASTION_SG_ID=$(aws ec2 create-security-group --group-name usms-bastion-sg \
  --description "Jump host for SSH access to the app tier" --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-bastion-sg},{Key=Project,Value=USMS},{Key=Tier,Value=management}]' \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"203.0.113.10/32","Description":"SSH from the admin workstation"}]}]'

OLD_SSH_RULE_ID=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$USMS_APP_SG" \
  --query "SecurityGroupRules[?FromPort==\`22\` && CidrIpv4=='10.0.0.0/16'].SecurityGroupRuleId | [0]" --output text)
aws ec2 revoke-security-group-ingress --group-id "$USMS_APP_SG" --security-group-rule-ids "$OLD_SSH_RULE_ID"
aws ec2 authorize-security-group-ingress --group-id "$USMS_APP_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$BASTION_SG_ID\",\"Description\":\"SSH from the bastion host only\"}]}]"
```

**Result - and the second confirmed Floci bug.** `revoke-security-group-ingress`
returned `{"Return": true}`, but `describe-security-group-rules` afterward
still showed the original `10.0.0.0/16` port-22 rule alongside the new
bastion-referenced one - two rows in the evidence screenshot,
`SourceCIDR: 10.0.0.0/16` and a second row with everything `None`. Revoke did
not actually remove anything. This is the same emulator gap that broke
`usms-db-sg`'s group reference in the main build (`README.md`, problem 5),
now confirmed a second, independent time: `authorize-security-group-ingress`
with `UserIdGroupPairs` is accepted and issues a real rule ID, but the
reference is never stored, and `revoke-security-group-ingress` reports
success without making the change. The intended state is correct and fully
documented here; the emulator's storage layer is what falls short.

`usms-bastion-sg` itself, which only needed a plain CIDR rule (no
`UserIdGroupPairs`), was created and stored correctly - `describe-security-
group-rules` on it shows the `/32` rule intact. The bug is specific to the
group-reference path, not to security groups in general.

---

## Exercise 3 - `lab-02-network-report.sh`

One line per subnet in `usms-vpc`, classifying `PUBLIC` / `PRIVATE` /
`ISOLATED` strictly from the route table's default route - never from the
subnet's name or tag. Script: `scripts/utilities/lab-02-network-report.sh`.

```bash
./scripts/utilities/lab-02-network-report.sh
```

**Output (before Exercise 5 added the second private subnet):**

```
usms-public-subnet-a  10.0.1.0/24  us-east-1a  PUBLIC via igw-b57737b4
usms-public-subnet-c  10.0.5.0/24  us-east-1c  PUBLIC via igw-b57737b4
usms-private-subnet-a 10.0.3.0/24  us-east-1a  PRIVATE via nat-dc59b1563c5597c36
usms-public-subnet-b  10.0.2.0/24  us-east-1b  PUBLIC via igw-b57737b4
```

Constraints satisfied: runs from any directory (`${BASH_SOURCE[0]}`
resolution, same pattern as every other utility script in this repo); no
resource ID is hard-coded, every value comes from `describe-subnets` /
`describe-route-tables` against the tag-derived VPC; `set -uo pipefail`
without `-e`, deliberately - a subnet with no default route makes the
`?DestinationCidrBlock==...` JMESPath filter return an empty match, and `-e`
would abort the whole loop on that empty result rather than falling through
to the `ISOLATED` branch.

---

## Exercise 4 - Design and defend: the exam-results service

> Staff on campus only (`10.10.0.0/16`, arrives via VPN with campus source
> addresses). Reads the transcripts database. Never reachable from the public
> internet. Needs outbound for security patches.

### Design

**Subnet placement: `usms-private-subnet-a` (or `-b`), not a new subnet.**
The service needs zero inbound reachability from the internet and the same
outbound-patch requirement `usms-db-sg`'s tier already has - that is
precisely what a private subnet behind the NAT gateway provides, and
reusing the existing private tier avoids a third route table, a third NACL,
and a CIDR allocation decision that cannot be undone later.

**Security groups.**

- New: `usms-exam-sg`, one inbound rule - TCP 443 from `10.10.0.0/16`
  ("HTTPS from campus over the VPN, staff only"). No SSH rule; the VPN is the
  management path, not this security group.
- Modified: `usms-db-sg` gets a second inbound rule - TCP 5432 from
  `usms-exam-sg` ("PostgreSQL from the exam-results service"), group-
  referenced for the same reason `usms-app-sg`'s rule is - it stays correct
  if the service is rescaled or moved to the second private subnet.

Every rule justified in one line, as the constraint requires: campus HTTPS
in because that is the only legitimate caller; database access out because
that is the one dependency named in the brief; nothing else, because the
brief names nothing else.

**NACL: no change, and here is why not just an assertion.** `usms-private-
nacl`'s existing rules already permit exactly what this service needs -
inbound 5432 from the VPN range is covered by the existing
`10.0.0.0/16`-scoped rule 100 only if the VPN terminates *inside* the VPC
first (which the brief implies: "traffic arrives with campus source
addresses", i.e. after the VPN endpoint, addresses are already VPC-internal
to the exam service's neighbours). The exam service's own inbound campus
traffic on 443 is a new pattern the current NACL does not cover, but per this
lab's own guidance (Interlude, Step 17), NACLs are a coarse subnet-wide
backstop, not the access-control layer, and this subnet already carries
mixed east-west traffic (`usms-db-sg` on 5432). Adding a NACL rule scoped to
`10.10.0.0/16` on 443 would be defensible defence-in-depth, but is not
required to satisfy the brief and is left for whoever owns the campus VPN's
actual termination point to request explicitly, since only they know the
addresses that will actually arrive.

**Second NAT gateway in AZ b: recommend against, for now, with the trade-off
quantified.**

| | One NAT gateway (current) | Two NAT gateways (one per AZ) |
|---|---|---|
| Base cost | ~USD 32/month (lab1.txt Section 12.2, `$0.045`/hr) | ~USD 64/month |
| Data processing | `$0.045`/GB, either way | Same rate, split across two paths |
| AZ-a failure | Both private subnets lose outbound | Only AZ a's private subnet loses outbound |
| Blast radius today | Whole private tier | Half the private tier |

USMS currently runs one workload class (transcripts + now exam results) with
no stated availability SLA in the brief. Doubling the NAT bill to protect an
outbound-only capability (patching, not the transcripts API itself, which has
no internet-facing component to begin with) is hard to justify without a
concrete downtime cost to weigh it against. Recommendation: keep one NAT
gateway now; revisit the moment a second workload with an actual availability
requirement lands in `usms-private-subnet-b`.

**Cleanup.** `usms-public-subnet-c` from Exercise 1 is scratch and should go.
Deletion order, inside-out, in this lab's four-line danger format:

> **What will be deleted:** `usms-public-subnet-c` and its association with
> `usms-public-rt`.
> **What depends on it:** nothing - it was never added to
> `configs/lab-02.env` or referenced by any other resource, by design.
> **Reversible?** The subnet itself, no (subnet deletion is permanent); the
> CIDR `10.0.5.0/24` can be reallocated to a new subnet identically.
> **Effect on later labs:** none.

```bash
aws ec2 disassociate-route-table --association-id <its rtbassoc-...>
aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_C_ID"
```

### Implementation (the security-group part only, per the constraint)

```bash
EXAM_SG_ID=$(aws ec2 create-security-group --group-name usms-exam-sg \
  --description "USMS exam-results service: campus VPN traffic only, no public exposure" \
  --vpc-id "$USMS_VPC_ID" \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=usms-exam-sg},{Key=Project,Value=USMS},{Key=Tier,Value=app}]' \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$EXAM_SG_ID" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"10.10.0.0/16","Description":"HTTPS from campus over the VPN, staff only"}]}]'
aws ec2 authorize-security-group-ingress --group-id "$USMS_DB_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":5432,\"ToPort\":5432,\"UserIdGroupPairs\":[{\"GroupId\":\"$EXAM_SG_ID\",\"Description\":\"PostgreSQL from the exam-results service\"}]}]"
```

**Result:** `usms-exam-sg` created and stored correctly (`screenshots/lab02-
16b-exam-sg-and-assumed-role.png` shows the CIDR rule intact: port 443,
`10.10.0.0/16`). The `usms-db-sg` group-reference addition hit the same
storage bug documented in Exercise 2 and problem 5 - accepted, issued a rule
ID, group reference not persisted. The design is correct and would work as
specified against real AWS; the gap is entirely in this Floci build's
storage layer.

---

## Exercise 5 - Complete the second Availability Zone

Create `usms-private-subnet-b` (`10.0.4.0/24`, `us-east-1b`) **while holding
`usms-developer-role` credentials**, associate with `usms-private-rt`, attach
`usms-private-nacl`, restore identity, regenerate `configs/lab-02.env`.

```bash
ROLE_ARN="arn:aws:iam::${USMS_ACCOUNT_ID}:role/usms-developer-role"
aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name "lab02-ex5-subnet-b" \
  --profile usms-dev > outputs/lab-02-ex5-assumed-role.json
chmod 600 outputs/lab-02-ex5-assumed-role.json
export AWS_ACCESS_KEY_ID=$(jq -r '.Credentials.AccessKeyId' outputs/lab-02-ex5-assumed-role.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r '.Credentials.SecretAccessKey' outputs/lab-02-ex5-assumed-role.json)
export AWS_SESSION_TOKEN=$(jq -r '.Credentials.SessionToken' outputs/lab-02-ex5-assumed-role.json)

PRIVATE_SUBNET_B_ID=$(aws ec2 create-subnet --vpc-id "$USMS_VPC_ID" \
  --cidr-block 10.0.4.0/24 --availability-zone "${AWS_REGION_COURSE}b" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=usms-private-subnet-b},{Key=Project,Value=USMS},{Key=Tier,Value=private},{Key=AZ,Value=b}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 associate-route-table --route-table-id "$USMS_PRIVATE_RT" --subnet-id "$PRIVATE_SUBNET_B_ID"
NACL_ASSOC_B_ID=$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_B_ID" \
  --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' --output text)
aws ec2 replace-network-acl-association --association-id "$NACL_ASSOC_B_ID" --network-acl-id "$USMS_PRIVATE_NACL"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

**Result - identity proof (`screenshots/lab02-16b-exam-sg-and-assumed-role.png`):**

```
before: arn:aws:sts::000000000000:assumed-role/usms-developer-role/lab02-ex5-subnet-b
after:  arn:aws:iam::000000000000:root
```

`configs/lab-02.env` was regenerated with `USMS_PRIVATE_SUBNET_B` now
resolved (`subnet-2b5f6829`), and the private NACL was looked up by
**subnet association** rather than by tag - because the tag-filter path is
the third confirmed Floci bug in this lab: `describe-network-acls --filters
Name=tag:...` ignores the tag filter entirely and returns every ACL in the
VPC regardless of match, so `[0]` on that result silently grabbed the
default ACL the first time `configs/lab-02.env` was generated (`README.md`,
problem 4). The association-based lookup does not depend on that broken
filter and was confirmed correct independently in `screenshots/lab02-
08-nacl.png`.

**Why restore identity immediately, in one sentence:** `usms-developer-role`
carries `USMSDeveloperBase`'s elevated build permissions and a finite
session, and holding elevated credentials for longer than the one operation
that needs them turns every subsequent command in the terminal into an
unnecessary, unaudited use of a privilege that was only ever supposed to
apply to this one `create-subnet` call.

**Verification, after regenerating `configs/lab-02.env`:**

```
grep -n 'export .*=$\|None' configs/lab-02.env || echo "all values populated"
-> all values populated

./scripts/utilities/verify-lab-02.sh
-> PASS=32  FAIL=1
```

The one remaining failure is the documented `usms-db-sg` group-reference gap
(problem 5) - every other check, including every Lab 02 resource, all
tagging, and all file/Git hygiene checks, passes.
