# Lab 03 - Amazon EC2 and the USMS Application - completed

Full write-up: [lab-03-report.md](lab-03-report.md) - exercises: [exercises.md](exercises.md) - review questions: [../../notes/lab-03-notes.md](../../notes/lab-03-notes.md)

## What exists after this lab

- Key pair `usms-app-key`; private key at `outputs/usms-app-key.pem`
  (`chmod 600`, git-ignored, never committed)
- `usms-web-01` (`i-f66018e669eb1530a`): `t3.micro`, `usms-public-subnet-a`,
  `usms-app-sg`, `usms-ec2-app-profile`, user data `user-data.sh`
- `usms-web-02` (`i-80faf975c25aad581`): the same, in `usms-public-subnet-b`
  (Step 18 "Your turn")
- `usms-db-01` (`i-780a8f3d907d26922`): `t3.micro`, `usms-private-subnet-a`,
  `usms-db-sg`, no instance profile
- `usms-db-02` (`i-16073b1702bcb7feb`): `usms-private-subnet-b`, user data
  `user-data-db.sh` (Exercise 2)
- Elastic IP `usms-web-eip` `54.178.180.91`, associated with `usms-web-01`
- `usms-web-data-vol` (`vol-9fd91b6c2914168c7`), 8 GiB `gp3`, `us-east-1a`,
  unattached (problem 6)
- Image `usms-web-golden-20261004` (`ami-902456dfbd32c64ab`), registered
  (problem 8)
- `configs/lab-03.env`, `templates/lab-03-run-instances.json` and
  `-web02.json`, `scripts/utilities/verify-lab-03.sh`,
  `scripts/utilities/write-lab-03-env.sh`,
  `scripts/utilities/lab-03-reachability.sh` (Exercise 3),
  `scripts/cleanup/lab-03-cleanup.sh` (never run)
- In this folder: `user-data.sh`, `user-data-db.sh`, `transcript-upload.sh`,
  `s3-readiness.sh`

## Reproduce

    cd ~/Desktop/aws-floci-course
    source configs/course.env
    ./scripts/setup/floci-up.sh
    source configs/lab-01.env
    source configs/lab-02.env
    source configs/lab-03.env
    ./scripts/utilities/verify-lab-03.sh

Expected: `PASS=33  FAIL=3`. The three failures are Floci limitations
(problems 4 and 6 below), and two of them are named by the lab itself as
known benign failures.

## Evidence

The three checkpoint screenshots Section 14 requires, plus the verification
result.

### 1. Checkpoint 3 - permission chain and `USER DATA PROVEN`

![Instance -> profile -> role -> policy; user data byte-identical on the instance; nginx answering](../../screenshots/lab03-02-checkpoint3-chain-and-userdata.png)

### 2. Checkpoint 5 - two tiers

`usms-db-01` in the private subnet with `usms-db-sg` and no profile. The
private route table (`0.0.0.0/0 -> NAT`) is at the top of
`lab03-08-golden-ami-and-audit.png`.

![usms-db-01 placement, MapPublicIpOnLaunch False, db-sg rules, wiring check](../../screenshots/lab03-05-checkpoint5-two-tiers.png)

### 3. Checkpoint 6 - `PERSISTENCE PROVEN`

![Same instances, subnets and security groups after a full Floci restart](../../screenshots/lab03-07-checkpoint6-persistence.png)

### 4. verify-lab-03.sh

![Verification script showing PASS=33 FAIL=3, all three Floci limitations](../../screenshots/lab03-09-verify-lab-03.png)

All 17 screenshots are displayed in context in
[lab-03-report.md](lab-03-report.md).

## Problems I hit and how I fixed them

### 1. Option A was run when it wasn't needed, and the image can't be removed

In the first pass, `describe-images --owners amazon` returned five seeded
images, but Step 3's Option A (`register-image usms-course-base`) was run
anyway. The pass was rolled back, but `deregister-image` returns
`UnsupportedOperation` on Floci 1.5.34, so `usms-course-base`
(`ami-ce398501cf7e6589f`) is still listed under `--owners self`. It is
untagged and unused. The final build selects the AMI by name
(`Images[?starts_with(Name, 'al2023-ami')]`), because the user-data script
uses `dnf`, which Amazon Linux 2 (`Images[0]`) lacks.

### 2. `delete-key-pair --key-name` reports success and deletes nothing

The rollback's `delete-key-pair --key-name usms-app-key` returned
`{"Return": true}`, and the key was still listed. Deleting by
`--key-pair-id` worked. `lab-03-cleanup.sh` now looks up the ID and deletes
by that, which is equally valid on real AWS. Floci's key is also a dummy:
126 bytes, an all-zero fingerprint, `KeyType None`, and key-pair tags
dropped.

### 3. The `userData` attribute reads back as `None`

`describe-instance-attribute --attribute userData` returns no `UserData`
field, so Step 12's decode-and-diff compared the script with the text `None`
(the first attempt at screenshot 02 showed exactly that). Floci does copy
the script into the instance container as `/tmp/user-data.sh` and run it, so
the proof moved onto the instance:
`docker exec <instance container> cat /tmp/user-data.sh | diff - user-data.sh`.

`verify-lab-03.sh`'s user-data check was changed to match. The original
`test -n "$(... userData ...)"` passes on the literal string `None`, so it
would always pass and prove nothing.

### 4. Every instance's public address is `127.0.0.1`

