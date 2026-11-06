# Lab 12 - Independent Exercises 1-5

All five exercises were done on Floci 2.2.0, after the six screenshots. Raw output is in
`outputs/lab-12-ex*.txt`; Exercise 5's evidence document is `outputs/lab-12-release-evidence.md`
(all git-ignored).

**End state, unchanged from the screenshots:**
- the service runs `usms-enrolment:4`, with image `r7` = `sha256:cdc8ee20...`
- the repository is `MUTABLE`
- `verify-lab-12.sh` reports `PASS=45 FAIL=0` and `verify-lab-11.sh` reports `PASS=46 FAIL=0`

**What the exercises added:**
- image `r7-alt`
- the green target group and the 8080 test listener
- a tighter trust on `usms-codepipeline-role`
- a collision-free image tag in the buildspec
- a `BASE_IMAGE` build argument in the Dockerfile

---

## Exercise 1 - Basic: a second base image, and a smaller one

**The change.** The Dockerfile's base became a build argument with the default unchanged
(`ARG BASE_IMAGE=nginx:1.27-alpine`, then `FROM ${BASE_IMAGE}`). So the second base is a flag, not
a second Dockerfile. `VERSION` stayed `r7`. `dist/` was rebuilt by the local runner, then:

```text
docker build --build-arg BASE_IMAGE=public.ecr.aws/nginx/nginx:stable-alpine -t ${URI}:r7-alt .
docker push ${URI}:r7-alt          ->  r7-alt: digest: sha256:d08809a6...
```

It was not deployed.

**The registry's numbers came in two steps.**
- **`describe-images` reports `imageSizeInBytes: 0`** for every image on Floci 2.2.0.
- **`batch-get-image` returns an OCI image index, not a manifest.** Docker Desktop pushes a
  multi-platform index with two entries, the image and an attestation, so the index has no layers
  of its own.

Following the index to the `linux/arm64` manifest gives the registry's own sizes
(`outputs/lab-12-ex1.txt`):

| | base | layers | registry (compressed) | local daemon (unpacked, `docker images`) |
|---|---|---|---|---|
| `r7` | nginx 1.27.5 (`nginx:1.27-alpine`) | 9 | 21.8 MB | 75.9 MB |
| `r7-alt` | nginx 1.30.6 (`public.ecr.aws/nginx/nginx:stable-alpine`) | 9 | 26.0 MB | 92.2 MB |

**Why the two columns differ.** The registry stores and reports **compressed** layers (gzip),
which is what a pull transfers. `docker images` reports the **unpacked** filesystem on disk,
roughly 3.5 times larger here. That accounts for most of the gap, as the hint says.

**What the difference between the two images is.**
- **Our own layer is the same 45 kB in both** (`docker history`: `COPY dist/`).
- **All 4.2 MB compressed (16 MB unpacked) of difference is the base.** `stable-alpine` is a
  newer nginx (1.30.6 against 1.27.5) on a newer Alpine, and the newer nginx build is bigger.
- **So the "alternative" is not smaller.** The exercise title assumed it would be. The choice of
  base decides almost the entire image, and the application is a rounding error.

**One more measurement trap.** With Docker Desktop's containerd image store,
`docker image inspect --format '{{.Size}}'` reports the content size, which equals the registry's
compressed number (21,823,376 bytes against 21.8 MB). Only `docker images` shows the unpacked
size. Which local number you quote depends on which command you ran.

---

## Exercise 2 - Intermediate: argue for immutable tags, then implement it

**The rejection.** I recorded `r7`'s digest, set `IMMUTABLE` with `put-image-tag-mutability`,
rebuilt `r7` (a new `builtAt` gives new bytes) and pushed it (`outputs/lab-12-ex2-push.txt`):

```text
r7 before: sha256:cdc8ee20...
IMMUTABLE
error from registry: The image tag r7 already exists in the usms-enrolment repository and cannot
be overwritten because the tag is immutable.
r7 after : sha256:cdc8ee20...       RESULT: tag did not move
```

**Floci 2.2.0 enforces immutability.** The guide lists that enforcement as build-dependent; on
this build it holds. The push uploaded its layers first (`f983971815e0: Pushed`) and was refused
at the tag. So a refused push still leaves orphaned layers behind, which is a lifecycle-policy
concern.

