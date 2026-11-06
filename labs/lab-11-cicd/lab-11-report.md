# Lab 11 - Building a CI/CD pipeline with CodePipeline and CodeBuild

## 1. Summary

This lab gave the enrolment service a source tree and a build, and joined them with a
two-stage pipeline:
- **The artifact store.** `usms-pipeline-artifacts` is versioned, has public access
  blocked, and is tagged. Versioning was proved by two versions at one key, then cleaned
  up.
- **The source tree.** `labs/lab-11-cicd/app/` holds a static portal, a health page, a
  validated `config/service.json`, eight smoke tests and a `buildspec.yml`. Its four phases
  validate the configuration, substitute the release and build time, write
  `build-metadata.json` and `imagedefinitions.json`, and test the result.
- **Two scoped identities.**
  - `usms-codebuild-role` + `USMSCodeBuildBase`: its own log group, the artifact bucket,
    and an explicit Deny on student data.
  - `usms-codepipeline-role` + `USMSCodePipelineBase`: the artifact store, one build
    project, and `iam:PassRole` on the build role only, to `codebuild.amazonaws.com` only.
- **The build and pipeline.** `usms-enrolment-build` (CodeBuild), and
  `usms-enrolment-pipeline`: Source (S3) to Build (CodeBuild).

**Support path: A by the probe, mixed in practice.** Floci 2.2.0 answers every CI/CD API,
but running it showed three things the probe cannot see (Section 6):
1. **CodeBuild really runs builds** in Docker containers, but only after I supplied a
   **local stand-in image** under the name `aws/codebuild/standard:7.0`. Docker Hub has no
   such repository, so the first build ended `FAULT`.
2. **A project-level `"buildspec": "buildspec.yml"` is read as inline YAML** on an S3-source
   project. Builds "succeed" in 30 ms having run nothing. The Step 10 template omits the
   field, which means the same thing on real AWS.
3. **The pipeline runs both stages, but its build receives an empty source directory, and
   no `SourceOutput` or `BuildOutput` is ever stored.** Every pipeline execution is
   therefore green with nothing built, including the one on deliberately broken source.

The guide's own "green is not evidence; the artifact is" principle is what exposed the
third. So the Step 19 proof is rebuilt from what Floci does record:
- **The pipeline's record.** Each execution records the exact S3 version ID its Source
  action fetched.
- **That exact version.** Downloaded by version ID, it contains the release.
- **A real CodeBuild build of the same key.** It comes from a standalone twin project,
  `usms-enrolment-build-standalone`, which keeps the S3 source.

**Verification.**
- **`verify-lab-11.sh`:** `PASS=46 FAIL=0`, both at the screenshot and after the exercises.
  It checks configuration, not behaviour. That is why it passes on a build whose pipeline
  builds nothing, and why Section 3.6 matters more than the count.
- **Regression:** `verify-lab-10.sh` `51/0`, `verify-lab-09.sh` `49/1` (its documented
  Floci failure).
- **IAM audit:** `HIGH=0` across 17 roles. All three new roles carry confused-deputy
  conditions.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| S3 | `usms-pipeline-artifacts` (versioning Enabled, public access blocked, EventBridge notifications on); `source/usms-enrolment-src.zip` 9 versions (r3 to r6); `source/usms-results-src.zip`; build artifacts `usms-enrolment-build-4.zip`, `usms-enrolment-build-standalone-{1,2,4,5,6,7}.zip`, `usms-results-build-{1,2,3}.zip` |
| CodeBuild | `usms-enrolment-build` (source/artifacts `CODEPIPELINE`), `usms-enrolment-build-standalone` (S3 source, the Floci stand-in), `usms-results-build` (Exercise 1) |
| CodePipeline | `usms-enrolment-pipeline`, 2 stages, 6 executions |
| IAM | `usms-codebuild-role` + `USMSCodeBuildBase` (trust: `SourceAccount` + `SourceArn` on three projects, Exercise 3); `usms-codepipeline-role` + `USMSCodePipelineBase`; `usms-pipeline-trigger-role` + `USMSPipelineTriggerBase` (Exercise 4) |
| EventBridge | `usms-enrolment-src-change-s3` (ENABLED), `usms-enrolment-src-change-cloudtrail` (DISABLED), both targeting the pipeline (Exercise 4) |
| Local Docker | image `aws/codebuild/standard:7.0`, built from `labs/lab-11-cicd/codebuild-standin/Dockerfile` (not an AWS resource) |
| Files | the source trees, 6 policy documents, 7 templates, `configs/lab-11.env` (26 exports), the scripts in Section 3.10, `scripts/cleanup/lab-11-cleanup.sh` (never run); `.gitignore` gains `labs/lab-11-cicd/app/dist/` |

