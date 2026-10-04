# Lab 03 - Amazon EC2 - my notes

## The sentence Step 11 asks for

`USMSStudentDataReadWrite` grants access to `arn:aws:s3:::usms-student-data`,
a bucket that does not exist until Lab 4. That is valid, because an IAM
policy is a statement about ARNs, not a reference to an object, so the
permission sits dormant until something appears at that ARN. The moment Lab 4
runs `create-bucket`, `usms-web-01` can write transcripts with no access key
anywhere on the machine.

## What I observed, and what I only reasoned about

Observed on Floci 1.5.34:
- instances placed in specific subnets with specific security groups
- the instance -> profile -> role -> policy chain
- user data delivered to the instance byte-identical, and *executed* (nginx
  installed, pages written, one page served through a local port-forward)
- the root volume deleted at terminate (`DeleteOnTermination=True`)
- the Elastic IP association surviving a stop/start
- the control plane surviving an emulator restart

Reasoned about, not observed:
- an Elastic IP reachable from the internet
- IMDS handing the instance credentials
- a security group refusing a packet
- the auto-assigned address being released on stop (Floci kept showing
  `127.0.0.1`)
- `InvalidVolume.ZoneMismatch` (Floci has no `AttachVolume` at all)
- a snapshot-backed AMI (Floci has no `CreateImage`)
- any of the cost

---

# Review Questions

### 1. Five inputs to one `run-instances`, and which failures are silent

Step 8's call consumed five things built elsewhere. Each can go wrong in two
ways: it can *not exist*, or it can *exist and be the wrong one*. The first
way is almost always loud. The second is almost always silent.

**The subnet (Lab 2).** If `$USMS_PUBLIC_SUBNET_A` is empty or stale, the
call fails immediately with `MissingParameter` or `InvalidSubnetID.NotFound`.
If it holds the *private* subnet's ID, the launch succeeds: an instance with
no public address, behind a route table with no internet gateway, and nothing
anywhere reports an error. You find out when the portal does not load. A
subnet that exists but lacks auto-assign is silent in the same way.

**The security group (Lab 2).** A nonexistent ID fails immediately with
`InvalidGroup.NotFound`. *Omitting* `SecurityGroupIds` is silent: the
instance gets the VPC's `default` group, which allows nothing from the
internet. A valid but wrong group (say `usms-db-sg`) is silent too, and that
is the most dangerous case, because the instance runs and the port is simply
closed.

**The instance profile (Lab 1).** A nonexistent name fails immediately with
`InvalidParameterValue: iamInstanceProfile.name`. Omitting the profile is
silent until Lab 4, when the first S3 call on the instance fails with
`NoCredentialsError` or `Unable to locate credentials`. That is several labs
and several weeks away from the mistake that caused it. A profile whose role
lacks the right policy gives `AccessDenied` at that point instead.

**The key pair (this lab).** A nonexistent name fails immediately with
`InvalidKeyPair.NotFound`. Omitting it is silent: the instance runs, and
nobody can ever SSH in, because a key can only be injected at first boot.

**The user-data script (this lab).** Every failure here is silent to the API,
because `run-instances` only stores the blob:
- A missing script means an instance that never installs nginx.
- A syntax error fails at boot, into a log on a machine you may not be able
  to log in to.
- An unquoted heredoc in Step 6 stores your laptop's `date` and empty
  variables. The script is wrong, but it is valid.

That is why Step 12 proves the script byte-for-byte and why `bash -n` runs
before launch. In this lab, the proof had to be made on the instance, because
Floci does not return the attribute.

Pattern: identifiers are validated at call time, and *intent* never is. Every
silent failure above is a correct-looking value that means the wrong thing.

### 2. A policy for a bucket that does not exist

IAM policies are evaluated against the ARN in a request, not against an
inventory of resources. A policy that names `arn:aws:s3:::usms-student-data`
is a rule that says "requests about this name are allowed". It is a perfectly
well-formed rule whether or not anything currently carries that name, in the
same way a door rule can name a room that has not been built yet. So
`USMSStudentDataReadWrite` is valid rather than broken, and IAM accepted it
in Lab 1 without complaint.

What it means for the instance today is nothing usable. `usms-web-01` holds
credentials (on real AWS) that would let it `PutObject` into
`usms-student-data`, but every such request fails because the bucket is not
there. `head-bucket` returns 404 Not Found, not 403 Access Denied, and that
difference is the evidence that the permission is in place and only the
object is missing (`outputs/lab-03-s3-readiness.txt`).

