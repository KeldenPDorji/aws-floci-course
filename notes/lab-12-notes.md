Support path: A (probe, Step 3) - ECR push/pull and ECS tasks are real; the pipeline's ECS deploy action is not ("Provider ECS is not available in Floci CodePipeline").

# Lab 12 - Deploying to Amazon ECS from the pipeline - my notes

## What the probe said, and what was true

`deploy-support-probe.sh` reported **Path A**: Docker, ECR and ECS all answer, and CodeDeploy
answers too. Running things showed more than the probe can.

| What | Observed on Floci 2.2.0 |
|---|---|
| The ECR registry | A sidecar container (`floci-<namespace>-ecr-registry`) that publishes `127.0.0.1:5100` **itself**. Pushes go through `repositoryUri` on port 4566, which Floci proxies to the sidecar |
| Step 4's port range | Publishing `5100-5104` on the Floci container collides with the sidecar (`Bind for 127.0.0.1:5100 failed: port is already allocated`), and Floci does not start. Reverted, with a comment in `docker-compose.yml` |
| `docker login` | First `503`. After the recreate, Floci was only on the compose network and the registry only on `bridge` + the `usms-vpc` network, so Floci could not reach it. `docker network connect floci-course_default <registry>` fixed it: `Login Succeeded`, over plain HTTP (a `*.localhost` host), with no insecure-registry setting needed |
| Push / pull / pull by digest | Real |
| `describe-images` | `imageSizeInBytes` is always 0; `imagePushedAt` is the manifest's push time, not when a tag moved |
| Images pushed from Docker Desktop | OCI image **indexes** (image + attestation); `batch-get-image` returns the index, with no layers |
| ECS tasks | **Real containers**, pulling from the registry, serving `release: r6` / `r7` |
| Rolling deployment | Replaces tasks without a visible `ACTIVE` second row during the overlap |
| A task whose image cannot be pulled | Fails, and is retried for ever: 46 failed tasks in 90 s, `rolloutState IN_PROGRESS`, zero service events |
| `deploymentConfiguration` | `null`. This repository's Lab 04 never set a circuit breaker, and Floci returns none |
| `describe-task-definition --task-definition <family>` | Returns the newest revision **even when it is INACTIVE**; real AWS returns the newest ACTIVE one |
| `describe-tasks ... containers[].imageDigest` | Recorded per task, at start: the most useful single field in Exercise 5 |
| The pipeline's Deploy stage (provider ECS) | `Provider ECS is not available in Floci CodePipeline` |
| `put-image-tag-mutability IMMUTABLE` | **Enforced**: a second push to `r7` is refused |
| `simulate-principal-policy` with conditions | Correct, once the context argument actually reaches the CLI (see Exercise 4) |

So the guide's own words apply: the deploy stage is "written and validated but not executed".
The four things that action does are done instead by
`scripts/utilities/usms-ecs-deploy-action.sh`, a labelled stand-in that reads
`imagedefinitions.json` from a real CodeBuild artifact.

## Two traps that cost me a re-push

- **zsh `:r`.** In zsh, `"$ECR_URI:r6"` is `$ECR_URI` with the `:r` ("remove extension")
  modifier applied, followed by `6`. The image was pushed to a stray repository,
  `usms-enrolment6:latest`, which I removed. Always write `"${ECR_URI}:r6"`.
  `"$ECR_URI:$IMAGE_TAG"` happens to be safe, because `:$` is not a modifier.
- **The guide's `docker info` guard.** It is true on any developer laptop. So the local runner,
  given `IMAGE_REPO_URI`, logged in, rebuilt and **re-pushed `r6`**, moving the tag to a
  different digest. Given the default `nginx`, it tried to push `nginx:r6` to Docker Hub, which
  refused. The guard now also requires `CODEBUILD_BUILD_ID` and a registry-shaped URI.

  The ledger (`outputs/lab-12-image-digest.txt`) records the move and the restore. That is a
  real-life instance of question 3's argument, two hours before I wrote the answer.

## One-sentence answers the checklist asks for

- **`COPY dist/`:** the image ships what the build **produced** (the substituted, tested
  `dist/`), not what it consumed (`src/`, `config/`, `tests/`, the buildspec, all excluded by
  `.dockerignore`). So what runs is exactly what the smoke tests checked.
- **`privilegedMode`:** it gives the build container a Docker daemon and elevated capabilities,
  which is enough to escape to the build host on a badly configured fleet. That is why who can
  start this one project matters: the pipeline role's `StartBuild` names a single project ARN.
