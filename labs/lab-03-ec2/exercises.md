# Lab 03 - Independent Exercises 1-5

Environment: Floci 1.5.34, AWS CLI 2.36.23, account `000000000000`,
`us-east-1`, VPC `vpc-1441470d`. Base AMI `ami-0abcdef1234567891`
(`al2023-ami-2023.0.20230315.0-kernel-6.1-x86_64`). Evidence:
`screenshots/lab03-11-exercises-1-2.png`, `lab03-11b-exercise-2-db-02.png`,
`lab03-12-exercise-3-reachability.png`, `lab03-12b-exercise-3-with-db-02.png`,
`lab03-13-exercise-4-cleanup.png`, `lab03-14-exercise-5-s3-readiness.png`.

`iq` below is the one-line helper used throughout the lab:
`iq() { aws ec2 describe-instances --instance-ids "$1" --query "Reservations[0].Instances[0].$2" --output text; }`

---

## Exercise 1 - A maintenance instance

`usms-admin-01-host`: `t3.micro` in `usms-public-subnet-b`, `usms-app-key`,
`usms-app-sg`, **no instance profile**, tagged `Project=USMS`, `Tier=admin`,
`Lab=03`, `Ephemeral=true`. Long-form command line, waiter rather than
`sleep`, and not recorded in `configs/lab-03.env`.

```bash
ADMIN_INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro --key-name usms-app-key --subnet-id "$USMS_PUBLIC_SUBNET_B" --security-group-ids "$USMS_APP_SG" --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' 'ResourceType=volume,Tags=[{Key=Name,Value=usms-admin-01-host-root},{Key=Project,Value=USMS}]' --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$ADMIN_INSTANCE_ID"

aws ec2 describe-instances --filters "Name=tag:Tier,Values=admin" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,Placement.AvailabilityZone,IamInstanceProfile.Arn]' --output text
```

**Result:** exactly one row:
`usms-admin-01-host  i-c5c064c4786abc867  running  us-east-1b  None`. That is
the expected outcome: one running instance in `us-east-1b`, and `None` is the
absent profile.

---

## Exercise 2 - A self-describing, idempotent bootstrap

[`user-data-db.sh`](user-data-db.sh), 1278 bytes, `bash -n` clean. What it
does, in order:

1. **The guard comes first.** If `/var/log/usms-db-bootstrap.done` exists, it
   prints the marker's contents and `exit 0`s before touching anything.
2. `set -euxo pipefail`, then all output goes to
   `/var/log/usms-db-bootstrap.log`.
3. It installs `postgresql15-server`. Each later step is guarded too:
   `initdb` only if `PG_VERSION` is absent, and `createdb usms` only if
   `pg_database` has no `usms` row. A run interrupted half-way can therefore
   resume safely.
4. It reads its instance ID from IMDSv2.
5. **The marker is written last**, containing `<instance-id> <UTC timestamp>`,
   so it only exists if every step above succeeded.

**Why the outer heredoc must be quoted.** If the script were written with
`cat > ... << 'EOF'`, the quotes stop *your* shell expanding `$MARKER`,
`$(date ...)`, `$TOKEN` and `$INSTANCE_ID` while the file is being written.
Those must be evaluated on the instance at boot. Unquoted, the file would
contain your laptop's date and a set of empty strings. (In this repository
the file was written directly rather than through a heredoc, so every `$` is
literal by construction, which is the same outcome.)

```bash
DB02_INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro --key-name usms-app-key --subnet-id "$USMS_PRIVATE_SUBNET_B" --security-group-ids "$USMS_DB_SG" --user-data file://labs/lab-03-ec2/user-data-db.sh --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-02},{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=03}]' --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$DB02_INSTANCE_ID"

# Step 12's technique, applied on the instance: Floci does not return the userData attribute
docker exec "floci-floci-course-ec2-$DB02_INSTANCE_ID" cat /tmp/user-data.sh | diff - labs/lab-03-ec2/user-data-db.sh && echo "DB USER DATA PROVEN: delivered to usms-db-02 byte-identical"
```

**Result:** `usms-db-02` `i-16073b1702bcb7feb`, `subnet-2b5f6829`
(`usms-private-subnet-b`), `us-east-1b`, `usms-db-sg`, `running`. `diff`
printed nothing: **DB USER DATA PROVEN.**

