# Lab 12 - Deploying to Amazon ECS from the Pipeline

## 1. Summary

This lab replaced the placeholder nginx container that Labs 04-11 ran with the enrolment service's
own image, and extended Lab 11's pipeline with a Deploy stage.

**The image:**
- **The repository.** `usms-enrolment`, the course's first private registry repository:
  `MUTABLE`, `scanOnPush`, AES256.
- **The Dockerfile.** It ships the built `dist/`, not the source.
- **The releases.** `r6` and `r7` were built, pushed, and read back by digest. `r6` was deleted
  locally and pulled back by digest.
- **The task definition.** Revision 3 was derived from revision 2 by describe, strip, register,
  and differs from it in exactly one field, the image.

**The pipeline:**
- **Build role.** `USMSCodeBuildBase` v2 adds ECR push.
- **Pipeline role.** `USMSCodePipelineBase` v2 adds the service-scoped ECS calls and a second
  `PassRole` (the two ECS roles, to `ecs-tasks` only). Both versions were created **and** set as
  default.
- **The project.** `privilegedMode` and `IMAGE_REPO_URI` (read from the API).
- **The buildspec.** It writes `imagedefinitions.json` and builds and pushes guardedly.
- **The pipeline.** Lab 11's two stages plus `Deploy` (provider ECS), added by get-modify-put.

**What ran on Floci 2.2.0 is a mixed path.** The probe says A. The registry and ECS are real, and
**the tasks really run our image**: the containers serve `release: r6`, then `release: r7`. But:
1. **Step 4's port publishing stopped Floci.** The ECR registry is a sidecar that already holds
   `127.0.0.1:5100`. The range stays unpublished, and pushes go through port 4566 (Section 6.1).
2. **The Deploy stage fails** with `Provider ECS is not available in Floci CodePipeline`.
   - **The guide's own Path B wording applies:** the stage is written and validated, not
     executed.
   - **What I did instead.** The deploy action's four steps were performed by a labelled
     stand-in, `usms-ecs-deploy-action.sh`. It read `imagedefinitions.json` from a real
     CodeBuild artifact of the same source and took the service from `:3` to `:4` (r7).
3. **The rollback drill showed a deployment that never fails.** An unpushed image produced 46
   failed tasks in 90 seconds, with `rolloutState` stuck at `IN_PROGRESS`, no events, and no
   circuit breaker: this repository's Lab 04 never set one.
   - **The rollback:** done by hand, to `:4`.
   - **Revision 5:** tagged with the reason, and deregistered. A new audit script finds such
     revisions.