At the moment Lab 4 runs `create-bucket usms-student-data`, the ARN starts
resolving to a real bucket. The same instance, with the same role and the
same unchanged policy document, can then immediately `ListBucket`, `GetObject`,
`PutObject` and `DeleteObject` under it, and still cannot `DeleteBucket`
because of the explicit deny. Nothing about IAM changes, and nothing about
the instance changes. The credentials it uses were never stored on its disk:
IMDS issues them, short-lived, from the role. That is the connection running
through Labs 1, 3 and 4. Identity was designed first, compute was given that
identity without a single secret, and the data store simply appears at an
address the identity was already allowed to use.

It also has a sharp edge. Because S3 bucket names are global, if *someone
else* created `usms-student-data` first, this policy would grant access to
their bucket. That is one reason to scope policies with conditions such as
`aws:ResourceAccount` on real accounts.

### 3. "Restarting redeploys it" - why not, and what does work

User data does not run on every boot. cloud-init runs it once per instance,
at first boot, and records that it has done so in `/var/lib/cloud/instance/`,
keyed to the instance ID. A reboot or a stop/start leaves that record in
place, so the script is skipped. A deployment placed in user data therefore
happens exactly once, when the instance is born, and "restart the instance"
redeploys nothing. You keep the old code and assume you have the new code.
Forcing cloud-init to run scripts on every boot is possible, but it turns
every reboot, including an unplanned one, into an unreviewed deployment.

Two approaches that do work:

1. **Immutable deployment.** Build a new AMI per release (the golden image
   from Step 20, built by a pipeline), then *replace* instances rather than
   restart them: launch from the new image and retire the old instances. An
   Auto Scaling group's instance refresh does this automatically, which is
   where Lab 8 is heading. Rolling back means launching from the previous
   image.
2. **A deployment agent pulls the release.** Use user data only to install
   an agent or a systemd unit that runs on *every* boot, or on demand, and
   fetches the current release, for example from S3 or a package repository.
   AWS-native versions of this are CodeDeploy and SSM Run Command / State
   Manager. Deployment becomes an explicit, logged action separate from
   machine creation. The instance's lifecycle and the application's
   lifecycle stop being the same thing, which is what the colleague actually
   wanted.

### 4. Auto-assigned public IP versus Elastic IP

| | Auto-assigned (Step 10) | Elastic IP (Step 13) |
|---|---|---|
| **Who owns it** | AWS. It is lent to the instance from the regional pool | You. It is allocated to your account as its own resource (`eipalloc-...`) |
| **When it changes** | On every stop/start, and it is gone at terminate | Never, until you release it |
| **What it costs** | USD 0.005/h while assigned (all public IPv4 is billed since February 2024) | USD 0.005/h whether associated or not. An *idle* EIP is still billed, which is the surprise |
| **When the instance stops** | Released immediately. The stopped instance has no public address, and a different one is assigned at start | Stays allocated *and stays associated*. The same address returns with the instance at start |

Floci showed the right-hand column correctly: the association survived
stop/start. It did not show the left-hand behaviour, because the field read
`127.0.0.1` throughout.

**A failover only the Elastic IP makes possible.** Keep a standby
`usms-web-02`, already configured from the golden image, in the other AZ.
When `usms-web-01` fails a health check:

```bash
aws ec2 associate-address --allocation-id "$USMS_WEB_EIP_ALLOC" --instance-id "$WEB02_INSTANCE_ID" --allow-reassociation
```

The address users and DNS already know, `54.178.180.91`, now lands on the
standby within seconds, with no DNS change and no TTL to wait out. With
auto-assigned addresses there is nothing to move: the standby has its own
different address, and every DNS record must change and propagate. During an
outage, that wait is the outage. The EIP is decoupled from the instance
precisely so that the address can outlive any one machine.

### 5. Volumes are zonal, snapshots are regional

An EBS volume is block storage that lives inside one Availability Zone's
storage system, replicated *within* that AZ for durability against disk
failure. It is attached over that AZ's network, which is why it can only
attach to instances in the same AZ. A snapshot is copied into Amazon S3,
which is a regional service that stores data redundantly across multiple
AZs. That is why a snapshot can be restored into a new volume in *any* AZ in
the region, and why moving a volume between AZs means snapshot-then-restore,
never a direct move.

For surviving the loss of an AZ, this means data that exists only on a
volume in AZ a is exactly as available as AZ a. If the AZ goes, the volume
is unreachable however healthy it is, and nothing in AZ b can attach it. To
survive, the data must already exist outside the failed AZ *before* the
failure:
- **Scheduled snapshots** (Data Lifecycle Manager or AWS Backup). The
  recovery point is the last snapshot, so the RPO equals the snapshot
  interval, and recovery means restoring into AZ b.