The failed rebuild had moved my **local** `r7` tag, so I pulled the real one back by digest and
retagged it. The registry was never wrong.

**The buildspec change.** The image is now tagged `<release>-<build number>`:

```yaml
- IMAGE_TAG="${USMS_RELEASE}-${CODEBUILD_BUILD_NUMBER:-local-$(date -u +%Y%m%dT%H%M%S)}"
```

`IMAGE_TAG` is used by the guarded `docker build`/`docker push`, by `build-metadata.json`'s
`imageUri`, and by `imagedefinitions.json`.
- **Fallback.** CodeBuild sets `CODEBUILD_BUILD_NUMBER`; the local runner does not, so it falls
  back to a UTC timestamp. The release stays readable at the front.
- **Tested** (`outputs/lab-12-ex2-buildspec.txt`):
  - locally: `r7-local-20261106T111759`
  - in CodeBuild (the standalone twin, build 10): `r7-10`, so **Floci does set
    `CODEBUILD_BUILD_NUMBER`**
  - `imagedefinitions.json` named the same tag in both

**What immutable tags buy:**
- **A tag means one set of bytes, forever.** So a task definition naming `r7-10` is as good as a
  digest for audit purposes.
- **No accidental overwrite.** It is exactly what happened twice in this lab: the Step 14 local
  runner re-pushed `r6`, and Exercise 5 retagged `r7`. Both would have been refused.
- **Rollback is safe.** Pointing back at an old revision really gets the old bytes.

**What they cost:**
- **Every build needs a new tag**, hence the change above.
- **No "latest" or "stable" convenience tags** that move.
- **Rebuilding the same release (say, to pick up a patched base) needs a new name**, and so a new
  task definition revision.
- **Refused pushes still leave layers behind.**

**End state: set back to `MUTABLE`, deliberately.** Exercise 5 has to retag `r7`, which an
immutable repository forbids. And the CloudFormation lab will compare against the guide's
`MUTABLE`; `verify-lab-12.sh` does not check this field, so a silent change would surprise it.
The buildspec keeps the collision-free tag, so flipping the repository to `IMMUTABLE` later needs
no further change.

---

## Exercise 3 - Problem solving: build the blue/green scaffolding

**Green target group.** `usms-enrolment-tg-green`, created from Lab 05's settings, read back from
`usms-enrolment-tg` rather than retyped. The two read back field for field
(`outputs/lab-12-ex3.txt`):

```text
usms-enrolment-tg        ip  HTTP  80  vpc-1441470d  HTTP  traffic-port  /  200
usms-enrolment-tg-green  ip  HTTP  80  vpc-1441470d  HTTP  traffic-port  /  200
```

**Test listener.** Port 8080 on `usms-enrolment-alb`, forwarding to the green group. The ALB now
has 80 to blue (production) and 8080 to green (test).

**The document.** `scripts/utilities/lab-12-fill-deployment-group.sh` looks up both listener ARNs
by port and writes them into `templates/lab-12-codedeploy-deployment-group.json`, which now holds
no `<` placeholders. It then validates three ways:

```text
1. valid JSON, placeholders left: 0
2. target group usms-enrolment-tg        exists, on usms-enrolment-alb
   target group usms-enrolment-tg-green  exists, on usms-enrolment-alb
   prod listener  port 80
   test listener  port 8080
3. CLI request model: accepted (failed only at connection, as intended)
```

**How check 3 works.** It sends the real `create-deployment-group` request to an **unreachable**
endpoint (`http://127.0.0.1:9`), so the AWS CLI validates it against CodeDeploy's request model
and then fails to connect. Nothing is created. A check that has never failed proves nothing, so I
misspelt one field in a copy: the CLI rejected it with `Unknown parameter in input:
"deploymentStyl"`.

**What remains unproven.** "Would be accepted by an account where CodeDeploy exists" is proven
only as far as the request model goes. Real CodeDeploy also checks at creation that the role
exists (`usms-codedeploy-role` does not), and that the service's deployment controller is
`CODE_DEPLOY`. Here it is still `ECS`, as the constraint requires. I did not create the
deployment group on Floci, even though its CodeDeploy API answers. Floci would almost certainly
accept a group that real AWS refuses, and that acceptance would prove nothing.

---