---

## 2. Evidence index

Six screenshots, each on one screen. Everything else is command output under `outputs/`
(git-ignored), quoted where it is used. The exercises came after the screenshots; their
evidence is `outputs/lab-11-ex*.txt` and [exercises.md](exercises.md).

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoints 1-2: Path A, every probe `ok`; versioning `Enabled`; tags; public access blocked on all four settings; five versions of the source key, one `True` | [3.1](#31-checkpoints-1-2---probe-and-artifact-store) |
| 02 | Checkpoints 3-4: the six-file source tree; both trusts with `aws:SourceAccount`; one policy per role; `USMSCodeBuildBase`'s three statements including the `Deny`; the PassRole statement scoped to one role and one service; the project, `CODEPIPELINE`, `standard:7.0`, the build role, 15 minutes | [3.2](#32-checkpoints-3-4---source-tree-identities-project) |
| 03 | Checkpoints 5-6: the stand-in image's label; a standalone build's eleven phases `SUCCEEDED`; its artifact (`release r3`, `buildId usms-enrolment-build:4`); the local runner, four phases, seven smoke tests, `buildId local`, exit 0 | [3.3](#33-checkpoints-5-6---a-real-build-and-the-local-runner) |
| 04 | Checkpoints 7-8: the pipeline's role, store and two stages; five executions with the source version each fetched; the read-back chain (version `aad2e4dd` contains `VERSION=r5`, 0 pipeline artifacts, standalone `release=r5`); 5 source versions, 0 BuildOutput objects | [3.4](#34-checkpoints-7-8---the-pipeline-and-what-it-consumed) |
| 05 | Checkpoint 9: the broken execution `Succeeded` on version `a1203c38`; that version's `"container": "enrolment-api-v2"`; the standalone build `FAILED` in `PRE_BUILD` with `config/service.json names the wrong container`; the fixed build `SUCCEEDED` | [3.5](#35-checkpoint-9---a-deliberate-failure-diagnosed) |
| 06 | Section 8 and Checkpoint 10: `PASS=46 FAIL=0`; 26 exports, all populated; `versioning=Enabled stages=2 source=CODEPIPELINE release=r5 path=A`; nothing under `outputs/`, no `.zip`, no `dist/`; `check-ignore` for the zip and `dist/`; `verify-lab-10` `51/0` | [3.7](#37-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-21)

### 3.1 Checkpoints 1-2 - probe and artifact store

**Steps 1-2: the environment.**
- **This repository's `floci-storage-check.sh`** is an older six-section version, with no
  `PASS=16` summary. Every section reports `[ok]`, and storage mode is `hybrid`.
- **Prerequisites:** `verify-lab-04` `39/0`, `verify-lab-05` `49/1` (the stale-rules-store
  failure documented in Lab 09), `verify-lab-10` `51/0`.
- **Environment files:** all ten source cleanly, including the optional `lab-09.env`. No
  value reads `MISSING`, and `USMS_ENROLMENT_CONTAINER` is `enrolment-api`.

**Step 3.** `scripts/utilities/cicd-support-probe.sh` is the guide's script, verbatim.
CodeDeploy answers too, which the guide says is rare.

**Steps 5-6.** The guide's commands, unchanged.
- **The proof:** two versions at `probe/versioning.txt` (`True 7`, `False 6`), both then
  deleted by version ID; the final count is `0` (`outputs/lab-11-step5-6.txt`).
- **The probe text file** was written to my scratch directory rather than `/tmp`.

![Checkpoints 1-2: cicd-support-probe.sh - codebuild list-projects, create-project accepted, probe project deleted, codepipeline list-pipelines, ecr and codedeploy all ok, PATH A recorded in outputs/lab-11-support-probe.txt; get-bucket-versioning Enabled; tags Project=USMS Tier=pipeline Lab=11; public access block True True True True; five versions of source/usms-enrolment-src.zip, aad2e4dd latest, then a1203c38, e0679ea1, 60883859, ee13d3a6](../../screenshots/lab11-01-checkpoints1-2-probe-artifact-store.png)

**Reading the screenshot.**
- **Versioning in the strongest available form:** five versions at the real source key,
  one per upload, rather than the two probe versions already deleted.
- **The sizes:** 2992 bytes for the unchanged releases; 2994 for the broken
  `service.json` written by `json.dump`; 2991 for the fix.

### 3.2 Checkpoints 3-4 - source tree, identities, project

**Step 7: the source tree.** The guide's files. `src/index.html` carries `__RELEASE__` and
`__BUILT_AT__`.

**Step 8: the buildspec, plus the "Your turn".**
- **The second `pre_build` check** fails the build if the port is not 80.
- **The obvious `grep '"port": 80'` is wrong:** it also matches `8080`, the test value the
  exercise prescribes. So the check used `'"port": 80([^0-9]|$)'` in a `- |` block.
- **Tested:** with `"port": 8080`, the local runner stopped in `pre_build` with
  `config/service.json: port must be 80 - the ALB target group and the task definition both expect 80. Set "port": 80 and rebuild.`
- **Parsing.** PyYAML is not installed, so the guide's parse check skipped. I validated
  the file with Ruby's YAML parser instead: version 0.2, four phases.

**Steps 9 and 15: the two identities.** The guide's documents, unchanged.
`USMSCodePipelineBase` reports default `v1` with 1 attachment.

**Step 10: the project.**
- **Written by lookup.** `scripts/utilities/write-lab-11-templates.sh project` writes the
  template from the role's ARN read from IAM, not from a shell variable, and refuses to
  write a hole: `0 unexpanded $`.
- **One deliberate difference:** the template has no `"buildspec": "buildspec.yml"`
  (Section 6.2).

**Step 18: the conversion.** The project was converted with the guide's own command,
`--source type=CODEPIPELINE,buildspec=buildspec.yml --artifacts type=CODEPIPELINE`.

![Checkpoints 3-4: the six files of labs/lab-11-cicd/app; usms-codebuild-role trusts codebuild.amazonaws.com with aws:SourceAccount 000000000000; usms-codepipeline-role trusts codepipeline.amazonaws.com with 000000000000; USMSCodeBuildBase and USMSCodePipelineBase attached; USMSCodeBuildBase statements WriteItsOwnBuildLogs Allow, ReadSourceAndWriteArtifacts Allow, BuildsDoNotTouchStudentRecords Deny; PassTheBuildRoleAndOnlyToCodeBuild Allow iam:PassRole on role/usms-codebuild-role with iam:PassedToService codebuild.amazonaws.com; usms-enrolment-build CODEPIPELINE CODEPIPELINE aws/codebuild/standard:7.0 role/usms-codebuild-role 15](../../screenshots/lab11-02-checkpoints3-4-source-identities-project.png)

**What the screenshot shows.**
- **The trusts at screenshot time.** Each shows one condition, `aws:SourceAccount`.
  Exercise 3 later added `aws:SourceArn` to the build role.
- **The policies are read back from IAM,** not from the files.

### 3.3 Checkpoints 5-6 - a real build, and the local runner

**Step 12: it took four builds to get one real one.**

| Build | Result | Why |
|---|---|---|
| `:1` | `FAULT` in `PROVISIONING` | `pull access denied for aws/codebuild/standard` - Floci pulls the image name from Docker Hub |
| `:2`, `:3` | `SUCCEEDED`, no artifact, no logs, ~30 ms | the project's `"buildspec": "buildspec.yml"` read as inline YAML with no phases |
| `:4` | `SUCCEEDED`, artifact `usms-enrolment-build-4.zip` | stand-in image, and the field omitted |

Section 6 has the diagnosis of each.

**The other Step 12 and 13 findings:**
- **The artifact key.** Floci writes `<project>-<build-number>.zip` at the bucket root.
  The project's `path: build` and `name` are ignored, so the guide's `build/` prefix stays
  empty.
- **The logs.** The log stream exists, but with zero events, the guide's "empty build
  logs" limitation.

**Step 14: the local runner.** `usms-buildspec-run.sh` is the guide's script.
- **Which parser:** PyYAML is absent, so it reports `built-in minimal parser`.
- **Which tools:** it runs on macOS with **BSD** sed (`install` prints `BSD sed`), which is
  why the buildspec's `sed -i.bak` form matters.
- **What it produced:** `dist/`, with `buildId: local`.

**Changed in Exercise 2.** The runner now implements `finally`. That is my change, not the
guide's, and it is described in [exercises.md](exercises.md).

![Checkpoints 5-6: aws/codebuild/standard:7.0 label "USMS Lab 11 local stand-in for aws/codebuild/standard:7.0 - not the real image"; usms-enrolment-build:4 phases SUBMITTED, QUEUED, PROVISIONING, DOWNLOAD_SOURCE, INSTALL, PRE_BUILD, BUILD, POST_BUILD, UPLOAD_ARTIFACTS, FINALIZING, COMPLETED all SUCCEEDED; artifact build-metadata release r3 buildId usms-enrolment-build:4 sourceVersion local; local runner built-in minimal parser 4 phases, release=r5, seven smoke tests ok, smoke tests failed 0, buildId local, exit status 0](../../screenshots/lab11-03-checkpoints5-6-build-and-local-runner.png)

**Reading the screenshot.**
- **The first line is deliberate.** The image the build ran in is shown to be the
  stand-in, not AWS's.
- **The two `buildId`s** (`usms-enrolment-build:4` and `local`) are exactly the guide's
  distinction between "the build passed" and "the build passed locally".
- **The two releases differ:** the CodeBuild artifact is r3 (Step 12), and the local run
  is r5 (screenshot time).
- **`sourceVersion` is `local`** even for the CodeBuild build, because Floci does not set
  `CODEBUILD_RESOLVED_SOURCE_VERSION`.

### 3.4 Checkpoints 7-8 - the pipeline, and what it consumed

**Step 17.** `create-pipeline` from the template written by lookup gave two stages. **No
execution started**, where real AWS starts one at creation: `list-pipeline-executions` was
empty, and both stage states were `null`.

**Step 18.** On Floci, `start-build` on the `CODEPIPELINE` project is **accepted** (build
`:5`), where real AWS refuses it. It then fails at `DOWNLOAD_SOURCE`. The override flags
are accepted and ignored: build `:6` still reports source type `CODEPIPELINE`. That goes in
the "recorded, not observed" list.

**Step 19, in the order it happened:**
1. **Without a buildspec field** (my first attempt), the pipeline's build failed with
   `No buildspec found in source or request` (execution `f3d24662`).
2. **With the guide's `buildspec=buildspec.yml`**, the execution succeeded (`47b03a20`).
   But the build container lived 28 ms, the same as the empty builds of Section 3.3, and
   no `BuildOutput` was written.
3. **A throwaway pipeline** confirmed it. Inside a pipeline-driven build:
   - `test -n "$CODEBUILD_SRC_DIR"` passes
   - `test -f "$CODEBUILD_SRC_DIR/VERSION"` fails
   - `test -f /codebuild/output/src/src/VERSION` fails
   - `test -n "$(ls -A .)"` fails

   **The source directory is empty.**

**The read-back, rebuilt.** What Floci **does** record is exact: every execution's Source
action records the S3 version ID it fetched. `scripts/utilities/lab-11-pipeline-readback.sh`
assembles the chain from that:
1. the execution and its fetched version
2. that exact version, downloaded by version ID, with the `VERSION` inside it
3. the number of pipeline artifacts, 0 on this build
4. the newest artifact from `usms-enrolment-build-standalone`, a real CodeBuild build of the
   same key

![Checkpoints 7-8: pipeline role usms-codepipeline-role and store usms-pipeline-artifacts; stages Source S3 None SourceOutput and Build CodeBuild SourceOutput BuildOutput; executions bfb10dda Succeeded aad2e4dd, 2bb1edae Succeeded a1203c38, dd04531d Succeeded e0679ea1, 47b03a20 Succeeded 60883859, f3d24662 Failed 60883859; read-back: execution bfb10dda Succeeded, Source fetched S3 version aad2e4dd, Build ran usms-enrolment-build:11, that version contains VERSION=r5, 0 objects under usms-enrolment-pipeline/, standalone artifact usms-enrolment-build-standalone-4.zip release=r5 buildId usms-enrolment-build-standalone:4; 5 source versions; 0 BuildOutput objects](../../screenshots/lab11-04-checkpoints7-8-pipeline-readback.png)

**Reading the guide's four checks against the screenshot:**
- **`release` is r5 (Checkpoint 8),** and it comes from the exact source version the
  execution recorded. That is stronger than "the newest object", because it is tied to the
  execution.
- **`buildId` is not `local`:** `usms-enrolment-build-standalone:4` is a real CodeBuild
  build. It is not the pipeline's build, and I say so.
- **The artifact root is the files,** with no `dist/` prefix.
- **`srcVersion` cannot match,** because Floci leaves it unset.

**The "Your turn" counts.** Five source versions against zero BuildOutput objects; the
explanation is in `notes/lab-11-notes.md`.

### 3.5 Checkpoint 9 - a deliberate failure, diagnosed

**Step 20's break.** `container` set to `enrolment-api-v2`, packed, uploaded (version
`a1203c38`), and the pipeline started (execution `2bb1edae`).

**The pipeline went green on broken source.** Both stages `Succeeded`, because its build
never saw `config/service.json`.

**I ran the same source through the twin,** a build that receives it, and diagnosed it the
guide's way, stage to build to phase to command:

![Checkpoint 9: execution 2bb1edae Succeeded on source version a1203c38; that version's config/service.json has "container": "enrolment-api-v2"; usms-enrolment-build-standalone:3 FAILED; failed phases PRE_BUILD, POST_BUILD, COMPLETED; PRE_BUILD context "Exit code 1: --- pre_build --- config/service.json names the wrong container"; after the fix usms-enrolment-build-standalone:4 SUCCEEDED](../../screenshots/lab11-05-checkpoint9-failure-diagnosed.png)

**What the screenshot proves:**
- **The input was broken:** the version the execution recorded contains the wrong
  container name.
- **The pipeline did not notice:** `Succeeded`.
- **A real build did:** `PRE_BUILD FAILED`. On this build `contexts[0].message` holds the
  failing command's own output, so the diagnosis reaches the command in one query.
- **The fix passed.** It was validated locally first ("local build passes again"), then
  uploaded (version `aad2e4dd`) and rebuilt.

**Two Floci deviations visible here:**
- **`POST_BUILD` also `FAILED`.** Floci ran `post_build` after a failed `pre_build`, where
  real CodeBuild goes to finalizing. So the smoke tests ran against an empty `dist/`.
- **Two placeholder tests "passed" on missing files** (`outputs/lab-11-step20.txt`):
  `! grep -q __RELEASE__ dist/index.html` is true when the file does not exist. That is a
  weakness in the guide's `smoke.sh`, harmless only because the existence tests run first.

**Checkpoint 9's sequence, as it actually ran:**

| Execution | Source | Result |
|---|---|---|
| (none at creation) | - | Floci starts none |
| `f3d24662` | r4 `60883859` | Failed: no buildspec (project without the field) |
| `47b03a20` | r4 `60883859` | Succeeded |
| `dd04531d` | r5 `e0679ea1` | Succeeded (the "Your turn") |
| `2bb1edae` | broken `a1203c38` | **Succeeded** - the pipeline cannot see it; `standalone:3` FAILED in PRE_BUILD |
| `bfb10dda` | fixed `aad2e4dd` | Succeeded; `standalone:4` SUCCEEDED |
| `80ffda4d` | r6 `0548c920` | Succeeded (after the exercises); `standalone:7` SUCCEEDED |

### 3.6 The standalone twin, and why it does not hide anything

`usms-enrolment-build-standalone` is the Step 10 project under a second name, which keeps
its S3 source (`write-lab-11-templates.sh standalone`). It exists only because of Floci's
empty pipeline source.
- **It is not exported** in `configs/lab-11.env`.
- **The cleanup script deletes it.**
- **It has one limitation:** it builds the **newest** object. `--source-version` is ignored,
  as tested: asked for r3, it built r4. So the read-back ties releases to executions through
  the execution's recorded version, not through the twin.

The guide's pipeline and project are exactly as written: `CODEPIPELINE`, with
`buildspec=buildspec.yml`.

### 3.7 Verification and hygiene

**Step 21: the env file.** `scripts/utilities/write-lab-11-env.sh` writes
`configs/lab-11.env`: the guide's 26 exports and sentinels, from any directory. It stops if
a must-succeed lookup returns empty or `None`.

**Section 8.1: `verify-lab-11.sh`.** The guide's 46 checks, with the same one adaptation
Lab 10 needed: "no secret is tracked" ignores exactly `outputs/.gitkeep`, which Lab 01
tracks on purpose.

![Section 8: verify-lab-11.sh section headers only and PASS=46 FAIL=0; 26 exports; all values populated; versioning=Enabled stages=2 source=CODEPIPELINE release=r5 path=A; nothing under outputs/, no .zip, no dist/, no root .env; .gitignore:8:outputs/* for usms-enrolment-src.zip and .gitignore:41:labs/lab-11-cicd/app/dist/ for dist/build-metadata.json; git ls-files outputs/ only outputs/.gitkeep; verify-lab-10.sh PASS=51 FAIL=0](../../screenshots/lab11-06-verify-env-and-hygiene.png)

**Read with Section 3.4 in mind, `PASS=46` is the weakest evidence in this report.**
- **The checks are existence and configuration only.** Every "CodeBuild" and "CodePipeline"
  check asks whether something exists or is configured; none asks whether a pipeline build
  built anything.
- **So it passes on this build** even though the pipeline builds nothing.
- **What would close the gap:** a check that downloads the newest `BuildOutput` and finds
  `build-metadata.json` in it. That check would fail here, honestly.

**After the exercises.**
- `configs/lab-11.env` was regenerated: release `r6`, source version `0548c920`.
- `verify-lab-11.sh` again `46/0` (`outputs/lab-11-verify-final.txt`).
- The IAM audit, on a fresh inventory, `HIGH=0 MED=39 ACCEPTED=7 roles=17`. The three new
  roles each have only the MED "no permissions boundary".

**Section 8.2: `scripts/cleanup/lab-11-cleanup.sh`.** The guide's script, with additions:
- it also deletes `usms-enrolment-build-standalone` and `usms-results-build`
- it prints the `docker rmi` for the stand-in image

It has passed `bash -n` and has **not** been run.

**Step 21's commit is left to me,** as in every lab.

### 3.8 Files

| File | Purpose |
|---|---|
| `labs/lab-11-cicd/app/` | `VERSION` (r6), `buildspec.yml`, `config/service.json`, `src/index.html`, `src/healthz.html`, `tests/smoke.sh` (8 assertions) |
| `labs/lab-11-cicd/app-results/` | Exercise 1's results service |
| `labs/lab-11-cicd/codebuild-standin/Dockerfile` | the local `aws/codebuild/standard:7.0` stand-in (Section 6.1) |
| `policies/trust-codebuild.json`, `usms-codebuild-policy.json` | build identity (trust tightened in Exercise 3) |
| `policies/trust-codepipeline.json`, `usms-codepipeline-policy.json` | pipeline identity |
| `policies/trust-events-pipeline-trigger.json`, `usms-pipeline-trigger-policy.json` | Exercise 4's trigger identity |
| `templates/lab-11-codebuild-project.json`, `-codebuild-project-standalone.json`, `-results-build-project.json`, `-pipeline.json` | request bodies, written by lookup |
| `templates/lab-11-source-change-rule.json`, `-rule-s3.json`, `-targets.json` | Exercise 4 |
| `configs/lab-11.env` | 26 exports |
| `scripts/utilities/cicd-support-probe.sh` | Step 3 |
| `scripts/utilities/usms-pack-source.sh` | Step 11 |
| `scripts/utilities/usms-buildspec-run.sh` | Step 14, plus `finally` (Exercise 2) |
| `scripts/utilities/write-lab-11-templates.sh` | `project`, `standalone`, `results`, `pipeline` |
| `scripts/utilities/usms-wait-build.sh` | a deterministic wait on a build, replacing the guide's `sleep 10` loops |
| `scripts/utilities/lab-11-pipeline-readback.sh` | Step 19's proof, rebuilt from what Floci records |
| `scripts/utilities/write-lab-11-env.sh`, `verify-lab-11.sh` | Step 21, Section 8.1 |
| `scripts/utilities/lab-11-readiness.sh` | Exercise 5's `outputs/lab-11-lab08b-readiness.txt` |
| `scripts/cleanup/lab-11-cleanup.sh` | Section 8.2, never run |
| `notes/lab-11-notes.md` | path, "Your turn" answers, review questions |

---

## 4. Exercises 1-5

Full commands, output and reasoning are in [exercises.md](exercises.md).

1. **`usms-results-build`.**
   - **Built:** a standalone build of `labs/lab-11-cicd/app-results`, reusing the build
     role; its artifact says `"service":"results"`.
   - **Does `USMSCodeBuildBase` permit it?** For S3, yes. For logs, no: the policy names
     only the enrolment log group. So the project logs to that group under its own stream,
     which keeps the policy at v1 for Lab 12.
2. **`finally`.**
   - **The buildspec is valid,** but **Floci never runs `finally`** (probed with a passing
     and a failing phase).
   - **I extended the local runner** to implement the documented semantics, where a broken
     test gives `tests_exit=1` in `dist/build-summary.txt` while the build still fails.
   - **The claim** is "passed locally", stated as such.
3. **Parsed, not grepped.**
   - **Format-blind:** passes with four-space indentation and compact separators.
   - **Specific:** names expected and actual for container and port in one run.
   - **The trust:** gains `aws:SourceArn`, listing all three projects that share the role.
4. **Event-driven trigger.**
   - **Documents:** CloudTrail and S3-native patterns, each matching one key; a target; and
     a trigger role scoped to `StartPipelineExecution` on one pipeline.
   - **What ran:** the S3 event was emitted and matched, and was captured through a
     throwaway SQS target (`Object Created`, carrying the version ID).
   - **What did not run:** Floci's EventBridge refuses CodePipeline targets
     (`unsupported target ARN type`), so the upload started nothing.
5. **`imagedefinitions.json`.**
   - **The file:** a one-entry array; container from `service.json`; `IMAGE_URI` defaulting
     to the image the service runs today.
   - **The test:** an eighth smoke assertion, with a negative test.
   - **The readiness file:** `outputs/lab-11-lab08b-readiness.txt`, generated by script. It
     tells Lab 12 that this build stores no `BuildOutput`.

---

## 5. Review questions

Answered in prose in [notes/lab-11-notes.md](../../notes/lab-11-notes.md#review-questions-section-14):

1. **Green pipeline, unchanged application.** A `base-directory` mismatch (an output
   problem) versus a zip with an `app/` prefix (an input problem). One `unzip -l` on each
   tells them apart. Floci added a third: a build with an empty source.
2. **Why an S3 source must be versioned.** Every execution records the version ID it
   fetched; without versioning there is no stable input to record.
3. **`iam:PassRole`.** Creating a build is not the same as choosing whose permissions it
   runs with.
4. **Two roles.** They limit the blast radius. But the build role can still poison the
   source and the artifact that the pipeline trusts.
5. **Heredocs.** Each wrong form produces valid output with the wrong content, so nothing
   errors.
6. **Removing `pre_build` validation.** Right only if the later check is as fast and as
   cheap. Floci's green-on-broken pipeline is the counter-example.
7. **The audit chain.** Version ID, execution, build, metadata. The weakest link is
   working tree to zip: no commit hash.

---

## 6. Problems encountered

### 6.1 Every build ended `FAULT`: no `aws/codebuild/standard:7.0`

**The symptom.** Build `:1` reached `COMPLETED FAILED` with the context
`pull access denied for aws/codebuild/standard, repository does not exist`.

**The cause.** Floci runs each build in a Docker container whose image is exactly the
project's `environment.image`. AWS serves that image only inside CodeBuild, and Docker Hub
has no such repository. The Floci binary has no image-mapping setting:
`floci.services.codebuild.*` offers only `enabled` and `docker-network`.

**The fix.** `labs/lab-11-cicd/codebuild-standin/Dockerfile` is `FROM python:3.12-slim`,
labelled as a stand-in, and tagged `aws/codebuild/standard:7.0` on the local daemon. Floci
then logs `Image already present locally, skipping pull`.

**Why this form.** The project document stays exactly what real AWS accepts. The cost is
that builds run on Debian with Python 3.12, not Ubuntu 22.04 with every runtime, and that
is shown on screen in screenshot 03.

### 6.2 Three ways a build "succeeded" without building

**1. An inline-buildspec misreading** (builds `:2`, `:3`).
- **What happened:** with `"buildspec": "buildspec.yml"` on an S3-source project, the
  container lived about 30 ms; the real build `:4` took about 200 ms. There were no
  artifacts and no logs.
- **The probe:** a project without the field built correctly, giving `release r3` and the
  placeholders replaced.
- **The fix:** the template omits the field. On real AWS an absent `buildspec` means
  `buildspec.yml` at the source root, which is what the value meant.

**2. A pipeline build with no source** (builds `:8` to `:12`).
- **What happens:** for a `CODEPIPELINE` project, Floci needs the field as a **file name**.
  Without it, it fails `No buildspec found in source or request`. With it, the build finds
  no file in an empty directory and runs nothing.
- **The probes:** four throwaway pipeline runs established that the directory is empty.
  Nothing is written to `SourceOutput/` or `BuildOutput/`.
- **What I did:** documented it, and evidenced the build through the twin (Section 3.6).
  Lab 12's deploy stage will meet the same wall.

**3. A green pipeline on broken source** (execution `2bb1edae`). This is a consequence of
2, and the most important line in the report for anyone who trusts a pipeline's colour.

### 6.3 What I could not demonstrate, and why

- **`finally`.** Floci does not execute it (Exercise 2).
- **EventBridge starting the pipeline.** Floci refuses CodePipeline (and CloudWatch Logs)
  targets (Exercise 4).
- **Build logs.** Every log stream is empty. Evidence came from phases, `contexts`, and
  artifacts.
- **`CODEBUILD_RESOLVED_SOURCE_VERSION`.** It is not set, so `sourceVersion` is always
  `local`.

### 6.4 Smaller ones

- **The minimal parser keeps YAML quotes,** so a quoted list item reaches bash as one word
  (found in Exercise 1). Use `- |` blocks.
- **`grep '"port": 80'` matches `8080`** (Step 8's "Your turn").
- **The CLI shorthand cannot carry a multi-line buildspec with quotes,** so the probe
  projects were sent with `--cli-input-json`.
- **The guide's polling loops use `sleep 10`.** `usms-wait-build.sh` replaces them with one
  deterministic wait.
- **Throwaway resources.** Eight probe projects, one probe pipeline, their log groups and
  artifacts, one SQS queue and one log group were all created for diagnosis and deleted. The
  only lasting additions are listed in Section 1.

---

## 7. Floci limitations versus real AWS

**Observed:**
- the zip layout
- four buildspec phases running in a container
- the smoke tests passing and failing
- an artifact naming the release
- a `PRE_BUILD` failure diagnosed to the command
- versioning, as nine versions at one key
- every pipeline execution recording the exact S3 version it fetched
- S3 emitting `Object Created` to EventBridge, and a one-key pattern matching it

**Recorded, not enforced:**
- the build role's scoping
- the explicit Deny
- the scoped `iam:PassRole`
- the single project ARN
- the trust conditions, including Exercise 3's `aws:SourceArn`

**Recorded, not observed:**
- a pipeline build consuming its input artifact
- a stored `BuildOutput`
- `start-build` being refused for a `CODEPIPELINE` project
- the automatic execution at creation
- `finally`
- EventBridge starting the pipeline
- build logs

**Not available at all:** CloudTrail-driven triggers, approvals, build reports and
KMS-encrypted artifacts.

| Behaviour | Real AWS | Floci 2.2.0, as observed |
|---|---|---|
| `aws/codebuild/standard:7.0` | Managed, cached | Pulled from Docker Hub, which fails; needs a local stand-in |
| Project `buildspec: buildspec.yml`, S3 source | A path in the source | Parsed as inline YAML; runs nothing |
| Project `buildspec`, `CODEPIPELINE` source | A path in the input artifact | Needed as a file name; the source is empty anyway |
| Artifact location | `path/name` as configured | `<project>-<n>.zip` at the bucket root |
| Pipeline artifacts | `SourceOutput/`, `BuildOutput/` zips in the store | None stored |
| Execution at `create-pipeline` | Starts immediately | None |
| `start-build` on a `CODEPIPELINE` project | Refused | Accepted; fails at `DOWNLOAD_SOURCE`; overrides ignored |
| `--source-version` on an S3 project | Builds that version | Ignored; builds the latest |
| Failed `PRE_BUILD` | Skips to finalizing | Runs `POST_BUILD` anyway |
| `finally` | Always runs | Never runs |
| `contexts` on a failed phase | Present | Present, with the command's output |
| Build logs | Every line | Empty streams |
| EventBridge -> CodePipeline target | Starts an execution | `unsupported target ARN type` |
| S3 -> EventBridge `Object Created` | Delivered | Delivered, with the version ID |

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh
docker build -t aws/codebuild/standard:7.0 labs/lab-11-cicd/codebuild-standin   # once per machine
source configs/course.env
source configs/lab-11.env
./scripts/utilities/verify-lab-11.sh                     # PASS=46  FAIL=0
./scripts/utilities/usms-buildspec-run.sh labs/lab-11-cicd/app
./scripts/utilities/lab-11-pipeline-readback.sh
./scripts/utilities/lab-11-readiness.sh
```

The stand-in image is not in Floci's data directory, so it must be rebuilt on any new machine
before a build can run.