- **Application-level replication across AZs**, for an RPO near zero:
  database replication, or RDS Multi-AZ (Lab 6 replaces `usms-db-01` with
  exactly this).
- **Storage that is regional by design**, such as S3 for objects or EFS for
  shared files, so that no single AZ holds the only copy.

Compute is the easy half. The golden AMI is regional, so a replacement
instance can launch anywhere. The design question is always where the state
lives.

### 6. Are six configuration checks an adequate substitute?

My position: **adequate as proof that AWS's side is configured correctly,
and not adequate as proof that the application is reachable.** Those are
different claims, and the lab is right only to claim the first.

The six checks are each necessary for reachability, and together they are
sufficient *for the network path*:
- the instance is running
- the subnet routes `0.0.0.0/0` to an internet gateway
- the gateway is attached
- a security group admits tcp/80
- the instance has a public address
- the NACL allows the traffic

Each one is a `describe-*` read of stored configuration, and a mistake in any
of them is a real, common cause of "I can't reach my instance". As a
precondition check they are thorough. They also have one virtue a single
`curl` lacks: when one fails, it names the broken link.

What they cannot detect is **everything on the host itself**:
- no process listening on port 80
- the service crashed or failed to start
- an OS-level firewall (`iptables`, `firewalld`)
- the application listening on the wrong port or only on `127.0.0.1`
- a broken bootstrap

They also cannot detect the class of fault where stored configuration and
enforced behaviour disagree, which is invisible on any emulator that does not
enforce security groups.

This lab produced a live example of the first class. The six checks all
passed for `usms-web-01`, and the user data had genuinely run. Nginx was
installed and the page was written. But `systemctl enable --now nginx` failed
(no systemd in the instance container), so **nothing was listening on port
80**. The configuration said reachable. The machine could not answer until
nginx was started by hand. On real AWS the same symptom would come from a
service that failed to start, and every `describe-*` call would still look
perfect. A real health check has to make the request: a load balancer target
health check, or a `curl` against `/health.json`.

### 7. Every difference between `usms-web-01` and `usms-db-01`

Both are `t3.micro`, from the same AMI, launched with the same key pair. The
differences, and what each one is a property of:

| Difference | `usms-web-01` | `usms-db-01` | Property of |
|---|---|---|---|
| Subnet | `usms-public-subnet-a` | `usms-private-subnet-a` | **Instance** (placement chosen at launch) |
| Availability Zone | `us-east-1a` | `us-east-1a` (same) | **Subnet**. The instance inherits it; a subnet lives in exactly one AZ |
| Private address range | `10.0.1.0/24` | `10.0.3.0/24` | **Subnet** CIDR (the address itself is the instance's ENI) |
| Auto-assigned public address | yes | no | **Subnet** attribute `MapPublicIpOnLaunch`, applied at launch |
| Route to the internet | `0.0.0.0/0 -> igw` | `0.0.0.0/0 -> nat` | **Subnet**, through its route-table association |
| Inbound reachability from the internet | possible | impossible | **Subnet** (routing), regardless of security group |
| Network ACL | default (allow all) | `usms-private-nacl` | **Subnet** |
| Security group | `usms-app-sg` (80/443 from anywhere) | `usms-db-sg` (5432 from app tier) | **Instance** (its network interface) |
| Instance profile / IAM identity | `usms-ec2-app-profile` | none | **Instance** |
| User data | `user-data.sh` (nginx) | none | **Instance** |
| Elastic IP | `usms-web-eip` associated | none | **Instance**, by association. The address itself is a VPC-scoped account resource |
| Data volume | `usms-web-data-vol` (intended) | none | **Instance** attachment, constrained by the **subnet**'s AZ |
| Tags (`Tier=web`/`data`) | | | **Instance** |
| DNS hostname resolution, the `10.0.0.0/16` local route, the internet gateway's existence | same for both | same for both | **VPC**. Shared, so not a difference, but where the "same" comes from |

The pattern that answers the question: what an instance **is** (identity,
firewall, bootstrap, tags) belongs to the instance. Whether the internet can
reach it belongs to the **subnet**, through routing and addressing. What
every instance shares belongs to the **VPC**. That is why moving an instance
between a public and a private subnet changes its exposure completely while
changing nothing about the instance itself.

(On Floci, both instances reported `127.0.0.1` as a public address and a
`172.19.0.x` private address. Those are emulator artefacts, not differences.
The subnet attributes that produce the real values were read back directly.)