**Verification.**
- **`verify-lab-12.sh`:** `PASS=45 FAIL=0`, with two commented adaptations.
- **`verify-lab-11.sh`:** `46/0`, after one check was adapted to Lab 12's third stage.
- **Regression:** Lab 10 `51/0`, Lab 09 `49/1`.
- **`configs/lab-12.env`:** 26 exports, all populated.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| ECR | `usms-enrolment` (`MUTABLE`, scanOnPush, AES256): `r6` `sha256:b16b18fc...`, `r7` `sha256:cdc8ee20...`, `r7-alt` `sha256:d08809a6...` (Exercise 1) |
| ECS | family `usms-enrolment`: `:3` (r6, Step 10), `:4` (r7, stand-in deploy), `:5` (r8, never pushed; tagged and `INACTIVE`); service on `:4`, 2/2 running r7 |
| IAM | `USMSCodeBuildBase` v2 (default), `USMSCodePipelineBase` v2 (default); `usms-codepipeline-role` trust now also conditioned on `aws:SourceArn` of the pipeline (Exercise 4) |
| CodeBuild | `usms-enrolment-build`: source/artifacts `CODEPIPELINE`, `privilegedMode`, `IMAGE_REPO_URI`; the Lab 11 twin given the same environment |
| CodePipeline | `usms-enrolment-pipeline`: Source (S3) to Build (CodeBuild) to Deploy (ECS, `imagedefinitions.json`) |
| ELB (Exercise 3) | `usms-enrolment-tg-green` (Lab 05's settings); test listener 8080 to green |
| Docker (local) | the registry sidecar attached to `floci-course_default` (Section 6.2); images `r6`, `r7`, `r7-alt` |
| Files | `Dockerfile`, `.dockerignore`, `buildspec.yml` (+ `buildspec.yml.lab08a`); 2 policies; 7 templates; `configs/lab-12.env`; the scripts in Section 3.10; `scripts/cleanup/lab-12-cleanup.sh` (never run) |

---

## 2. Evidence index

Six screenshots, each on one screen. Everything else is command output under `outputs/`
(git-ignored), quoted where it is used. The exercises came after the screenshots; their evidence
is `outputs/lab-12-ex*.txt` and [exercises.md](exercises.md).

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoints 1-2: Path A; the probe's `repositoryUri` read from the API; the repository `MUTABLE True AES256`; `Login Succeeded` against the host from `lab-12.env`; `r6` and `r7` digests; the digest ledger including the accidental move and restore of `r6` | [3.1](#31-checkpoints-1-2---probe-repository-login) |
| 02 | Checkpoints 3-4: `r6` untagged and deleted locally, `no local copy of r6 remains`, pulled back by digest; revisions 2 and 3 side by side; `container fields that differ from revision 2 : ['image']` | [3.2](#32-checkpoints-3-4---the-image-by-digest-and-revision-3) |
| 03 | Checkpoints 5-7: both policies at `v2` default with `v1` kept; `USMSCodeBuildBase` v2's five statements (`GetAuthorizationToken` on `*`, push scoped to the repository, the Deny); `USMSCodePipelineBase` v2's six Sids and its second `PassRole`; the project `CODEPIPELINE True <repository URI>`; three stages and the artifact chain | [3.3](#33-checkpoints-5-7---policies-project-pipeline) |
| 04 | Checkpoint 8: the r7 execution's Deploy `Failed: Provider ECS is not available in Floci CodePipeline`; the artifact's `imagedefinitions.json`; the evidence file (`:3` to `:4`, image `r7`, deployed by the stand-in); revision 4's fields; the service on `:4`, 2/2; both containers on `cdc8ee202a45` serving `release: r7` | [3.4](#34-checkpoint-8---release-r7) |
| 05 | Checkpoint 9: no `r8` in ECR; the captured drill (46 failed tasks, `IN_PROGRESS`, 0 events, circuit breaker `null`, `404 manifest unknown`); `:5` `INACTIVE` with its tags; the audit with 0 missing; the service back on `:4`, one deployment | [3.5](#35-checkpoint-9---the-rollback-drill) |
| 06 | Checkpoint 10 and Section 8: appspec parses, deployment group JSON valid; `PASS=45 FAIL=0`; 26 exports, all populated; `tag=r7`, its digest, `svc=usms-enrolment:4 stages=3 cb=v2 cp=v2 path=A`; hygiene; `verify-lab-11` `46/0` | [3.7](#37-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-21)

### 3.1 Checkpoints 1-2 - probe, repository, login

**Steps 1-2.**
- **Lab 11's readiness file** was read first. It had warned that the pipeline stores no
  `BuildOutput` and that the CodeBuild stand-in image has no `docker`, and both mattered
  later.
- **Prerequisites:** Lab 04 `39/0`, Lab 05 `49/1` (the documented stale rules store),
  Lab 11 `46/0`. Every environment file sourced, with no `MISSING`.

**Step 3.** `deploy-support-probe.sh` is the guide's script, verbatim. It reported Path A, with
CodeDeploy answering.

**Step 4: not applied.** Publishing `5100-5104` on the Floci container stopped Floci from
starting. Section 6.1 has the details; the line is back to commented, with the reason beside it.

**Steps 5-6.**
- **The repository** was created as the guide writes it.
- **The registry host** came from `describe-repositories` (`${URI%%/*}`), never typed.
- **`docker login`, with the token on standard input,** first returned `503`, and succeeded
  after the network fix in Section 6.2.

![Checkpoints 1-2: deploy-support-probe.sh - docker daemon reachable, ecr describe-repositories and create-repository ok, probe repositoryUri 000000000000.dkr.ecr.us-east-1.localhost:4566/usms-probe-delete-me, probe deleted, ecs and codedeploy answer, PATH A; repository 000000000000.dkr.ecr.us-east-1.localhost:4566/usms-enrolment MUTABLE True AES256; Login Succeeded; images r7 sha256:cdc8ee20... and r6 sha256:b16b18fc...; ledger r6 b16b18fc 10:24:19Z, r6 ca517a50 MOVED by the Step 14 local runner, r6 b16b18fc RESTORED, r7 cdc8ee20 10:34:07Z](../../screenshots/lab12-01-checkpoints1-2-probe-ecr-login.png)

**Reading the screenshot.** The ledger is longer than the guide's one line per tag because it
records a mistake. Step 14's local runner re-pushed `r6`, moving it to `ca517a50`
(Section 6.3), before I restored it. It is in the screenshot on purpose: it is the mutable-tag
hazard of Section 14, question 3, caught by the one record that keeps history.

### 3.2 Checkpoints 3-4 - the image by digest, and revision 3

**Steps 7-8.** The Dockerfile and `.dockerignore` are the guide's. Release r6:
1. `dist/` built by the local runner (7 smoke tests, `release=r6`)
2. `docker build`, `docker tag`, `docker push`
3. the push printed `r6: digest: sha256:b16b18fc...`

**Step 9.** `describe-images` read the digest back, and it went into the ledger.

**Step 10.** `scripts/utilities/lab-12-derive-taskdef.sh r6 --register` is the guide's Python in a
script. It takes the image reference from ECR by tag rather than from a shell variable, strips
the eight read-only fields, and finds the container by name.
- **Revision 2 has no health check or log configuration in this repository.** Its container
  holds only `environment`, `essential`, `image`, `name` and `portMappings`. So revision 3
  "keeping the health check" means keeping none.
- **What matters is that nothing was dropped,** and the one-field diff in the screenshot shows
  that.

**Step 11.** `update-service` to `:3`. `usms-ecs-watch.sh` (the guide's) settled at poll 2, with
one deployment and 2 of 2 running. **The tasks were real:** both containers ran image
`b16b18fcdfb9` and served `release: r6` (`docker exec ... wget http://localhost/`). Floci never
showed the old deployment as a second `ACTIVE` row; it replaced the tasks without a visible
overlap.

![Checkpoints 3-4: docker rmi untagged r6 and its digest reference and deleted sha256:b16b18fc...; no local copy of r6 remains; docker pull by digest - Pull complete, Digest sha256:b16b18fc..., Downloaded newer image; docker images --digests shows the digest, 75.9MB; revision 2 public.ecr.aws/nginx/nginx:stable-alpine 256 1024 usms-ecs-exec-role usms-ecs-task-role; revision 3 000000000000.dkr.ecr.us-east-1.localhost:4566/usms-enrolment:r6 256 1024 usms-ecs-exec-role usms-ecs-task-role; container fields that differ from revision 2 : ['image']](../../screenshots/lab12-02-checkpoints3-4-digest-pull-taskdef.png)

**Reading the screenshot.**
- **The guide's create, perturb, read back.** The local copy is gone, then comes back **by
  digest**, so the bytes were in the registry, not only in my cache.
- **The check for "no local copy" tests the `r6` reference specifically.** The guide's
  `grep -c usms-enrolment` would have matched `r7`.
- **The last line compares the two revisions field by field.** It is stronger than eyeballing
  cpu and memory.

### 3.3 Checkpoints 5-7 - policies, project, pipeline

**Step 12.** The guide's `USMSCodeBuildBase` v2, created with `--set-as-default`. The "Your
turn" draft is in `notes/lab-12-my-pipeline-policy.json`, compared in the notes. My draft put
every ECS action on `"*"`, which would let the role update **any** service; Step 15 splits off a
service-scoped statement and is right.

**Step 13.** The project update is written by lookup (`write-lab-12-templates.sh codebuild`, `0
unexpanded $`). `source.type` stayed `CODEPIPELINE` and `buildspec` stayed `buildspec.yml`, so
Lab 11 Step 18 was not undone. The Lab 11 twin was given the same environment.

**Step 14: extended, not rewritten.** The guide's Step 14 replaces `buildspec.yml` wholesale.
That would have deleted three pieces of Lab 11 exercise work:
- Exercise 3's parsed config check
- Exercise 2's `finally`
- Exercise 5's `IMAGE_URI` override

So I added the guide's pieces as edits, and kept the old file as `buildspec.yml.lab08a`, as the
guide asks:
- `IMAGE_REPO_URI` (default `nginx`)
- `docker --version`
- a guarded `docker login`
- a guarded `docker build`/`push` after `dist/` is assembled
- `imageUri` in the metadata
- `imagedefinitions.json` naming `${IMAGE_REPO_URI}:<tag>`

The eighth smoke assertion already existed from Lab 11 Exercise 5, and it is stricter: it takes
the container from `service.json`.

**The guard changed** (Section 6.3). Image work runs only with `CODEBUILD_BUILD_ID` set and a
registry-shaped `IMAGE_REPO_URI`.

**Step 15.** The guide's `USMSCodePipelineBase` v2, with six Sids, set as default.

**Step 16.** `write-lab-12-templates.sh pipeline` performs the guide's get (dropping `metadata`),
then append, keeping its `assert` and `raise` paranoia. `update-pipeline` returned `Stages 3,
Version 2`.

![Checkpoints 5-7: USMSCodeBuildBase v1 False v2 True; v2 statements WriteItsOwnBuildLogs Allow on the two log ARNs, ReadSourceAndWriteArtifacts Allow on the bucket, GetARegistryTokenWhichCannotBeScoped Allow *, PushAndPullTheEnrolmentImageOnly Allow repository/usms-enrolment, BuildsDoNotTouchStudentRecords Deny usms-student-data; USMSCodePipelineBase v1 False v2 True; six Sids; PassTheTwoEcsRolesAndOnlyToEcsTasks iam:PassRole on usms-ecs-exec-role and usms-ecs-task-role with iam:PassedToService ecs-tasks.amazonaws.com; project CODEPIPELINE True with IMAGE_REPO_URI; stages Source S3 None, Build CodeBuild SourceOutput, Deploy ECS BuildOutput imagedefinitions.json](../../screenshots/lab12-03-checkpoints5-7-policies-project-pipeline.png)

**Reading the screenshot.** The last three lines are the pipeline's data flow, read down the
input column (`None`, `SourceOutput`, `BuildOutput`), plus the file the Deploy action looks for.

### 3.4 Checkpoint 8 - release r7

**Step 17, in the order it ran:**
1. **r7 pushed by hand first.** The guide's warning box applies twice over: Lab 11 showed this
   pipeline's build gets an empty source, and its stand-in image has no `docker`. The push gave
   `r7` = `sha256:cdc8ee20...`.
2. **The pipeline run.** `VERSION` was set to r7, the source uploaded as version `1dd91f41`,
   and execution `24576f49` started: Source `Succeeded`, Build `Succeeded`, Deploy `Failed:
   Provider ECS is not available in Floci CodePipeline`. The service stayed on `:3`.
3. **The deploy, done by the stand-in.** `scripts/utilities/usms-ecs-deploy-action.sh`
   performs Section 5's four steps and no more:
   - it reads `imagedefinitions.json` from a build artifact, here
     `usms-enrolment-build-standalone-8.zip`, a real CodeBuild build of the same source key
   - it describes the service's **current** revision
   - it replaces the image of the container the file names
   - it registers the result, then runs `update-service`

   Like the real action, it never reads a task definition file from the repository. The result
   is `:3` to `:4`, settled at 2/2.

![Checkpoint 8: execution 24576f49 Deploy Failed "Provider ECS is not available in Floci CodePipeline", Build Succeeded, Source Succeeded; artifact imagedefinitions.json [{"name": "enrolment-api", "imageUri": ".../usms-enrolment:r7"}]; evidence - source version 1dd91f41, artifact usms-enrolment-build-standalone-8.zip release r7, deployed by usms-ecs-deploy-action.sh (stand-in), task def before usms-enrolment:3, after usms-enrolment:4, image after usms-enrolment:r7; revision 4 image r7 256 1024 both roles; service usms-enrolment:4 2 2; two containers sha256:cdc8ee202a45 release: r7](../../screenshots/lab12-04-checkpoint8-deploy-r7.png)

**The guide's three proofs:**
1. **The revision increased** from `:3` to `:4`. It was registered by the stand-in action, not
   by Floci's pipeline. The evidence file says so in its `deployed by` line.
2. **The image names `r7`.** The bottom two lines go one step further: both running containers
   are on image `cdc8ee202a45` and serve `release: r7`. The chain from `VERSION` to a running
   page is observed, not inferred.
3. **Everything else in revision 4 is unchanged:** cpu, memory and both roles. As with revision
   3, there is no log driver, matching revision 2.

### 3.5 Checkpoint 9 - the rollback drill

**Step 18: what I did.**
1. Set `VERSION` to r8 and uploaded the source.
2. Confirmed that only `r6` and `r7` exist in ECR.
3. Ran the pipeline (Deploy failed as before).
4. Built the same source on the twin.
5. Ran the stand-in deploy, which registered `:5` naming `...:r8` and moved the service to it.

**What happened next is the guide's "what you can observe" point, made sharper.** On this build
the tasks are real, so Floci actually tried to start them:
- **The pull failed every time.** Floci pulled `...:r8`, the registry answered `404 manifest
  unknown`, and the task failed.
- **It retried without limit:** 46 failed tasks in 90 seconds, with the rollout state stuck at
  `IN_PROGRESS` and **no service events at all**.
- **There was no breaker to trip.** `deploymentConfiguration` came back `null`. This
  repository's Lab 04 never set a circuit breaker, so the guide's "stored, not enforced" does
  not even apply.
- **The records and reality disagreed.** The two old r7 tasks kept running (`runningCount 2`),
  but they had vanished from `deployments[]`. Users were still served r7, while the record
  showed only a failing deployment.

**The rollback.** `update-service` to `:4`, by hand. It settled with one deployment and 2 of 2
running, and both new containers serve `release: r7`. The source went back to r7.

![Checkpoint 9: ECR tags r7 r6 (no r8); the captured drill - PRIMARY usms-enrolment:5, rolloutState IN_PROGRESS, 0 running and 46 failed tasks, service 2/2 (the old r7 tasks, no longer in deployments[]), 0 events, 50 stopped tasks, deploymentConfiguration (circuit breaker) null, floci log 404 manifest unknown, Failed to start ECS task; revision 5 INACTIVE naming usms-enrolment:r8 with tags usms:rolled-back-to usms-enrolment-4, usms:status failed-deploy, usms:reason image-r8-never-pushed; audit EXTERNAL :1 :2, ok :3 r6, ok :4 r7, 0 missing; service usms-enrolment:4 2 2 with 1 deployment](../../screenshots/lab12-05-checkpoint9-rollback-drill.png)

**The "Your turn": I tagged revision 5 with the reason and deregistered it.**
- **How it gets noticed.** `scripts/utilities/usms-taskdef-image-audit.sh` lists every ACTIVE
  revision and checks each ECR image against the registry. It flagged `:5 MISSING` (exit 1)
  before the decision and finds nothing after it.
- **Why the summary file.** The drill's numbers in the screenshot come from
  `outputs/lab-12-step18-summary.txt`, a labelled rewrite of the raw capture taken at the time
  (`lab-12-step18-observe.txt`). The drill cannot be re-observed after the rollback.

The reasoning is in the notes.

### 3.6 Checkpoint 10 - blue/green, on paper

**Step 19.**
- **The documents:** the appspec and the deployment group document, both the guide's.
- **Validation:** PyYAML is absent, so the appspec was parsed with Ruby's YAML (`container
  enrolment-api port 80`, five hooks). The JSON was checked with `json.tool`.

**CodeDeploy answers on this build, but nothing was executed,** as the step requires. Exercise
3 built the second target group and the test listener, and validated the filled document against
the CLI's CodeDeploy request model without creating anything.

### 3.7 Verification and hygiene

**Step 20.** `scripts/utilities/write-lab-12-env.sh` writes the guide's 26 exports by lookup.
- **The registry host** is derived in the shell before the heredoc, so the guide's `cut -d/`
  workaround is not needed.
- **The revision** is the family's latest **ACTIVE** one, asked for explicitly. Floci returned
  `:5` for the bare family name even after it was deregistered.
- **The comments** state the Floci facts a later lab needs, and why the port range is not
  published.

**Section 8.1.** `verify-lab-12.sh` is the guide's 45 checks, with two adaptations, each commented:
- **`tdef()`** reads the latest ACTIVE revision, for the same Floci quirk.
- **"No secret is tracked"** ignores `outputs/.gitkeep`, as in Labs 10 and 11.

![Section 8: appspec parses: container enrolment-api port 80; deployment group document is valid JSON; verify-lab-12.sh section headers only, PASS=45 FAIL=0; 26 exports; all values populated; tag=r7 digest=sha256:cdc8ee20...; svc=usms-enrolment:4 stages=3 cb=v2 cp=v2 path=A; nothing under outputs/, no zip, no dist/, no backup, no live snapshot; .gitignore:8:outputs/* for the deploy evidence and .gitignore:45 for templates/lab-12-taskdef-base.json; verify-lab-11.sh PASS=46 FAIL=0](../../screenshots/lab12-06-verify-env-and-hygiene.png)

**Lab 11's verify** has one adapted check. "Pipeline has 2 stages" became "stages 1-2 are Source,
Build", because Lab 12 appends a third stage by design. Without the change it would read
`45/1` on a correct repository.

**Step 21's hygiene:**
- **No compose backup.** I edited `docker-compose.yml` in place, with git as the backup, so
  there is no `docker-compose.yml.bak-*` and no `.gitignore` rule for one.
- **The live snapshots are ignored.** The guide says not to commit
  `templates/lab-12-taskdef-base.json` or `templates/lab-12-pipeline-current.json`, so they are
  now **ignored** rather than left to memory.
- **The commit itself** is left to me, as in every lab.

**Section 8.2.** `scripts/cleanup/lab-12-cleanup.sh` is the guide's script, using `mktemp`
instead of fixed `/tmp` names. It has passed `bash -n` and has **not** been run.

### 3.8 Regression

`verify-lab-09` `49/1` (its documented failure), `verify-lab-10` `51/0`, `verify-lab-11` `46/0`.
Lab 04's service was changed by design: it now runs our image, on `:4`.

### 3.9 Not done

Section 13.1 is the in-class practical assessment: a results service, a trace, an
approval-stage design, and housekeeping. It is done in class, at a machine, and is not part of
this submission.

### 3.10 Files

| File | Purpose |
|---|---|
| `labs/lab-11-cicd/app/Dockerfile`, `.dockerignore` | the image; `BASE_IMAGE` build argument (Exercise 1) |
| `labs/lab-11-cicd/app/buildspec.yml`, `buildspec.yml.lab08a` | extended buildspec; the Lab 11 version kept |
| `labs/lab-11-cicd/app/VERSION` | `r7` |
| `policies/usms-codebuild-policy-v2.json`, `usms-codepipeline-policy-v2.json` | the two v2 documents |
| `policies/trust-codepipeline.json` | trust tightened with `aws:SourceArn` (Exercise 4) |
| `templates/lab-12-taskdef-v3.json`, `-codebuild-update.json`, `-pipeline.json` | request bodies, written by lookup |
| `templates/lab-12-appspec.yaml`, `-codedeploy-deployment-group.json` | blue/green, conceptual; the latter filled with real listener ARNs (Exercise 3) |
| `configs/lab-12.env` | 26 exports |
| `docker-compose.yml` | the 5100-5104 line kept commented, with the reason |
| `scripts/utilities/deploy-support-probe.sh`, `usms-ecs-watch.sh` | the guide's (Steps 3, 11) |
| `scripts/utilities/lab-12-derive-taskdef.sh` | Step 10, describe-strip-register |
| `scripts/utilities/write-lab-12-templates.sh` | `codebuild` (Step 13), `pipeline` (Step 16) |
| `scripts/utilities/usms-ecs-deploy-action.sh` | the stand-in for the ECS deploy action |
| `scripts/utilities/usms-taskdef-image-audit.sh` | Step 18 "Your turn" |
| `scripts/utilities/write-lab-12-env.sh`, `verify-lab-12.sh` | Step 20, Section 8.1 |
| `scripts/utilities/lab-12-fill-deployment-group.sh` | Exercise 3 |
| `scripts/utilities/lab-12-pipeline-role-simulate.sh` | Exercise 4 |
| `scripts/utilities/lab-12-release-evidence.sh` | Exercise 5 |
| `scripts/utilities/verify-lab-11.sh` | one check adapted to the third stage |
| `scripts/cleanup/lab-12-cleanup.sh` | Section 8.2, never run |
| `notes/lab-12-notes.md`, `notes/lab-12-my-pipeline-policy.json` | notes, "Your turn" answers, review questions |

---

## 4. Exercises 1-5

Full commands, output and reasoning are in [exercises.md](exercises.md).

1. **A second base.**
   - **How:** `r7-alt` was built with `--build-arg BASE_IMAGE=public.ecr.aws/nginx/nginx:stable-alpine`.
   - **The registry's sizes:** `describe-images` reports 0, and the registry returns an OCI
     index, so the index was followed to the platform manifest: 21.8 MB against 26.0 MB
     compressed. Locally, unpacked: 75.9 MB against 92.2 MB.
   - **What differs:** all of it is the base (nginx 1.27.5 against 1.30.6). Our layer is 45 kB
     in both, so the "alternative" is not smaller.
2. **Immutable tags.**
   - **Enforced:** Floci refused a second push to `r7`, and the tag did not move.
   - **The buildspec now tags `<release>-<build number>`:** `r7-10` in CodeBuild, a timestamp
     locally.
   - **End state:** set back to `MUTABLE`, because Exercise 5 must retag.
3. **Blue/green scaffolding.**
   - **Built:** a green target group cloned from Lab 05's settings, and a test listener on 8080.
   - **The document:** filled by lookup, no placeholders left. The CLI's request model accepts
     it; a misspelt field is rejected. The deployment controller is untouched.
4. **The pipeline policy's hole.**
   - **IAM's simulator** confirms the path: register any revision, pass the task role, update
     the service. The task role can read, write and delete every student record.
   - **Not closable in this policy:** IAM cannot see task-definition content. The controls are
     task-role least privilege, a content gate before deploy, and detection.
   - **Closed:** the adjacent gap in the pipeline role's trust, now with `aws:SourceArn`.
   - **A trap documented:** zsh had made the simulator look broken.
5. **Release evidence.**
   - **The document:** `outputs/lab-12-release-evidence.md`, seven links, each command beside
     its output.
   - **The break:** retagging `r7` breaks links 5-6 while ECS's per-task `imageDigest` (link 7)
     still proves what runs. The ledger records the move.
   - **Restored** afterwards.

---

## 5. Review questions

Answered in prose in [notes/lab-12-notes.md](../../notes/lab-12-notes.md#review-questions-section-14):

1. **What cannot travel through the deploy action.** Memory and CPU, environment and secrets,
   logging and health checks. They change through a reviewed task-definition template,
   registered once.
2. **The two `"*"` grants are not the same kind.** The token is harmless; a task definition is
   authority written down (Exercise 4).
3. **Digests make "what is deployed" a fact.** Against: patching speed and readability, and
   ECS already resolves tags per deployment.
4. **The circuit breaker misses healthy-but-wrong releases.** Alarms on user-facing metrics,
   tied to rollback or blue/green test hooks, catch them.
5. **Replace-only APIs set whole documents, whose validity is whole.** A merge would need
   identity, deletion, order, nesting and concurrency rules.
6. **Staging versions protects review, simulation and instant rollback.**
7. **Execution history and the deploy evidence help; the ledger only partly.** None ties bytes
   to review. Record the commit SHA as an image label and settle it in one command.

---

## 6. Problems encountered

### 6.1 Step 4 stopped Floci

**What happened.** With `5100-5104:5100-5104` published, `floci-up.sh` failed: `Bind for
127.0.0.1:5100 failed: port is already allocated`, and nothing answered on 4566.

**Why.** On Floci 2.2.0 the ECR registry is a separate sidecar container,
`floci-aws-floci-course-ecr-registry`, which publishes `127.0.0.1:5100` itself, and pushes go
through the `repositoryUri` on 4566.

**The fix.** The line is back to commented, with the reason in `docker-compose.yml`. State was
unaffected: the service was still `ACTIVE` on `:2` after the restart.

### 6.2 `docker login` returned 503

**The diagnosis.** The sidecar answered `/v2/` on 5100 with 200; Floci's proxy on 4566 answered
503.
- **After the recreate,** Floci was attached only to `floci-course_default`.
- **The registry** was on `bridge` and the `usms-vpc` network (10.0.0.3).
- **Before,** Floci had also been on that VPC network (10.0.0.2), and reached the registry
  there.

**The fix.** `docker network connect floci-course_default floci-aws-floci-course-ecr-registry`.
It is non-destructive, and the connection stays with the container, which Floci adopts on
restart. If Floci ever **recreates** the sidecar, the connect has to be repeated. The symptom is
the same 503.

### 6.3 Two ways `r6` moved under me

**The guard.** The guide's `if docker info` guard is true on a laptop. So `IMAGE_REPO_URI=<repo>
./usms-buildspec-run.sh` rebuilt the image and re-pushed `r6`, giving `ca517a50`. With the
default `nginx`, it tried `docker push nginx:r6` to Docker Hub, which refused (`insufficient
scope`), so nothing left the machine. The guard now also requires `CODEBUILD_BUILD_ID` and a
registry-shaped URI.

**The restore, and zsh.** My first attempt to restore `r6` ran `docker tag ... "$ECR_URI:r6"`
in zsh. There `:r` is a history modifier, so the push went to a stray repository,
`usms-enrolment6:latest`. I removed it from the registry (a `DELETE` on the manifest, HTTP 202)
and redid the restore with `${ECR_URI}`. Every screenshot command uses braces for this reason.

The ledger records the move and the restore.

### 6.4 The pipeline cannot deploy

`Provider ECS is not available in Floci CodePipeline` comes on top of Lab 11's empty-source
builds. The stand-in action (Section 3.4) is the evidence that the mechanism works, and it is
labelled as a stand-in everywhere it appears: the evidence file, the env comments, the report.

### 6.5 Smaller ones

- **A deregistered revision is still returned for the bare family name** (Section 3.7).
- **`describe-images` reports a size of 0,** and Docker Desktop pushes OCI indexes
  (Exercise 1).
- **The task definitions have no health check or log configuration in this repository**
  (Section 3.2).
- **A zsh `${4:+--flag "x"}` expansion is one word,** which made the IAM simulator look broken
  in Exercise 4 until I found it.
- **Revision 5 still names a missing image while INACTIVE.** That is by design: it is evidence,
  and the audit only judges ACTIVE revisions.

---

## 7. Floci limitations versus real AWS

**Observed:**
- a repository, a real push, a delete, and a pull **by digest**
- tag immutability enforced
- a revision derived with exactly one field changed
- the service running **our** image in real containers, r6 then r7
- an unpullable release failing every task with no rollback
- a manual rollback by naming a revision
- per-task image digests
- a three-stage pipeline document, with its first two stages executing

**Recorded, not enforced:**
- both v2 policies, the scoped `PassRole`s, the single-service ARN, and the trust conditions
  (Floci authorises nothing; Exercise 4's decisions come from the simulator, not from denials)
- `scanOnPush` (no scan results)

**Not executed:**
- the pipeline's ECS deploy action
- the circuit breaker (never configured here)
- CodeDeploy blue/green (documents only, validated)

**Not available:** scan findings, lifecycle expiry, and image signing.

| Behaviour | Real AWS | Floci 2.2.0, as observed |
|---|---|---|
| ECR registry endpoint | `<acct>.dkr.ecr.<region>.amazonaws.com`, HTTPS | `<acct>.dkr.ecr.<region>.localhost:4566`, plain HTTP; a sidecar on 127.0.0.1:5100 behind it |
| Publishing 5100-5104 | n/a | Breaks Floci (the sidecar holds the port) |
| Image size in `describe-images` | Compressed size | Always 0 |
| `IMMUTABLE` tags | Enforced | Enforced |
| ECS tasks | Real | Real containers, pulling from the registry |
| Unpullable image | Tasks fail, the breaker (if set) trips and rolls back | Tasks fail and retry for ever, `IN_PROGRESS`, no events |
| `rolloutState` / events | Populated | `rolloutState` yes; events none |
| Family name in `describe-task-definition` | Newest ACTIVE revision | Newest revision, even INACTIVE |
| Per-task `imageDigest` | Recorded | Recorded |
| CodePipeline ECS deploy action | Registers and updates | `Provider ECS is not available in Floci CodePipeline` |
| CodeDeploy | Full | API answers; nothing executed here |

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh
docker build -t aws/codebuild/standard:7.0 labs/lab-11-cicd/codebuild-standin    # Lab 11, once
# if docker login returns 503: the registry sidecar lost Floci's network
docker network connect floci-course_default floci-aws-floci-course-ecr-registry
source configs/course.env
source configs/lab-04.env
source configs/lab-12.env
./scripts/utilities/verify-lab-12.sh                        # PASS=45  FAIL=0
./scripts/utilities/usms-taskdef-image-audit.sh             # 0 missing
```