- **`ecr:GetAuthorizationToken` on `"*"`:** it is a registry-level call with no repository to
  name, so scoping it denies it. The failure then shows up as a `docker login` authentication
  error, not an IAM one. The token alone grants nothing; push and pull are separately scoped to
  `repository/usms-enrolment`.
- **The second `iam:PassRole`:** registering a task definition that names an execution role and
  a task role hands both to ECS. The pipeline role may hand over exactly those two roles, and
  only to `ecs-tasks.amazonaws.com`. Exercise 4 shows `ec2.amazonaws.com` and any third role are
  refused.

## Step 12 "Your turn" - my v2 of `USMSCodePipelineBase`, against Step 15's

`notes/lab-12-my-pipeline-policy.json` has **five** statements; Step 15's has **six**. Three are
identical (artifact store, the one build project, the CodeBuild `PassRole`), and so is the ECS
`PassRole`. The two that do not match are the ECS ones.

**1. Scope: my single ECS statement is on `Resource: "*"`; Step 15 splits it in two.**
- **What Step 15 does:** `DescribeServices` and `UpdateService` are on **one service ARN**,
  and only the task-definition calls, which have no resource to scope to, are on `"*"`.
- **What mine does:** my version lets the role update **any** service in the account.
  Exercise 4's simulation shows "any other service: implicitDeny" under Step 15's version;
  under mine it would be `allowed`.
- **Why I wrote it that way:** I treated "the ECS calls" as one capability. They are two
  capabilities with different scoping possibilities, and the narrower one is worth separating.
  Step 15 is right.

**2. Actions: different lists, and neither can be tested here.**
- **Mine:** `DescribeTasks`, `ListTasks` and `TagResource`, which is how I remember the
  CodePipeline documentation's list for the ECS deploy action.
- **Step 15:** `ListTaskDefinitions`.
- **On Floci:** the ECS provider does not run, and Floci enforces no IAM, so neither list can
  be proved sufficient. On real AWS I would settle it the boring way: deploy with the minimal
  list, read the `AccessDenied` in the action's error details, and add exactly what it names.

## Step 16 "Your turn" - `inputArtifacts: SourceOutput` instead of `BuildOutput`

**What would be read.** The Deploy action would read `imagedefinitions.json` from the root of
**SourceOutput**. That is the source zip, whose root holds `buildspec.yml`, `VERSION`,
`Dockerfile`, `config/`, `src/` and `tests/`.

**Why the file is missing there.** `imagedefinitions.json` exists only in `dist/`. It is written
by the **build** phase, and `usms-pack-source.sh` excludes `dist/` from the source on purpose.

**Where the failure would appear.** The action would fail **in the Deploy stage** with a "file
not found in the input artifact" error naming `imagedefinitions.json`. The mistake is in the
Deploy action's `inputArtifacts` (the pipeline document), not in the Build stage, which would
have succeeded and produced a perfectly good `BuildOutput` that nothing read.

**On this Floci build the mistake would be invisible.** Deploy fails anyway, with `Provider ECS
is not available`, before it would ever look for the file. A real error masked by an
environmental one is the case worth remembering.

## Step 18 "Your turn" - what to do about `usms-enrolment:5`

**My decision: tag it, then deregister it.**
- **Tags:** `usms:status=failed-deploy`, `usms:reason=image-r8-never-pushed`,
  `usms:rolled-back-to=usms-enrolment-4`.
- **Deregister:** `deregister-task-definition`. It is now `INACTIVE`.

