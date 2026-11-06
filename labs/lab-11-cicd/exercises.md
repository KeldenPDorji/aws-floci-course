# Lab 11 - Independent Exercises 1-5

All five were done on Floci 2.2.0 after the six screenshots. Raw output is in
`outputs/lab-11-ex*.txt` (git-ignored).

Three Floci behaviours, found during the main lab, decide how several exercises could be
evidenced. They are described in full in [lab-11-report.md](lab-11-report.md) Section 6:

- **The pipeline's builds receive no source.** CodePipeline runs, but the CodeBuild action
  it triggers gets an empty source directory, and no `SourceOutput` or `BuildOutput` object
  is ever stored. Real builds of the source key come from `usms-enrolment-build-standalone`,
  a twin of the project that keeps its S3 source.
- **Floci 2.2.0 does not run `finally` blocks**, at all.
- **EventBridge cannot deliver to a CodePipeline target.** It accepts the target and then
  logs `unsupported target ARN type: arn:aws:codepipeline:...`.

**End state:**
- **Source and build:** release `r6`, with nine versions of `source/usms-enrolment-src.zip`.
- **Pipeline:** six executions.
- **Verification:** `verify-lab-11.sh` `PASS=46 FAIL=0`, and `configs/lab-11.env`
  regenerated (26 exports, release `r6`).

---

## Exercise 1 - Basic: a second build project for the results service

**Source tree:** `labs/lab-11-cicd/app-results/`:
- `VERSION` (`r1`)
- `src/index.html`
- a `buildspec.yml` with three phases, whose `build-metadata.json` says
  `"service": "results"`

**Project:** `usms-results-build`.
- **The document:** `templates/lab-11-results-build-project.json`, written by
  `write-lab-11-templates.sh results`.
- **Source:** type `S3`, location `usms-pipeline-artifacts/source/usms-results-src.zip`.
- **Role:** reuses `usms-codebuild-role`.

```text
usms-results-build:2  status=SUCCEEDED  phase=COMPLETED
results artifact:   {"service":"results","release":"r1","buildId":"usms-results-build:2",...}
enrolment artifact: {"service":"enrolment","release":"r5","buildId":"usms-enrolment-build-standalone:4",...}
```

The two artifacts are distinguished by `service` and `buildId`.

**Does `USMSCodeBuildBase` already permit this build? Half of it.**
- **The S3 statement covers it,** because it names the whole bucket (`.../*`). Reading
  `source/usms-results-src.zip` and writing the artifact are both allowed.
- **The log statement does not.** It names only `/aws/codebuild/usms-enrolment-build` and
  its streams, so on real AWS a project logging to `/aws/codebuild/usms-results-build`
  would be denied its log writes.

Rather than widen the policy (Lab 12 creates its version 2 for ECR, and I did not want to
spend that version here), the results project sends its logs to the permitted group under
its own stream name:

```json
"logsConfig": { "cloudWatchLogs": { "status": "ENABLED",
  "groupName": "/aws/codebuild/usms-enrolment-build", "streamName": "usms-results-build" } }
```

The cost is one log group holding two services' builds. If a dedicated group mattered more,
the fix would be a second log ARN in USMSCodeBuildBase v2.

**A runner bug this exercise found.** The first version of the results buildspec had a
quoted list item: `- "! grep -q '__RELEASE__' $ARTIFACT_DIR/index.html"`.
- **In CodeBuild it passed:** Floci parses real YAML, which strips the quotes.
- **In the local runner it failed:** the runner's minimal parser keeps the quotes, so bash
  received the whole line as one word (`No such file or directory`).

I rewrote the line as a `- |` block, which both parsers read identically. I left the
parser's limit documented rather than widened.

---

## Exercise 2 - Intermediate: a `finally` block and a build report

**The change.** `post_build` now records the tests' exit status before it fails, and a
`finally` block, a sibling of `commands` at the same indentation, writes the summary:

```yaml
  post_build:
    commands:
      - echo "--- post_build ---"
      - |
        bash tests/smoke.sh && SMOKE_STATUS=0 || SMOKE_STATUS=$?
        echo "$SMOKE_STATUS" > "${TMPDIR:-/tmp}/usms-smoke-status"
        test "$SMOKE_STATUS" -eq 0
      ...
    finally:
      - |
        mkdir -p "$ARTIFACT_DIR"
        printf 'release=%s tests_exit=%s at=%s\n' ... > "$ARTIFACT_DIR/build-summary.txt"
```