## Exercise 4 - Challenge: close the hole in the pipeline policy

### The attack, from IAM's own decisions

`scripts/utilities/lab-12-pipeline-role-simulate.sh` asks `simulate-principal-policy` about the
**live** role, which uses its default version, v2 (`outputs/lab-12-ex4-sim.txt`):

```text
-- the attack path
  ecs:RegisterTaskDefinition (any content, any family)         allowed
  iam:PassRole usms-ecs-task-role -> ecs-tasks.amazonaws.com   allowed
  ecs:UpdateService usms-enrolment-svc                         allowed
-- the bounds that hold
  ecs:UpdateService any other service                          implicitDeny
  ecs:RunTask (a one-off task)                                 implicitDeny
  iam:PassRole usms-ecs-task-role -> ec2.amazonaws.com         implicitDeny
  iam:PassRole usms-deploy-role -> ecs-tasks.amazonaws.com     implicitDeny
  s3:GetObject usms-student-data/* (the pipeline role itself)  implicitDeny
-- what the task role it CAN pass may do
  usms-ecs-task-role s3:GetObject / PutObject / DeleteObject   allowed (all three)
-- what the execution role may pull
  usms-ecs-exec-role ecr:BatchGetImage on ANY repository       allowed
```

**The most damaging thing a compromised pipeline role can do.**
1. **Register a revision** of `usms-enrolment` that keeps our trusted image, but sets an
   `entryPoint`/`command`. Revision 4 sets neither, so the field is free.
2. **Pass `usms-ecs-task-role`** to it, which is allowed by design.
3. **Run it:** `UpdateService` on `usms-enrolment-svc`, the one service it may touch.

The command runs inside production, with the task role's credentials, and can read, overwrite
and delete every student record in `usms-student-data`. It needs no new image, so no image
control stops it. The bounds above hold: it cannot reach another service, run a one-off task,
or pass any other role. But the one service it can reach is the one holding the student data.

### Why I did not write a v3: it cannot be closed in this policy

- **IAM sees only the action and the resource,** never the content of a task definition. The
  hole is in **what** is registered, and that content is invisible to IAM at the API call: the
  image, `command`, `entryPoint`, environment, or which of the two passable roles sits in
  which field. `RegisterTaskDefinition` has no resource to scope it to; Step 15 explains this.
- **I am not proposing any condition key.** I know of none that inspects task-definition
  content, and the constraint is to cite one only after checking it exists.
- **Removing either capability breaks the deploy.** Both `PassRole` on the task role and
  `UpdateService` are things the deploy action genuinely needs.

**What actually closes it, in order of strength:**
1. **Shrink what the passable role can do.** `usms-ecs-task-role` carries
   `USMSStudentDataReadWrite`: read, write **and delete** on every object. A web front end
   that reads transcripts needs `GetObject` on a prefix; that is Lab 09's
   `USMSStudentDataReadOnly`. Least privilege on the **task role** caps the blast radius of
   every path to it, this one included. It is IAM, but on a different principal.
2. **Gate the content before the service changes.** The real ECS deploy action only ever
   changes the image. So a pre-deploy check, as a pipeline action or a Lambda on the registered
   revision, can diff the new revision against the running one and refuse anything else.
   That is the same diff screenshot 02 shows (`container fields that differ ... ['image']`),
   used as a gate.
3. **Detect what slips through.** Alert on any `RegisterTaskDefinition` call (CloudTrail)
   whose container definition differs from its predecessor in more than `image`.
   `usms-taskdef-image-audit.sh` is the same idea, for missing images.
4. **Constrain images, which is necessary but not sufficient.** The execution role may pull
   from **any** ECR repository (`USMSECSTaskExecution` uses `Resource: "*"`), and the task
   subnets have a NAT path to public registries. Scoping the pulls to
   `repository/usms-enrolment` and removing the public egress would pin images to our own
   repository, which only the build role can push to. As shown above, it does nothing about
   `command`.

### An adjacent hole that IAM does close: who may become the pipeline role

**The gap.** `usms-codepipeline-role` trusted `codepipeline.amazonaws.com` with
`aws:SourceAccount` only. So **any** pipeline in this account could be created with this role,
and inherit the `RegisterTaskDefinition` + `PassRole` + `UpdateService` path above.