**It took four launches to get there,** and the reason is a Floci bug, not
the script. Launches 1-3 (`i-aeef1ea7d6773edbd`, `i-59f53969f4087958b`,
`i-5fdb315800873602f`) were terminated by Floci within a second, with
`Bind for 0.0.0.0:2201/2200 failed: port is already allocated`. After an
emulator restart, Floci's SSH-port allocator re-issues ports its running
instance containers still hold. Screenshot 11 shows launch 1 with
`public=None`. Setting `FLOCI_SERVICES_EC2_SSH_PORT_RANGE_START=2210` in
`docker-compose.yml` fixed it, and launch 4 took port 2210.

**What the script did when it ran.** The bootstrap log shows `dnf` installing
PostgreSQL 15, then `postgresql-setup --initdb` failing ("System has not been
booted with systemd"). `set -e` stopped the script, and
`/var/log/usms-db-bootstrap.done` does **not** exist. This is the marker
design working: a partial install is not recorded as complete, so a re-run
would try again rather than skip.

**When could a re-run actually happen, given user data runs once?**
- **Deliberately**, with `cloud-init clean` followed by a reboot, or by
  changing the cloud-init frequency (`scripts-user` set to `always`, or a
  `#cloud-boothook`). After a fix to a broken bootstrap, this is exactly what
  you would do.
- **By hand**, by an operator re-running `/var/lib/cloud/instance/scripts/part-001`
  while debugging.
- **From an AMI.** If a golden image is made from a configured `usms-db-02`,
  the marker file is baked into it. A new instance launched from that image
  would run its own user data, find the marker and exit, and the new
  instance's own setup would never happen. The marker records the *old*
  instance ID, which is how you would notice. A per-instance marker
  (comparing the ID inside it with IMDS) makes it safe.

---

## Exercise 3 - `lab-03-reachability.sh`

[`scripts/utilities/lab-03-reachability.sh`](../../scripts/utilities/lab-03-reachability.sh).
For every running instance tagged `Project=USMS` it prints name, private
address, public address, a verdict and the reason. The verdict is **computed,
never read from a name or tag**:

1. It fetches all instances, all route tables and all security groups once
   each, then filters locally with `jq`. That avoids relying on server-side
   filters, which Lab 2 found Floci partly ignores.
2. It finds the subnet's route table from the explicit association, falling
   back to the VPC's main table, and reads the `0.0.0.0/0` target.
3. It checks whether any attached security group admits tcp/80 (or all
   traffic) from `0.0.0.0/0`.
4. The verdicts:
   - `UNREACHABLE`: no internet-gateway route (the NAT target is printed).
   - `NO-ADDRESS`: an internet-gateway route but no public address.
   - `REACHABLE`: route, address and SG rule all present.
   - `FILTERED`: route and address present, but no SG rule.

Constraints met:
- It runs from any directory (`REPO_ROOT` from `BASH_SOURCE`).
- No hard-coded IDs.
- Nulls default to `-` in `jq`, so they never crash the script.
- It uses `set -uo pipefail` **without `-e`**, a decision explained in the
  script's header comment: a null field or one failed lookup should degrade a
  single line to `-`, not abort the whole report half-way. The three describe
  calls it cannot work without are checked explicitly and `die` on failure.

```bash
(cd ~ && ~/Desktop/aws-floci-course/scripts/utilities/lab-03-reachability.sh)
diff <(cd ~ && ~/Desktop/aws-floci-course/scripts/utilities/lab-03-reachability.sh) <(cd ~/Desktop/aws-floci-course/labs/lab-03-ec2 && ../../scripts/utilities/lab-03-reachability.sh) && echo "IDENTICAL output from ~ and from labs/lab-03-ec2/"
```

**Result:** two runs, because the first happened while `usms-db-02` was still
failing to launch.

```text
# run 1 (screenshot 12) - includes the Exercise 1 admin host
usms-admin-01-host   172.19.0.3   127.0.0.1   REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0
usms-db-01           172.19.0.7   127.0.0.1   UNREACHABLE   no igw route on subnet (0.0.0.0/0 -> nat-dc59b1563c5597c36)
usms-web-01          172.19.0.3   127.0.0.1   REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0
usms-web-02          172.19.0.4   127.0.0.1   REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0

# run 2 (screenshot 12b) - after Exercise 4 removed the admin host, with usms-db-02
usms-db-01           172.19.0.7   127.0.0.1   UNREACHABLE   no igw route on subnet (0.0.0.0/0 -> nat-dc59b1563c5597c36)
usms-db-02           172.19.0.3   127.0.0.1   UNREACHABLE   no igw route on subnet (0.0.0.0/0 -> nat-dc59b1563c5597c36)
usms-web-01          172.19.0.8   127.0.0.1   REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0
usms-web-02          172.19.0.4   127.0.0.1   REACHABLE     igw route + sg allows 80/tcp from 0.0.0.0/0
```

Both runs printed `IDENTICAL output from ~ and from labs/lab-03-ec2/`.

**Every verdict is the one real AWS would give.** `usms-public-subnet-b` also
has `MapPublicIpOnLaunch=True`, so the admin host and `usms-web-02` would get
real public addresses there too. The `NO-ADDRESS` state the hint describes
(an internet-gateway route but no public address) does not occur in this
estate on Floci, because Floci gives every instance `127.0.0.1`. On real AWS
it would appear for any instance launched into a public subnet with
auto-assign switched off and no EIP. The script handles it, and
`FILTERED` (address and route, but a closed security group) is handled the
same way.

(Two Floci artefacts are visible in the output. Private addresses are Docker
network addresses, not subnet addresses. `usms-web-01`'s changed from
`172.19.0.3` to `172.19.0.8` between runs because its container was recreated
by an API stop/start; see `README.md`, problem 13.)

---

## Exercise 4 - Right-size and clean up

### The question

> 400 concurrent users at peak, mostly reading. One `t3.micro` at 85% CPU at
> midday, idle overnight. Finance wants a number first. What would you
> change, what would it cost, and what would you delete today?

### Burstable CPU credits, and why 85% sustained is a specific problem

A `t3.micro` has 2 vCPUs but a **baseline of 10% per vCPU**. It earns
**12 CPU credits per hour**, where one credit is one vCPU running at 100% for
one minute, so it can bank up to 288, a day's earnings. Running above the
baseline spends credits. At 85% across both vCPUs it spends
`0.85 x 2 x 60 = 102` credits an hour while earning 12, so it is about
90 credits an hour in deficit.

What happens when the balance runs out depends on the instance's **credit
specification**, which this lab never set:

- **`standard`**: the instance is throttled to its 10% baseline. At midday,
  under the heaviest load, the portal slows to a crawl.
- **`unlimited`**, the default for T3: it keeps running at 85% and **bills
  the surplus** at USD 0.05 per vCPU-hour (Linux). No alarm and no
  throttling, just a larger bill.

The setting is read with `describe-instance-credit-specifications`. **Floci
returns `UnsupportedOperation`** (screenshot 13), so on this build the mode
cannot be observed. Since `run-instances` set no `--credit-specification`,
the instance would be `unlimited` on real AWS.

Worked example, assuming 4 hours a day at 85% and 2% for the other 20:

| | Credits/day |
|---|---|
| Spent at peak: 4 h x 60 x 2 vCPU x 0.85 | 408 |
| Spent off-peak: 20 h x 60 x 2 vCPU x 0.02 | 48 |
| Earned: 24 h x 12 | 288 |
| **Deficit** | **168 credits = 2.8 vCPU-hours** |

2.8 vCPU-hours x USD 0.05 x 30 days is about **USD 4.20/month of surplus
charges**, more than half the instance price again. The overnight idle time
already earns the instance its full daily credit. The problem is the midday
peak, which no amount of idle time can bank enough for.

### Prices (us-east-1, Linux, on-demand, 730 h/month)

Source: AWS pricing pages, Amazon EC2 On-Demand Pricing
(aws.amazon.com/ec2/pricing/on-demand), Burstable performance instances,
unlimited mode (aws.amazon.com/ec2/pricing/on-demand, "T2/T3/T4g Unlimited"),
Elastic Load Balancing pricing (aws.amazon.com/elasticloadbalancing/pricing),
Amazon VPC pricing for public IPv4 (aws.amazon.com/vpc/pricing), and Amazon
EBS pricing (aws.amazon.com/ebs/pricing). These are list prices as published.
Check them before quoting them to finance.

| Item | Rate | Per month |
|---|---|---|
| `t3.micro` | USD 0.0104/h | 7.59 |
| `t3.small` (2 vCPU, 2 GiB, baseline 20%/vCPU, earns 24 credits/h) | USD 0.0208/h | 15.18 |
| T3 unlimited surplus | USD 0.05/vCPU-h | as computed |
| Application Load Balancer | USD 0.0225/h + USD 0.008/LCU-h | 16.43 + ~5.84 (1 LCU) |
| Public IPv4 address (EIP or auto-assigned, in use or idle) | USD 0.005/h | 3.65 |
| `gp3` storage | USD 0.08/GB-month | 0.64 per 8 GiB |

### Options compared

| | Monthly | Peak behaviour | Overnight | Availability |
|---|---|---|---|---|
| **Today**: 1x `t3.micro` unlimited + EIP + 8 GiB | 7.59 + ~4.20 + 3.65 + 0.64 ≈ **USD 16.08** | Runs, but billed surplus | Idle, paid | One AZ, one instance |
| **Scale up**: 1x `t3.small` + EIP + 8 GiB | 15.18 + 3.65 + 0.64 ≈ **USD 19.47** | Earns 576 credits a day vs 456 spent, so no surplus and no throttle | Idle, paid | One AZ, one instance |
| **Scale out**: ALB + 2x `t3.micro` (one per AZ) + 2x 8 GiB, no EIP needed | 22.27 + 15.18 + 1.28 ≈ **USD 38.73** | Load split, ~42% each: 2 x 4 h x 60 x 2 x 0.42 ≈ 403 + off-peak, inside 2 x 288 earned | Can scale in to 1 overnight with a scheduled action | Survives an AZ loss |

### Recommendation

**Scale up to a `t3.small` now, and scale out when availability, not cost, is
the requirement.**

- **Scaling up** removes the surplus charge and the throttling risk for about
  USD 3.40 a month more than today's *real* bill. Today's bill is not the
  USD 7.59 sticker price. It also takes one command (`modify-instance-attribute
  --instance-type` while stopped), with no architecture change.
- **Scaling out** costs about twice as much, and most of the increase is the
  load balancer. It buys the thing a single instance can never have: surviving
  the loss of an instance or an AZ. With a scheduled action down to one
  instance overnight, it is also the only option that does anything about the
  idle hours. It belongs with Lab 8's Auto Scaling group, built on
  `usms-web-golden`.
- **For a read-mostly portal**, the cheapest CPU is the request that never
  reaches the instance. Caching static assets (CloudFront or nginx caching)
  could make the `t3.micro` sufficient. It is worth measuring before buying
  either option.

### What to delete today, in dependency order

The rule is the one `lab-03-cleanup.sh` follows: release what depends on
something before the thing it depends on. An EIP must be disassociated before
release, a volume detached before deletion, and an instance terminated before
its subnet can go.

> **DANGER - terminate `usms-admin-01-host`**
> **What will be deleted:** `usms-admin-01-host` (`i-c5c064c4786abc867`) and its root volume (`DeleteOnTermination=True`).
> **What depends on it:** nothing; it is the Exercise 1 practice host, tagged `Ephemeral=true`, absent from `configs/lab-03.env`.
> **Reversible?** No. A terminated instance cannot be restarted.
> **Effect on later labs:** none. It is in Section 16's CLEAN UP column.

```bash
aws ec2 terminate-instances --instance-ids "$ADMIN_INSTANCE_ID" --query 'TerminatingInstances[0].[InstanceId,PreviousState.Name,CurrentState.Name]' --output text
aws ec2 wait instance-terminated --instance-ids "$ADMIN_INSTANCE_ID"
```

> **DANGER - delete orphaned volumes**
> **What will be deleted:** every EBS volume in state `available` *except* `usms-web-data-vol` (which is `available` only because Floci cannot attach it, and is on the KEEP list).
> **What depends on it:** nothing; an `available` volume is attached to nothing.
> **Reversible?** No. Without a snapshot the data is gone.
> **Effect on later labs:** none.

```bash
aws ec2 describe-volumes --query 'Volumes[?State==`available` && !(Tags[?Value==`usms-web-data-vol`])].[VolumeId,Tags[?Key==`Name`]|[0].Value,AvailabilityZone]' --output text
for v in $(aws ec2 describe-volumes --query 'Volumes[?State==`available` && !(Tags[?Value==`usms-web-data-vol`])].VolumeId' --output text); do aws ec2 delete-volume --volume-id "$v" && echo "deleted orphan $v"; done
```

> **DANGER - release unassociated Elastic IPs**
> **What will be deleted:** any Elastic IP with no association that nothing uses.
> **What depends on it:** check first. A NAT gateway's EIP is used by the gateway's network interface, not by an instance.
> **Reversible?** No. A released address is gone, and you will not get the same one back.
> **Effect on later labs:** releasing `usms-web-eip` would break Lab 4; releasing `usms-nat-eip` would break private-subnet egress.

```bash
aws ec2 describe-addresses --query 'Addresses[].[Tags[?Key==`Name`]|[0].Value,PublicIp,AssociationId,InstanceId]' --output text
# release only after confirming: aws ec2 release-address --allocation-id <id>
```

### What actually happened (screenshot 13)

- `describe-instance-credit-specifications` returned `UnsupportedOperation`.
- The `Ephemeral=true` filter returned exactly one instance, the admin host.
  It went `running -> shutting-down`, and the waiter returned at
  `terminated`.
- **No orphaned volumes.** The admin host's root volume was deleted by its
  `DeleteOnTermination=True`, and the Step 15 AZ-test volume had already been
  deleted in that step. The loop deleted nothing.
- **No Elastic IP released.** `usms-web-eip` is associated
  (`eipassoc-efe924b80598eb31d`). `usms-nat-eip` shows `AssociationId None`,
  but it is the NAT gateway's address. Floci does not record that association
  and real AWS does. Releasing it on the strength of a `None` would have been
  wrong, and is the case the "what depends on it" line exists for.
- `verify-lab-03.sh` afterwards: `PASS=32 FAIL=4` at the time. The extra
  failure was not the cleanup's doing. `usms-web-01`'s container had died
  behind a `running` API state (README problem 13). After the API stop/start
  that revived it, the final run is `PASS=33 FAIL=3` (screenshot 09), the
  same as before the cleanup. Nothing named in the KEEP column was touched.

---

## Exercise 5 - The S3 hand-off for Lab 4

### 1. `transcript-upload.sh`

[`transcript-upload.sh`](transcript-upload.sh) runs **on** `usms-web-01`.
`transcript-upload.sh <student-id> <file>` uploads to
`s3://usms-student-data/transcripts/<student-id>/<filename>`.

- It contains, reads and references **no credentials**. The AWS CLI on the
  instance resolves temporary credentials from the instance profile through
  IMDS, and they rotate without the script knowing. A `grep` for
  `access.?key|secret|AKIA|aws_access|aws_secret` finds nothing.
- It validates both arguments. With the wrong number it prints usage and
  exits `2`. It also checks the student ID against `^[A-Za-z0-9-]+$` (which
  stops `../` traversal into another student's prefix) and checks that the
  file exists and is readable.
- `set -euo pipefail` is right here, unlike in the readiness script: any
  failure should stop the upload and return non-zero to the caller.

### 2. The outbound rule nobody wrote

`usms-app-sg`'s egress is `-1 0.0.0.0/0`, the default rule every security
group is created with. **That default egress, together with statefulness, is
what makes the S3 call possible**: the instance's outbound HTTPS to S3 is
allowed by that rule, and the response is admitted automatically because
security groups track connections. No inbound 443 rule is needed for an
outbound call, and adding one would expose the instance without helping the
upload.

### 3. `outputs/lab-03-s3-readiness.txt`

Generated by [`s3-readiness.sh`](s3-readiness.sh), which looks every value up
rather than copying it. It deliberately runs without `-e`, so the expected
`head-bucket` failure is captured rather than aborting the script.

```text
instance            : i-f66018e669eb1530a (usms-web-01)
instance profile    : arn:aws:iam::000000000000:instance-profile/usms-ec2-app-profile
role                : usms-ec2-app-role
attached policy     : USMSStudentDataReadWrite (arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite, default v1)
resources in policy :
                      arn:aws:s3:::usms-student-data
                      arn:aws:s3:::usms-student-data/*
usms-app-sg egress  : -1 0.0.0.0/0;

head-bucket --bucket usms-student-data
  exit code : 254
  output    : 
aws: [ERROR]: An error occurred (404) when calling the HeadBucket operation: Not Found
```

(The CLI's error text begins with a blank line, so it lands under the
`output` label rather than beside it.)

**The failure is the evidence.** `404 Not Found` with exit code 254 means
the bucket does not exist. It does not mean access was denied, which would
be `403`. Every link on the EC2 side is present, and only the object at the
end of the ARN is missing.

**Prediction for Lab 4.** When Lab 4 runs `create-bucket usms-student-data`,
the same `head-bucket` returns exit 0. `usms-web-01` can then
`GetObject`/`PutObject`/`DeleteObject` under `transcripts/` and
`ListBucket` on the bucket, and still cannot `DeleteBucket` (explicit deny).
None of that needs a change to IAM, to the instance or to the first six lines
of this file.

### 4. `USMS_BUCKET_NAME`

Already exported by `configs/lab-01.env` (`USMS_BUCKET_NAME=usms-student-data`).
Not duplicated into `configs/lab-03.env`, so Lab 4 has one source of truth.
Both `transcript-upload.sh` and `s3-readiness.sh` default to it.