**The reason.** An ACTIVE revision is a **deployable** one. Anybody (or a script choosing "the
latest revision") could put the service back on an image that does not exist, and Step 18 showed
that nothing would object. Deregistering does not delete the evidence: an INACTIVE revision is
still describable, with its image, its tags and its ARN, so the audit trail survives. The
alternative, leaving it ACTIVE and documented, is defensible only if every deploy names an exact
revision, which the "latest revision" habit makes unlikely.

**How somebody notices six months from now, without being told.**
`scripts/utilities/usms-taskdef-image-audit.sh` lists every ACTIVE revision and checks each ECR
image reference against the registry. It exits 1 on a `MISSING`, so it can run on a schedule or
gate a deploy:
- **before the decision:** `MISSING usms-enrolment:5 ...:r8`, exit 1
- **after:** `0` missing

**A Floci quirk the decision exposed.** A bare family name in `describe-task-definition` still
returns `:5` after it is deregistered. Real AWS returns the newest ACTIVE revision. The env writer
and `verify-lab-12.sh` ask for the latest ACTIVE revision explicitly.

---

## Review questions (Section 14)

### 1. Three changes that cannot travel through this pipeline

The ECS deploy action copies the **running** revision and changes one field, the image. So
anything else in the task definition cannot ride along.

1. **Memory or CPU**, for example raising `memory` from 1024 for a new feature.
2. **Environment variables or secrets**, for example a new database host or a Secrets Manager
   reference.
3. **The logging or health-check configuration**, for example adding the `awslogs` driver this
   repository's revisions still lack, or a container health check.

Others in the same class are port mappings, a changed task role, and a sidecar container.

**How to deploy them.** Change the task definition **itself**, as a reviewed document:
- register the new revision from a committed template (by hand, from IaC, or through a
  CloudFormation deploy action), then `update-service` to it once
- from then on, the pipeline's image-only deploys copy that revision forward

**Why it must be one place.** If such a change is made out of band and nobody records it, the
deploy action silently preserves the drift for ever. The task definition has to be owned by one
place. The CloudFormation lab is where this gets fixed properly: the template is the task
definition, and the image is a parameter.

### 2. `GetAuthorizationToken` and `RegisterTaskDefinition` on `"*"`: the same kind of exception?

**The case that they are the same.** In both, the API offers nothing to scope to. The token is
for the registry, not a repository, and a task definition that does not exist yet has no ARN.
In both, the honest policy is `"*"` with the real control placed somewhere else: on push and pull
for the token, on `PassRole` for registration.

**The case that they are different.** The difference is what the call **creates**.
- **The token** authorises nothing by itself. Every push and pull is separately checked against
  `repository/usms-enrolment`. `"*"` there gives away a key to a building whose every door is
  still locked.
- **A task definition** is authority written down. It names roles, a command, an image and
  environment variables, and `UpdateService` makes it run. `"*"` there lets the holder author a
  new program that will run with the task role's permissions.

**My answer: they are not the same kind.** The first is a harmless global call. The second is a
real hole that IAM cannot see into. Exercise 4 demonstrates it: register a revision with a
`command` override, pass the task role (allowed by design), update the one service, and read,
write or delete every student record. The `PassRole` statement bounds **which** roles, not
**what is done with them**.

### 3. Digest versus tag

**For digests.** A digest is the content's identity: the same digest means the same bytes,
anywhere, for ever. A tag is a pointer that anyone with push rights can move. This lab moved
`r6` once by accident and `r7` once on purpose. Each time, every record that named the tag kept
saying the same thing while the bytes behind it changed. Exercise 5 showed that only a recorded
digest (the tasks' `imageDigest`, and our ledger) could still tell which bytes ran. Pinning
digests makes "what is deployed" a fact, not a lookup.

**The strongest case against pinning digests in task definitions.** Digests turn every image
change into a task definition change.
- **Base-image patching gets heavier.** With a tag, a patched base can be rebuilt and pushed
  under the same name, and a forced redeploy picks it up. With digests in task definitions,
  every service needs a new revision and a deploy, through the same pipeline and review as a
  feature, while the CVE is live.
- **Readability.** `...@sha256:1c92...` tells a human nothing during an incident; `r7` does.
- **ECS already does it per deployment.** As I understand it, ECS now resolves the tag to a
  digest at deployment time and runs every task of that deployment on that digest. That is the
  `imageDigest` Floci recorded here. If so, pinning in the document duplicates a guarantee the
  service already gives, and pays for it in patching speed and readability.

**The better split:**
- immutable, unique tags (Exercise 2), so a tag **is** a set of bytes
- digests recorded at build time
- the running tasks' digest compared with the recorded one

### 4. A failure the circuit breaker would not catch

**What the breaker watches.** It reacts to tasks that **fail to start or fail health checks**,
such as an unpullable image (Step 18), a crash at start-up, or a failing `/` check.

**A failure it misses.** Say r9 starts, passes the target group's `GET /` check, and returns
`200` for the portal page, but its new enrolment endpoint returns `500` on every submission
because a config value is wrong. To ECS the deployment is healthy, and it completes. Then every
student who tries to enrol for the next hour fails. The breaker cannot see a page it does not
check. The same applies to a memory leak that kills tasks hours after the deployment finished,
and to wrong data served correctly.

**The mechanism that catches it is an alarm on what users experience, tied to rollback:**
- **The alarm:** a CloudWatch alarm on the ALB's 5xx count, or on a business metric
  (successful enrolments per minute).
- **The rollback:** either
  - ECS deployment **alarms**, which roll the deployment back when the alarm fires
  - CodeDeploy's `DEPLOYMENT_STOP_ON_ALARM`, which Step 19's deployment group already lists
- **The earlier catch:** blue/green's `AfterAllowTestTraffic` hook, which runs a real
  enrolment smoke test against the test listener **before** production traffic moves, and
  catches it earlier still.

### 5. Replace-only APIs

**What they share.** Each sets a **small document whose meaning is the whole**:
- a pipeline's ordered stages and its artifact chain
- a bucket's notification set
- a role's trust statements
- a bucket policy

**Why replacement is the natural design.** Validity is a property of the whole document. For
example, a stage's input must be some earlier stage's output, and two policy statements interact
only as a pair. So the service validates exactly what it will store, and what you sent is what
you get.

**What a merge-based `update-pipeline` would have to decide:**
- **Identity.** Is a stage matched by name or by position? What does a renamed stage mean?
- **Deletion.** How does a partial document say "remove Build"? It needs tombstones or a
  separate API.
- **Order.** Where does a new stage go? Appended, before a named stage, or by index?
- **Nesting.** At what depth does merging stop? Does an action's `configuration` merge key by
  key, so a removed key survives?
- **Concurrency.** Two people merging at once can each produce a valid document while their
  combination is invalid.
- **Validation.** The service would have to validate the merged result, not the request, so
  errors would name things you never sent.

A replace-based API pushes all of that to the caller's get-modify-put. That is why Step 16's
script is deliberately paranoid: it refuses unexpected stages and refuses a second Deploy.

### 6. Why `create-policy-version` does not set the default by default

**Creating a version and making it effective are two decisions on purpose.** A managed policy
can be attached to many principals; this one is used by a live pipeline. A new version that is
wrong in one statement breaks every one of them at the moment it becomes the default.

**The workflow that separation protects:**
1. **Create** the version, inactive.
2. **Review and test it before anyone runs under it.** Diff it against the default, run
   `simulate-custom-policy` with the new document (Exercise 4 used simulation, and showed why
   you check the simulation's inputs), and get a second pair of eyes.
3. **Promote** it with `set-default-policy-version`.
4. **Roll back** by setting the previous version as the default again: an instant, exact undo,
   because the old version is still there.

The five-version limit is the other half: history you can roll back to, kept small.

**What a silent default would cost.** If `create` silently promoted, every edit would be a
production change with no staging and no prepared rollback. The cost of the separation is the
mistake the guide warns about: forgetting `--set-as-default`, which leaves everyone evaluating v1
with no error.

### 7. "The enrolment service is running code that was never reviewed"

**The three artefacts:**
- **The pipeline execution history helps most.** It links an execution to the **S3 version ID**
  of the source zip, and that exact zip can be downloaded and read (`VERSION r7`, the buildspec,
  the source).
- **`outputs/lab-12-deploy-evidence.txt` helps.** It links that execution to revision `:4` and
  the image reference `...:r7`.
- **`outputs/lab-12-image-digest.txt` helps only as far as it can be trusted.** It is a file
  **I** appended to, and it records the tag moving twice. It shows which digest `r7` named at
  each moment, but it is not a record AWS keeps.

**What none of them can show is the claim actually at issue, review.**
- **No link to review.** The source zip is packed from a working tree. Nothing in it, in the
  execution, in the image or in the metadata names a commit, so nothing connects the running
  bytes to a reviewed change.
- **The upload path is open.** Anyone with `PutObject` on the bucket could have uploaded the
  zip.
- **The build is not proven either.** The tasks' `imageDigest` proves which bytes run, but not
  which source built them, because the pipeline's own build built nothing on this emulator.

**What to record at build time to settle it in one command.** The **commit SHA**, of a commit
that is only reachable after review (a merged pull request), should be written into the image:
- as the label `org.opencontainers.image.revision=<sha>`, set by `docker build --label`
- in `build-metadata.json`

With immutable, unique tags (Exercise 2), or a signed image, nobody can swap the bytes under the
label. Then one command settles it, reading the label from the digest ECS recorded for a running
task:

```text
docker image inspect <repo>@<task's imageDigest> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
```

The SHA it prints either is or is not a merged, reviewed commit.