**Two design points:**
- **The status is written outside the source tree.** The temporary file lives in
  `${TMPDIR:-/tmp}`, so it is never packed into the next source zip.
- **The phase still fails.** `test "$SMOKE_STATUS" -eq 0` fails it, because `finally`
  only guarantees that the summary is written; it does not rescue the phase.

**What happened in CodeBuild on Floci.** I broke one test (`healthz.html` said `not ok`),
uploaded the source and built it (`usms-enrolment-build-standalone:6`):

```text
POST_BUILD FAILED  ->  UPLOAD_ARTIFACTS SUCCEEDED  ->  COMPLETED FAILED
  FAIL health endpoint says ok / smoke tests failed: 1
artifact usms-enrolment-build-standalone-6.zip: service.json index.html build-metadata.json healthz.html
                                                 (no build-summary.txt)
```

The artifact was uploaded but had no summary. To find out why, I made two throwaway
projects with a `finally` that writes a file into the artifact: one whose `post_build`
passes, one whose `post_build` fails (`outputs/lab-11-ex2-finally-probe.txt`):

```text
post_build pass -> SUCCEEDED, artifact: ['body.txt']
post_build fail -> FAILED, artifact: ['body.txt']
```

**Floci 2.2.0 never runs `finally`**, not even after a passing phase. The guide's expected
outcome cannot be observed in CodeBuild on this build.

**What I changed about how I tested it.** The guide's local runner did not implement
`finally`. Its minimal parser did not stop at `finally:`, so the block's commands were simply
appended to the phase's commands. They would therefore run only on success, which is exactly
the case that does not matter. I extended `scripts/utilities/usms-buildspec-run.sh`:
- **Both parsers read `finally`:** the PyYAML path takes `body.get("finally")`; the minimal
  parser switches its target list at `finally:`.
- **The generated script** wraps the phase in an `EXIT` trap that runs the `finally`
  function on failure (when `set -e` ends the script), and calls it explicitly on success.
  It runs in the same shell, so variables carry over as they do in CodeBuild.
- **The phase's exit status is preserved,** so `finally` does not rescue a failure.

```text
== tests passing
=== finally: post_build ===
release=r5 tests_exit=0 ...
--- local build exit status: 0 ---
== a test broken
  FAIL health endpoint says ok
=== finally: post_build ===
release=r5 tests_exit=1 ...
--- local build exit status: 1 ---
dist/build-summary.txt: release=r5 tests_exit=1 at=2026-11-06T05:22:12Z
```

**What I can claim:**
- **Observed:** the buildspec is valid. A YAML parser reads `post_build` as 4 commands plus
  1 `finally` command, and Floci accepted and ran the phase.
- **Observed locally:** the documented `finally` semantics, run by my runner, produce a
  summary saying the tests failed while the build still fails.
- **Not observed:** CodeBuild running the block. That is "the build passed locally", with a
  runner I changed, not "the build passed". On real AWS, I would confirm it by reading
  `build-summary.txt` from the artifact of a deliberately failed build.

---

## Exercise 3 - Problem solving: make the configuration check robust

**The check.** Both `pre_build` greps, the guide's container check and my Step 8 "Your turn"
port check, are replaced by one standard-library parse:

```python
cfg = json.load(open("config/service.json"))
want = {"container": ("enrolment-api", "the ECS task definition's container name (Lab 04)"),
        "port": (80, "the ALB target group and the task definition both expect 80")}
bad = ["config/service.json: %s must be %r - %s - but it is %r" % ...]
```

The smoke test's seventh assertion was also a `grep` on the same formatting, so it now
parses too. Otherwise the build would pass `pre_build` and then fail `post_build` on a
reformatted file.

**Proof that formatting no longer matters** (`outputs/lab-11-ex3.txt`). I rewrote
`service.json` with four-space indentation **and** compact separators
(`"container":"enrolment-api"`), which the old `grep '"container": "enrolment-api"'` cannot
match:

```text
container=enrolment-api port=80
  ok   container name matches the task def
--- local build exit status: 0 ---
```

**Proof that it fails specifically,** with the container and the port both wrong:

```text
config/service.json: container must be 'enrolment-api' - the ECS task definition's container name (Lab 04) - but it is 'enrolment-api-v2'
config/service.json: port must be 80 - the ALB target group and the task definition both expect 80 - but it is 8080
--- local build exit status: 1 ---
```

Both problems are reported in one run, not one per rebuild.

**The trust policy.** `policies/trust-codebuild.json` now has two conditions:
`aws:SourceAccount` and `ArnLike aws:SourceArn`. It names **three** project ARNs, not one,
because three projects share `usms-codebuild-role`: the enrolment project, the results
project (Exercise 1) and the standalone twin. A single ARN would lock the other two out on
real AWS. The three ARNs match `batch-get-projects`' `arn` fields exactly, and all three
projects still build after `update-assume-role-policy`. The before and after documents are in
`outputs/lab-11-ex3-trust-{before,after}.json`.

The attack `aws:SourceArn` closes is answered in
[notes/lab-11-notes.md](../../notes/lab-11-notes.md#exercise-3---what-awssourcearn-closes-that-awssourceaccount-does-not).

---

## Exercise 4 - Challenge: trigger the pipeline without polling

### The design

```text
PutObject source/usms-enrolment-src.zip
   -> event on the default bus (one of the two paths below)
   -> rule: matches bucket + ONE key
   -> target: arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline
              RoleArn usms-pipeline-trigger-role  (codepipeline:StartPipelineExecution, this pipeline only)
```

**Two ways an S3 object change reaches EventBridge. They are not equivalent:**

| | CloudTrail data events | S3 EventBridge notifications |
|---|---|---|
| Enabled by | a trail with a data-event selector on the bucket or key | `put-bucket-notification-configuration` with `EventBridgeConfiguration: {}` |
| `detail-type` | `AWS API Call via CloudTrail` | `Object Created` |
| Match the key with | `detail.requestParameters.key` | `detail.object.key` |
| Cost and latency | data events are charged per event, and delivery is slower | no trail needed, and delivered directly |
| Used by | the CodePipeline documentation's S3-source change detection | the console's newer S3-source setup |

**Both documents are written, and both match exactly one key:**
- `templates/lab-11-source-change-rule.json`: the CloudTrail pattern. `eventName` is
  `PutObject`, `CompleteMultipartUpload` or `CopyObject`, because a large upload arrives as a
  multipart completion, not a `PutObject`.
- `templates/lab-11-source-change-rule-s3.json`: the S3-native pattern.
- `templates/lab-11-source-change-targets.json`: the target.

**The target's role is not the pipeline role, for three reasons:**
- **Different principal.** `usms-codepipeline-role` trusts `codepipeline.amazonaws.com`;
  EventBridge assumes roles as `events.amazonaws.com`.
- **Too much power.** The pipeline role reads and writes the artifact store, starts builds,
  and passes the build role. EventBridge needs exactly one action.
- **What a broad rule would mean.** If the trigger role could do what the pipeline role
  does, an over-broad rule could start builds directly and pass roles. Scoped to
  `StartPipelineExecution` on one pipeline ARN, the worst it can do is start this pipeline.

So, `usms-pipeline-trigger-role`:
- **trust:** `policies/trust-events-pipeline-trigger.json`, with `aws:SourceAccount` and
  `aws:SourceArn` naming the two rule ARNs
- **policy:** `USMSPipelineTriggerBase` (`policies/usms-pipeline-trigger-policy.json`)

### What was created, and what ran

- **Both rules:**
  - `usms-enrolment-src-change-s3`: **ENABLED**
  - `usms-enrolment-src-change-cloudtrail`: **DISABLED**. It is created so the document is
    proven to be accepted, but disabled so the two paths can never both start the pipeline
    for one upload.
- **Targets:** `put-targets` reported `FailedEntryCount 0` for both rules.
- **The bucket:** `EventBridgeConfiguration` enabled.

**Then I released r6 by upload only, with no `start-pipeline-execution`**
(`outputs/lab-11-ex4-trigger.txt`):

```text
executions before: 5
upload source/usms-results-src.zip          (a different key - must NOT match)
upload source/usms-enrolment-src.zip  r6    (the watched key)
executions after 90s: 5
Floci: WARN EventBridgeInvoker  EventBridge: unsupported target ARN type: arn:aws:codepipeline:us-east-1:000000000000:usms-enrolment-pipeline
```

Exactly one refusal followed, for the watched key and not the results key. So the S3 event
was emitted and the one-key pattern matched; only the delivery to CodePipeline is missing.

**Capturing the matched event.** To see the event itself I added a second, throwaway target
to the same rule:
- **A CloudWatch Logs target first:** also `unsupported target ARN type: arn:aws:logs:...`.
- **Then an SQS queue:** this one delivered (`outputs/lab-11-ex4-event.txt`):

```text
{"source": "aws.s3", "detail-type": "Object Created", "resources": []}
{"bucket": "usms-pipeline-artifacts", "key": "source/usms-enrolment-src.zip",
 "version-id": "0548c920-a39f-4f94-afdf-3fcc64a2736d", "reason": "ObjectCreated:Put"}
uploaded version: 0548c920-a39f-4f94-afdf-3fcc64a2736d
```

**That answers the hint's question, for the S3 path.** A `PutObject` on the versioned key
produces `detail-type: Object Created` with `reason: ObjectCreated:Put`, and the event
carries the **version ID**. That is the same identifier the pipeline's Source action records.
The probe target, the queue and the log group were removed afterwards.

**Recorded, not demonstrated:**
- **The CloudTrail path.** CloudTrail answers on Floci, but I did not create a trail. Data
  events would need one, and Floci's EventBridge could not deliver to the pipeline anyway.
  The CloudTrail rule exists only as a validated, disabled document.
- **EventBridge starting the pipeline,** and therefore the role being assumed. Floci
  refuses the target type.

r6 was then started by hand (execution `80ffda4d`). That is the step this design would
remove on real AWS.

---

## Exercise 5 - Integration: prepare the deployment contract for Lab 12

**The `build` phase** now writes `dist/imagedefinitions.json`:

```bash
export IMAGE_URI="${IMAGE_URI:-public.ecr.aws/nginx/nginx:stable-alpine}"
python3 -c '...c=json.load(open("config/service.json"))["container"]; json.dump([{"name": c, "imageUri": os.environ["IMAGE_URI"]}], ...)' "$ARTIFACT_DIR/imagedefinitions.json"
```

**How it meets the constraints:**
- **The container name is read from `config/service.json`,** never typed a second time.
- **The default image is the one the service runs today.** `usms-enrolment-svc` runs task
  definition `usms-enrolment:2`, whose `enrolment-api` container uses
  `public.ecr.aws/nginx/nginx:stable-alpine`. So with no `IMAGE_URI`, a deploy of this
  artifact changes nothing.
- **The output is always an array,** because `json.dump` is given a list.

**The eighth smoke assertion** checks for a one-entry array whose `name` is the container
from `service.json` and whose `imageUri` is non-empty:
- **positive:** 8 `ok`
- **`IMAGE_URI` override:** honoured (`.../usms-enrolment:r6`)
- **negative:** an object instead of an array, which gives
  `FAIL imagedefinitions.json is a one-entry array` and `smoke tests failed: 1`

**Running the pipeline and downloading the artifact.** The pipeline ran r6 (execution
`80ffda4d`, Source fetched version `0548c920`, which contains `VERSION=r6`). Floci stores no
`BuildOutput`, so the artifact is the twin's real CodeBuild build of the same key,
`usms-enrolment-build-standalone-7.zip`:

```text
artifact root          build-metadata.json, healthz.html, imagedefinitions.json, index.html, service.json
imagedefinitions.json  at root: True
  contents             [{"name": "enrolment-api", "imageUri": "public.ecr.aws/nginx/nginx:stable-alpine"}]
  is a 1-entry array   True
release                r6   (buildId usms-enrolment-build-standalone:7)
```

**`outputs/lab-11-lab08b-readiness.txt`** is written by `scripts/utilities/lab-11-readiness.sh`.
It is re-runnable and git-ignored (`.gitignore:8:outputs/*`). Alongside the artifact key and
contents, it ends with three lines Lab 12 needs:
- **No stored `BuildOutput`.** A Deploy stage on this build will have no
  `imagedefinitions.json` to read.
- **The CodeBuild image is a local stand-in** with no `docker` CLI, so Lab 12's
  `docker build` needs a different stand-in.
- **`finally` is not executed.**