That includes `usms-db-01` in a subnet with `MapPublicIpOnLaunch=False`.
Floci doesn't clear it on stop and doesn't replace it with an associated
EIP. A launch that Floci failed before creating a container kept the
addresses it would have assigned (`10.0.4.10`, no public address),
which shows Floci computes subnet-correct values and then overwrites them
with the container's. This one limitation is behind the `usms-db-01 has NO
public address` verify failure, the exposure report listing everything as
`true`, and Step 18 never showing the address disappear. In each case the
subnet attribute was read back directly instead.

### 5. Private addresses come from Docker, not the subnet

`172.19.0.x` rather than `10.0.1.x` and `10.0.3.x`, and they change when an
instance's container is recreated: `usms-web-01` moved from `172.19.0.3` to
`172.19.0.8` after an API stop/start (problem 13). On real AWS the private
address comes from the subnet CIDR and is held for the instance's life.

### 6. `AttachVolume` is unsupported, and so are launch-time extra volumes

`attach-volume` returns `UnsupportedOperation` for same-AZ and cross-AZ
volumes alike. A second `--block-device-mappings` entry at launch (tested on
a throwaway untagged instance, `i-da66773801fefca61`, then terminated) is
silently ignored, and only the root volume is created. `usms-web-data-vol`
exists in the right AZ but can't be attached. That causes two verify
failures: "attached", and "DeleteOnTermination is False", which the lab
names as benign. The Step 15 cross-AZ test therefore couldn't show
`ZoneMismatch`, and that outcome is stated for real AWS instead.

### 7. A waiter after an unsupported action hangs for ten minutes

`attach-volume` failed, and the `volume-in-use` waiter in the same block then
polled for its full ten minutes, because nothing would ever change. It was
interrupted. The same thing happened with `create-image` (problem 8): the
waiter got an empty image ID. A waiter checks a state, not whether the
action that should have produced it worked.

### 8. `CreateImage` is unsupported; image tags are dropped

`create-image` returns `UnsupportedOperation`. The golden image was made with
`register-image` instead, as a record with the right name and description
but no snapshot of the configured instance behind it. `--tag-specifications`
on `register-image` was accepted and the tags dropped. `write-lab-03-env.sh`
finds the image by name prefix (`usms-web-golden`), not by `tag:Name`, so
`USMS_WEB_AMI` is still populated.

### 9. Root-volume tags are ignored

`run-instances`' `ResourceType=volume` tag specifications are ignored, so all
root volumes are untagged. `create-tags` on a root volume is stored (it
appears in `describe-tags`) but never shown by `describe-volumes`. The result
is that Step 19's `Project=USMS` volume count is 1 (the data volume), not the
lab's 3-4.

### 10. `start-instances` while `stopping` breaks the instance

The first stop/start sent `start` while the instance was still `stopping`
(the stop waiter hadn't finished). Floci's container start failed
(`Status 304`), the instance settled in `stopped`, and the `instance-running`
waiter could never succeed. Redone with the stop waiter allowed to return
first. Real AWS rejects the early start outright with
`IncorrectInstanceState`.

### 11. A duplicate `usms-db-01` - my mistake, not Floci's

Floci takes about 27 seconds to boot an instance container, and the waiter
polls every 15. The first `instance-running` wait was interrupted, and the
whole launch block was then run again, so `run-instances` ran twice. I
terminated the instance not held in `$DB_INSTANCE_ID` (`i-25384e4e31341c673`)
and retook screenshot 05. Launches are not idempotent unless you pass
`--client-token`.

### 12. Floci's SSH-port allocator collides after a restart

Every instance container publishes an SSH port counting up from 2200. After
an emulator restart Floci forgets which ports are still held, and the next
launch failed with `Bind for 0.0.0.0:2201 failed: port is already allocated`.
Floci marks that instance `terminated` within a second. This happened three
times for `usms-db-02` (`i-aeef1ea7d6773edbd`, `i-59f53969f4087958b`,
`i-5fdb315800873602f`). It was fixed by adding
`FLOCI_SERVICES_EC2_SSH_PORT_RANGE_START: "2210"` (and `_END: "2299"`) to
`docker-compose.yml`. The key name was found in the Floci binary
(`services.ec2.ssh-port-range-start`).

### 13. API says `running`, the container is dead

After the botched start (problem 10), and again after Floci restarts,
`usms-web-01`'s and `usms-db-01`'s containers had exited (code 137) while
`describe-instances` still said `running`. This is how verify first read
`FAIL=4`: the user-data check reads from the instance, so it noticed and the
API did not. An API `stop-instances` + `wait instance-stopped` +
`start-instances` + `wait instance-running` resynchronised them. On Floci,
persistence means the *records* persist. The containers behind them are not
guaranteed.

### 14. No systemd and no IMDS inside the instance

The user-data script ran, but `systemctl enable --now nginx` failed (the
container has no systemd), so nginx was started by hand with `docker exec` to
show it serving. Floci's IMDS proxy also failed to install ("Could not
install IMDS proxy dependencies ... aarch64"), so the portal page's
instance ID and AZ are blank. The same lack of systemd stopped
`user-data-db.sh` at `postgresql-setup --initdb`, and its marker was
correctly never written.

### 15. Unsupported read: credit specifications

`describe-instance-credit-specifications` returns `UnsupportedOperation`, so
Exercise 4's `standard` vs `unlimited` question is answered from AWS's
default for T3 (`unlimited`) rather than from an observation.