**The fix.** I added `ArnLike aws:SourceArn` naming
`arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline`
(`policies/trust-codepipeline.json`). This is the Lab 09 confused-deputy pattern, and the
condition Lab 11 Exercise 3 put on the build role.

**Not broken.** An execution after `update-assume-role-policy` (`7c7a23e9`) ran Source and Build
as before. Deploy failed exactly as before, on Floci's missing ECS provider.
`verify-lab-11.sh` stays at `46/0`. Floci does not enforce trust conditions, so "not broken" here
means the pipeline still runs and every check still passes, not that AWS evaluated the
condition.

### A trap I fell into, and what it nearly made me write

My first simulation said `implicitDeny` for **every** conditioned `PassRole`, including v1's
long-standing CodeBuild grant. I briefly concluded that Floci's `simulate-principal-policy` was
broken.

**It was zsh.** My helper built the optional argument as `${4:+--context-entries "..."}`, which
zsh passes as **one** word. The CLI therefore received no context, and a statement conditioned on
`iam:PassedToService` cannot match without it. Written out explicitly, the simulator agreed with
the policy. The script now builds its arguments in a bash array, and its header records why.

---

## Exercise 5 - Integration: prove a release end to end, for an auditor

**The document.** `outputs/lab-12-release-evidence.md` is written by
`scripts/utilities/lab-12-release-evidence.sh r7 <execution> <heading>`. Every value appears
directly under the command that produced it. The chain for r7, as Part 1 recorded it:

| # | Link | Value |
|---|---|---|
| 1 | pipeline execution, and the S3 version of the source it fetched | `24576f49-...` fetched `1dd91f41-...` |
| 2 | that exact version's `VERSION` | `r7` |
| 3 | stages | Source Succeeded (`1dd91f41`), Build Succeeded (`usms-enrolment-build:13`), Deploy Failed (no ECS provider) |
| 4 | the build that produced the deployable artifact | `usms-enrolment-build-standalone:8`: `release r7`, `imagedefinitions.json` naming `usms-enrolment:r7` |
| 5 | image digest of tag `r7` | `sha256:cdc8ee20...` |
| 6 | task definition revision | `usms-enrolment:4`, image `usms-enrolment:r7` |
| 7 | the digest each **running** task pulled | `sha256:cdc8ee20...`, on both tasks |

Link 3 is honest about the gap Labs 11 and 12 documented. The pipeline's own build ran nothing,
because Floci gives it an empty source. The deployable artifact came from the standalone twin's
build of the same key, and the deploy itself came from the stand-in action.

**The break.** `r7` was retagged onto the `r7-alt` image and pushed. The ledger got the second
`r7` line the constraint requires (`RETAGGED ... sha256:d08809a6...`). Nothing was deployed: the
service stayed on `:4` with one deployment. Part 2 re-ran the same seven commands:
- **Links 1-4** are unchanged. They are records keyed by immutable IDs.
- **Link 5 now answers `d08809a6...`,** a different image. Its `imagePushedAt` is the
  `r7-alt` manifest's original push time, so **the registry does not show that the tag moved**;
  only our own ledger does.
- **Link 6 still says `usms-enrolment:r7`,** character for character.
- **Link 7 still says `cdc8ee20...`.** ECS records the pulled digest per task at start, and it
  is the only AWS-held record of which bytes are running.

**What the document can and cannot still prove** (Part 3 of the document):
- **It can still prove:** the source, build and execution history, and which bytes the
  currently running tasks contain.
- **It can no longer prove from AWS's records alone:** that revision 4's image reference means
  those bytes. Any new task (scale-out, replacement, restart) would pull `d08809a6` while every
  record says "r7".
- **Where the join survives:** the join "the image that was built is the image that runs" now
  rests on tag equality, which the retag broke. It survives only because a digest was written
  down at push time.

A task definition that names a tag cannot prove which bytes ran. A digest, whether in the task
definition or recorded at build time and compared with the tasks' `imageDigest`, can.

**Restored.** `r7` was put back on `cdc8ee20...` immediately afterwards (ledger `RESTORED` line),
`configs/lab-12.env` was regenerated, and `verify-lab-12.sh` is `45/0`. Leaving it would have meant
the next Floci restart silently ran a different nginx under the name `r7`.
