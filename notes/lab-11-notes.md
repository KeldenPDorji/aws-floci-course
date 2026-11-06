Support path: A (probe, Step 3) - CodeBuild runs for real; CodePipeline runs but its builds receive no source (Path B for the pipeline's artifact).

# Lab 11 - Building a CI/CD pipeline with CodePipeline and CodeBuild - my notes

## What the probe said, and what was true

`cicd-support-probe.sh` reported **Path A**: CodeBuild, CodePipeline, ECR and CodeDeploy all
answer. The guide warns that CodeDeploy is usually absent; here it is not.

Path A was only partly true. The probe creates a project and lists pipelines; it never runs
either. What running them showed:

| What | Observed on Floci 2.2.0 |
|---|---|
| A CodeBuild build | Runs in a real Docker container, but only after I built a local image tagged `aws/codebuild/standard:7.0`. Floci pulls that name from Docker Hub, where it does not exist, so build 1 ended `FAULT` before `INSTALL` |
| `"buildspec": "buildspec.yml"` on an S3-source project | Read as an **inline** buildspec. The string has no phases, so builds 2 and 3 "succeeded" in about 30 ms, ran nothing, and produced no artifact |
| The same field on a `CODEPIPELINE`-source project | Read as a **file name**. Without it, a pipeline build fails `DOWNLOAD_SOURCE: No buildspec found in source or request` |
| A pipeline's Build action | Gets an **empty** source directory (`CODEBUILD_SRC_DIR` set, nothing in it), and no `SourceOutput` or `BuildOutput` is stored. With the buildspec found and nothing to build, the action "succeeds" |
| Artifact key of a standalone build | `<project>-<build-number>.zip` at the bucket root; `path` and `name` are ignored |
| Build logs | Log group and stream created, **zero** events |
| `contexts[0].message` on a failed phase | Present, and it contains the failing command's own output |
| A failed `pre_build` | Floci still runs `post_build` (real CodeBuild goes to finalizing) |
| `finally` | Never executed |
| `start-build` on a `CODEPIPELINE` project | Accepted (real AWS refuses), then fails at `DOWNLOAD_SOURCE`; `--source-type-override` / `--source-location-override` / `--source-version` are accepted and ignored |
| `create-pipeline` | Starts **no** execution (real AWS starts one immediately) |
| A Source action | Records the exact S3 **version ID** it fetched, as `externalExecutionId`, in `artifactRevisions`, and in `sourceRevisions` |

## Step 8 "Your turn" - the port check

The obvious pattern is wrong: `grep -q '"port": 80'` also matches `"port": 8080`, the very
value the exercise tells you to test with, because `80` is a prefix of `8080`.

My check used `grep -qE '"port": 80([^0-9]|$)'`, inside a `- |` block because the pattern
contains `": "`. Its message names the fix and the reason:

```text
config/service.json: port must be 80 - the ALB target group and the task definition both expect 80. Set "port": 80 and rebuild.
```

With `"port": 8080` the local runner stopped in `pre_build` with that message and exit 1;
restored, it passed. Exercise 3 later replaced both greps with a parse.

## Step 9 - the explicit Deny, in one sentence

`BuildsDoNotTouchStudentRecords` makes "builds never read or write student records" a
statement that survives any later Allow, because in IAM an explicit Deny always wins. Even
if a future policy version or a second attached policy grants `s3:*` on `*`, the build role
still cannot reach `usms-student-data`. On Floci nothing is enforced, so here it is a
documented intent, not an observed refusal.

## Step 15 - `Resource "*"` with the condition kept

If `USMSDeployBase`'s PassRole statement had `"Resource": "*"` but kept
`iam:PassedToService: [ec2.amazonaws.com, ecs-tasks.amazonaws.com]`, the condition would
still limit **which service** receives a role. It would no longer limit **which role**. An
attacker holding the deploy role could then pass any role in the account that EC2 or ECS
tasks will assume.

The one I would name is **`usms-eks-node-role`**:
- It trusts `ec2.amazonaws.com`, and it is not one of the three listed ARNs.
- It carries `USMSStudentDataReadWrite` and `USMSEKSNodePolicy`.
- So: launch one instance with that role's profile, and the instance can read, write and
  delete every transcript, and create and delete network interfaces.

The same attack works with any role added later that trusts EC2 or ECS tasks, however
powerful. The condition fixes the destination; only the `Resource` list fixes the cargo.

## The nested-heredoc rule

**Quoted writes text, unquoted writes the result.**
- `<< 'BUILDSPEC'` puts `$USMS_RELEASE` into the file literally, for CodeBuild to expand.
- The inner `<< META` expands at build time.
- `<< EOF` in Step 21 expands at write time, so `configs/lab-11.env` holds values, not
  commands.

## Step 19 "Your turn" - versions versus BuildOutput objects

At r5, from command output:

```text
source versions:     3   (r3 ee13d3a6, r4 60883859, r5 e0679ea1)
BuildOutput objects: 0
pipeline executions: 3   (f3d24662 Failed on 60883859, 47b03a20 Succeeded on 60883859, dd04531d Succeeded on e0679ea1)
```

The two counts measure different things.
- **Source versions** count **uploads**: every `put-object` to the key makes one, whether
  or not anything ran.
- **BuildOutput objects** count **executions whose Build action produced an artifact**: on
  real AWS, one per successful Build action.

**Why they need not be equal:**
- **An upload with no execution.** `PollForSourceChanges` is `"false"` and Exercise 4's
  trigger cannot start the pipeline on Floci, so uploading does not run anything by
  itself.
- **Two executions of one version.** `f3d24662` and `47b03a20` both fetched `60883859`,
  because I re-ran after fixing the project's buildspec setting.
- **Failed executions.** `f3d24662` failed at Build and produced nothing.
- **On real AWS, the automatic execution at `create-pipeline`** would add one more. Floci
  started none.
- **On Floci, the BuildOutput count is always 0,** because its pipeline stores no artifacts
  at all.

At the end of the lab: **9** source versions, **6** executions, **0** BuildOutput objects.
Three of the versions are r6 uploaded three times by Exercise 4's trigger tests, which
started nothing.

## Exercise 3 - what `aws:SourceArn` closes that `aws:SourceAccount` does not

**What `aws:SourceAccount` already gives.** It says CodeBuild may assume
`usms-codebuild-role` only when acting for a resource in account `000000000000`. That stops
another AWS customer's project from using our role: the cross-account confused deputy.

**What it leaves open is in-account.** Any project in this account could run as this role.
- **The attack:** a developer with `codebuild:CreateProject` (and, on real AWS, PassRole on
  this role) creates `scratch-build` with `usms-codebuild-role` as its service role and a
  buildspec of their choosing.
- **What it gives them:** their arbitrary commands run with the artifact store's
  read/write. They can overwrite `source/usms-enrolment-src.zip`, or plant a doctored
  `BuildOutput` that Lab 12 would deploy.
- **What `SourceArn` does:** it binds the role to the named projects, so CodeBuild refuses
  to assume it for any other project, even inside the account.

The condition lists three project ARNs, because three projects share the role. Fewer shared
roles would mean shorter lists.

---

## Review questions (Section 14)

### 1. Source and Build succeed, and the deployed application is unchanged

**Explanation 1: `artifacts.base-directory`.**
- **The cause:** `base-directory` does not match where the build wrote its files, for
  example `dist` when the build wrote to `build/`. CodeBuild then uploads an empty or
  irrelevant artifact.
- **Why it still looks green:** with `files: ['**/*']` and a non-matching base directory,
  the build can succeed with an artifact that has no `index.html` or
  `imagedefinitions.json`, and the deploy has nothing new to apply.
- **The one command:** list the artifact itself:
  `unzip -l <downloaded BuildOutput zip>`. It is empty, or the expected files are missing,
  or they sit under `dist/`.

**Explanation 2: the zip's internal layout.**
- **The cause:** the source was zipped as `app/...` instead of from inside `app/`, so the
  build root has no `VERSION`, `src/` or `buildspec.yml` at the top.
- **How it slips through:** this normally fails with `YAML_FILE_ERROR`. If the buildspec
  were supplied inline (or, as on Floci, never read from the source), the build "succeeds"
  having built nothing, or built an old `dist/` that shipped inside the source.
- **The one command:** `unzip -l outputs/usms-enrolment-src.zip`, where every path starts
  with `app/`.

**Telling them apart.** The first is a problem with the **output**, the second with the
**input**. So list the source zip first; if it is correct, list the artifact.

Floci gave a third, real-world-instructive variant. The Build action "succeeded" while its
build received an **empty** source directory. Only the artifact, or here its absence,
exposes that.

### 2. Why an S3 source must be versioned

**An execution is a record of exactly which input it processed.** When the Source action
runs, it records the source revision: for S3, the object's **version ID**. I saw this in
`artifactRevisions[0].revisionId` and `sourceRevisions`, equal to the `VersionId` that
`put-object` returned.

**Without versioning, there is no such identity.**
- **No identifier to record.** An unversioned key has only "whatever is there now", so the
  execution can record nothing that names its input.
- **Later stages can see different bytes.** A later stage, a retry, or a stage re-run
  reading the same key could get bytes uploaded after the execution started.
- **History loses its link to input.** "Execution X succeeded" would no longer say on which
  input.

With versioning, every execution is pinned to one immutable object version. Retries,
approvals and later stages all refer to the same bytes, and the history means something.
Rollback is a consequence of that, not the reason.

### 3. `iam:PassRole` for someone who thinks it is redundant

Their objection, "I can already create the project, why separately approve the role?", is
reasonable, because both permissions feel like "setting up the build".

**The difference is whose permissions the build will run with.** `codebuild:CreateProject`
lets you describe a build. The role you name decides what that build may do, and it is not
your own permissions: it is the role's.
- **Without a separate check,** anyone allowed to create projects could name the most
  powerful role in the account, say an admin role trusted by CodeBuild, then put
  `aws iam create-user ...` in a buildspec, and CodeBuild would run it with admin rights.
  They would have escalated from "can create builds" to "can do anything" without ever
  being granted anything.
- **`iam:PassRole` closes that gap.** It asks whether you are allowed to hand **this**
  role to **this** service. Scoped to one role ARN, with `iam:PassedToService`, it means
  "you may create builds, and they may only run as the build role".

It is the same reason a manager who can schedule work cannot sign that work off as the
finance director.

### 4. Two roles or one

**For two roles: the blast radius follows the job.**
- **The pipeline role** reads every artifact, starts one build project, and passes one role.
- **The build role** writes logs and reads and writes one bucket, with an explicit Deny on
  student data.
- **A compromised build** runs arbitrary commands from a source zip that anyone with
  `PutObject` can change, so the build role is the one most likely to be abused. It
  therefore must not be able to start other builds, pass roles, or (in Lab 12) update ECS
  services.
- **Separate trust policies** mean each service can assume only its own role, and
  CloudTrail shows which identity did what.
- **Lab 12 depends on it:** the pipeline gains `ecs:UpdateService` and another PassRole,
  and none of that should reach the build container.

**The strongest argument against.** In this design the build role already holds most of
what matters. It can overwrite the source zip and write the build artifact, and the pipeline
trusts both. A compromised build can therefore make the pipeline deploy whatever it wants,
without needing any of the pipeline role's extra permissions. The split gives real
protection against a role **being used directly**, but little against the build poisoning
what flows downstream. To make the separation meaningful you also need:
- the build role's write access limited to its own output prefix, not the whole bucket
  including `source/`
- an integrity check, such as a signature or a recorded checksum, between build and deploy

Until then, two roles is partly ceremony, with one more set of documents to keep in sync.

### 5. The three heredoc forms

- **`<< 'BUILDSPEC'` (quoted), if unquoted.** The shell would expand `$USMS_RELEASE`,
  `$BUILT_AT`, `$ARTIFACT_DIR` and `${CODEBUILD_BUILD_ID:-local}` **while writing the
  file**, when they are empty or have the laptop's values. The buildspec would then contain
  `"release": ""`, `buildId: "local"` and `mkdir -p ""`.
  - **No error:** it is still valid YAML and still runs. The first sign is a smoke test, or
    an artifact with an empty release.
- **`<< META` (unquoted, inside the buildspec), if quoted.** `build-metadata.json` would
  contain the literal text `"$USMS_RELEASE"` instead of `"r4"`.
  - **No error:** the JSON is still valid, and `json.tool` passes. Only a reader of the
    metadata, such as Step 19's read-back, notices that the release is a variable name.
- **`<< EOF` in Step 21 (unquoted), if quoted.** `configs/lab-11.env` would contain
  `export USMS_SOURCE_VERSION_ID=$(aws s3api head-object ...)` as text.
  - **No error:** sourcing it later would **run** those commands (in a terminal that may
    not have the right profile) instead of reading recorded values. Nothing fails, and the
    "record" silently becomes a live query.

**Why no message tells you:** all three are legal input for every tool involved. The shell
does exactly what it was told. Only checking the output against the intent catches it.

### 6. Removing `pre_build`'s configuration validation

**They are right when:**
- the deploy stage really validates the same thing, the same way, and fails fast, **and**
- a failure there costs no more than a failure in the build

For example, with a pipeline that deploys only to a disposable test environment, where a bad
deploy rolls back in seconds and touches nobody. Then the check is duplicated effort and one
more thing to keep in sync.

**They are expensively wrong when the deploy is the first place anything notices:**
- **The deploy may not fail at all.** In Lab 12, ECS takes `imagedefinitions.json`'s
  container name. A wrong name is reported in terms that do not name the container, and
  only after the deployment has started.
- **The cost of failing late is higher.** A late failure means minutes of rollout, possibly
  a partial deploy, alarms and on-call time, against the build's seconds.
- **Not every consumer validates.** A file can also be copied, cached or reused by a
  consumer that does not validate.

**Floci made the point concretely.** Step 20's broken container name sailed through the
pipeline green, because its build received no source. The only thing that caught it was
`pre_build` in a build that actually ran.

**The general rule:** validate where it is cheapest, and do not count on a later stage's
check unless you have seen it fail.

### 7. Proving release r4 was built from a given day's source

**The evidence chain, using what this lab created:**
1. **The source object.** `source/usms-enrolment-src.zip` version `60883859-...`, with its
   `LastModified` (`2026-11-06T02:32:09Z`). Its contents, downloaded by version ID, contain
   `VERSION=r4` and the exact `buildspec.yml`.
2. **The pipeline execution.** `47b03a20-...`, whose Source action's
   `revisionId`/`externalExecutionId` is that version ID, and whose Build action names
   build `usms-enrolment-build:8`.
3. **The build record.** `batch-get-builds` for that ID: its phases, image, project and
   role.
4. **The artifact.** Its `build-metadata.json` carries `release`, `builtAt`, `buildId` and
   `sourceVersion`.

**The weakest link is between "the repository on that date" and the uploaded zip.**
`usms-pack-source.sh` zips a **working tree**, not a commit:
- **No identity of its origin.** Nothing in the zip, its metadata or the S3 object records
  a commit hash, and the tree may have had uncommitted edits.
- **Anyone with write access.** Anyone with `s3:PutObject` on the bucket, which includes the
  build role, could have uploaded it.

**The fix:**
- embed `git rev-parse HEAD`, and a dirty-tree flag, in the zip and in `build-metadata.json`
- pin source uploads to a separate identity
- for the strongest form, sign the zip or use S3 Object Lock

**On this Floci build the chain has two more breaks, which I would have to declare:**
- **The `sourceVersion` field reads `local`,** because Floci does not set
  `CODEBUILD_RESOLVED_SOURCE_VERSION`.
- **The pipeline's own build artifact does not exist.** Link 4 comes from the standalone
  twin, which builds the **latest** object and ignores `--source-version`. It is not
  pinned to the execution.
