# Lab 10 - Edge functions with AWS Lambda

## 1. Summary

This lab created the bucket that four IAM policies have named since Lab 01, and put
three Lambda functions around it.

**The origin.**
- `usms-student-data`, tagged `Project=USMS`, `Tier=data`, `Lab=10`.
- `USMSStudentDataReadWrite` now resolves to a real bucket, on the three roles that
  carry it.

**Two edge functions (Lambda@Edge), Node.js 20, 128 MB, 5 s, no environment variables:**
- `usms-edge-viewer-request`: an auth gate and URI normalisation.
  - **No `x-usms-student` header:** it returns a `403` *response*, so the origin is never
    contacted.
  - **Otherwise:** it lower-cases the URI and stamps
    `x-usms-edge: viewer-request-allow;student=<id>` on the request.
- `usms-edge-origin-response`: four security headers, a transcript cache policy
  (`public, max-age=300, s-maxage=3600`), and an `x-usms-edge-chain` marker proving the
  two functions composed.

Both are published (version 1) and associated by **version-qualified ARN** with a real
CloudFront distribution, `E6X90N1YYWT91G` (`Deployed`).

**One regional function,** `usms-transcript-notifier` (Python 3.12, 256 MB, 30 s, with
environment variables, which are legal here and are the contrast):
- **Wiring:** published, behind alias `live`, invoked by S3 `ObjectCreated` on
  `transcripts/*.json`.
- **Permission:** a resource policy lets `s3.amazonaws.com` invoke `...:live` only from
  this bucket.

**The execution role.** `usms-lambda-exec-role` now trusts `edgelambda.amazonaws.com` as
well as `lambda.amazonaws.com`. I added it as a **second statement**, so Lab 09's
confused-deputy conditions on the `lambda` statement survived. The guide's Step 6 would
have removed them (Section 3.2).

**Support path A, on Floci 2.2.0.** Two things are true on this build at the same time:
- **Lambda really runs code.** Every invocation in this report executed the handler in a
  container. The S3 notification is really **delivered**.
- **Floci never runs an edge function.** CloudFront distributions exist as records, and
  Floci serves the distribution's hostname by proxying to S3. But it never invokes an
  associated function. A request with no auth header got `200` and the object
  (Section 3.5).

`usms-edge-simulate.sh` is therefore the evidence that the chain composes. It runs both
functions in CloudFront's order.

**Verification.**
- **`verify-lab-10.sh`:** **`PASS=51 FAIL=0`**, both at the screenshot and after the
  exercises.
- **Persistence:** identical across a Floci restart, and the chain still composes.
- **Regression:**
  - `verify-lab-09.sh` still `49/1`
  - Labs 02-08 at their recorded results (Section 3.8)
  - Lab 09's IAM audit at `HIGH=0`

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| Bucket | `usms-student-data`; objects under `transcripts/evidence/` (3) and `notes/` (1); notification `usms-transcript-upload` (prefix `transcripts/`, suffix `.json`) -> `usms-transcript-notifier:live` |
| Edge functions | `usms-edge-viewer-request` versions 1-2; `usms-edge-origin-response` versions 1-3 (2 and 3 add `Content-Security-Policy`, Exercise 1) |
| Regional function | `usms-transcript-notifier` versions 1-2, alias `live` -> 1, resource policy `usms-s3-transcript-upload` |
| CloudFront | `E6X90N1YYWT91G` / `e6x90n1yywt91g.cloudfront.net`, associations `viewer-request:2`, `origin-response:3` (after the exercises; `:1` and `:1` in the screenshots) |
| IAM | `usms-lambda-exec-role` trust: `lambda` (conditioned) + `edgelambda`; new `usms-edge-exec-role` + `USMSEdgeBasic` (Exercise 2); two accepted findings added to `configs/usms-iam-accepted-findings.tsv` |
| Infrastructure | `docker-compose.yml`: two Lambda network settings, without which no function ran (Section 6.1) |
| Files | 3 handlers; 7 templates; `policies/trust-lambda-edge.json`, `policies/usms-edge-basic-policy.json`; `configs/lab-10.env` (25 exports); the scripts in Section 3.10; `scripts/cleanup/lab-10-cleanup.sh` (never run) |

---

## 2. Evidence index

Six screenshots. Each fits on one screen and none repeats another. They show the core
lab, with both edge functions at version 1; the exercises came afterwards and are
evidenced by `outputs/lab-10-ex*.txt`. Everything else is command output under
`outputs/` (git-ignored), quoted where it is used.

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoints 1-3: the bucket exists and is tagged; `USMSStudentDataReadWrite` resolves to it, on three roles; the two trust statements (`lambda` conditioned `True`, `edgelambda` `False`); the viewer function's allow path (normalised URI, stamped header) and deny path (`403`, `viewer-request-deny`) | [3.1](#31-checkpoints-1-3---origin-role-and-the-viewer-function) |
| 02 | Checkpoints 4-6: both functions edge-eligible with no `NO` line; the distribution `Deployed` and enabled; both associations version-qualified (`:1`); 11 structural checks `ok` | [3.4](#34-checkpoints-4-6---versions-eligibility-and-the-distribution) |
| 03 | Checkpoint 7: the chain, deny (`viewer-request` only, `403`) and allow (`viewer-request -> origin -> origin-response`, five headers and `x-usms-edge-chain`) | [3.5](#35-checkpoint-7---the-edge-chain) |
| 04 | Checkpoints 8-9: the notifier with environment variables; versions 1-2; `live` -> 1; the resource policy scoped by `AWS:SourceArn`; the notification with its filter; the objects; the `USMS_NOTIFY` lines | [3.6](#36-checkpoints-8-9---the-notifier-the-resource-policy-and-the-notification) |
| 05 | Checkpoint 10: a real `floci-down`/`floci-up`, the inventory `IDENTICAL`, the chain still composing, `verify-lab-09` unchanged at `49/1` | [3.7](#37-checkpoint-10---persistence) |
| 06 | Section 8 and hygiene: `PASS=51 FAIL=0`; 25 exports, all populated, CloudFront `yes` with real IDs; the IAM audit `HIGH=0` with the `edgelambda` finding accepted; nothing under `outputs/`, no `.zip`; `check-ignore` naming the rule | [3.9](#39-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-24)

### 3.1 Checkpoints 1-3 - origin, role and the viewer function

**Steps 1-4: environment and probe.**
- Labs 01-09's environment files source cleanly. The account is `000000000000`.
- **The probe** answered for Lambda, S3 and CloudFront (`list-distributions`), which put
  this build on Path A.
- **Lambda did not run until I fixed the network.** Section 6.1 has the details; every
  later step depends on that fix.

**Step 5: the bucket.** `create-bucket`, then the tags:
- `USMSStudentDataReadWrite`'s resources are now `arn:aws:s3:::usms-student-data` and
  `.../*`.
- It is carried by `usms-ec2-app-role`, `usms-ecs-task-role` and `usms-eks-node-role`.
- The bucket ARN appears twice in the document, once for `ListBucket` and once in a
  second statement. That is how Lab 01 wrote it, and it is harmless.

**Step 6: the role.** See Section 3.2.

**Steps 7-9: the viewer function.**
- **The source.** `labs/lab-10-lambda-edge/edge-viewer-request/index.mjs` is written
  exactly as the guide gives it. Its template literal
  `` `viewer-request-allow;student=${studentId.toLowerCase()}` `` survived intact, and
  `verify-lab-10.sh` checks for it.
- **Packaging.** Zipped from inside the function's directory, so `index.mjs` sits at the
  archive root.
- **Creation.** `index.handler`, 128 MB, 5 s, run as `usms-lambda-exec-role`.

![Checkpoints 1-3: bucket usms-student-data exists in us-east-1; tags Project=USMS Tier=data Lab=10; USMSStudentDataReadWrite resources arn:aws:s3:::usms-student-data and /*; carried by usms-ec2-app-role, usms-ecs-task-role, usms-eks-node-role; trust lambda.amazonaws.com LambdaMayAssumeThisRoleForThisAccountsFunctionsOnly True, edgelambda.amazonaws.com AllowCloudFrontEdgeToAssume False; allow invoke 200, uri /transcripts/2026/stu-00417.json, edge viewer-request-allow;student=stu-00417; deny invoke 200, status 403, edge viewer-request-deny](../../screenshots/lab10-01-checkpoints1-3-bucket-role-viewer.png)

The screenshot shows three things:
- **The allow path** returns a **request**: the URI has been lower-cased
  (`STU-00417` -> `stu-00417`) and the header stamped.
- **The deny path** returns a **response**, with status `403` and no `uri` key at all.
  That shape is how CloudFront knows not to go to the origin. The full deny output,
  including the body `transcript access requires an authenticated session`, is in
  `outputs/lab-10-step7-9.txt`.
- **`200` is the Lambda invoke status** for both, meaning "the function ran". The `403`
  is the function's answer.

### 3.2 Step 6 - two principals without undoing Lab 09

**The guide's version would have undone Lab 09.** Step 6 replaces the trust policy with
one statement listing both principals and no condition. `update-assume-role-policy`
replaces the whole document, so that would have quietly removed the `aws:SourceAccount`
and `aws:SourceArn` conditions that Lab 09 Exercise 2 put on `lambda.amazonaws.com`.

**What I used instead.** `policies/trust-lambda-edge.json` has two statements:
- `LambdaMayAssumeThisRoleForThisAccountsFunctionsOnly`: Lab 09's statement, unchanged
- `AllowCloudFrontEdgeToAssume`: `edgelambda.amazonaws.com`, no condition

The before and after documents are kept (`outputs/lab-10-lambda-role-trust-*.json`).
The screenshot's `True` / `False` column is `Condition != null` for each statement.

**The audit cost.** The `edgelambda` statement has no condition, so Lab 09's audit
reports it as HIGH. It is recorded as accepted, with its reasons:
- AWS's documented Lambda@Edge trust carries no condition
- replicas run in other Regions, so the `lambda` statement's `us-east-1` `SourceArn`
  pattern cannot just be copied
- Floci never assumes the role for a replica, so a condition is untestable here

The compensating controls are listed in the TSV. Screenshot 06 shows the audit at
`HIGH=0` with this finding `ACCEPTED`.

### 3.3 Steps 10-14 - logs, versions, the origin-response function, the rules

**Step 10: logs.** `--log-type Tail` returns `LogResult: None` on this build. The log
group `/aws/lambda/usms-edge-viewer-request` exists with one stream, but Floci writes no
`START`/`END`/`REPORT` lines, only what the handler prints. Step 21 relies on exactly
that.

**Step 11: version 1.** `publish-version` returned `1`. The qualified ARN
`...:usms-edge-viewer-request:1` is what the edge accepts. `$LATEST` and an alias are
not: one is mutable, and the other can move after replication.

**Steps 12-13: the origin-response function.** Invoked with the Step 13 event, it kept
the origin's `content-type`, `etag` and `server`, and added:
- the four security headers
- `cache-control`
- `x-usms-edge-chain: viewer-request-allow;student=stu-00417;origin-response`

It was published as version 1 (`outputs/lab-10-origin-response.json`).

**Step 14: the rules, and the deliberate mistake.**
- `scripts/utilities/lab-10-edge-eligibility.sh` is the guide's `edge_eligibility`
  function, moved into a script. It asks six questions per function.
- **The mistake.** Setting two environment variables on the viewer function
  **succeeded**, and the check then said `NO 2 environment variables set`.
- **The undo.** Clearing them with `--environment 'Variables={}'` returned both functions
  to six `ok` lines (`outputs/lab-10-function-inventory.json`).
- Version 1 had been published before the mistake, so it never carried the variables.

### 3.4 Checkpoints 4-6 - versions, eligibility and the distribution

**Step 15, Path A.** I wrote `templates/lab-10-distribution-config.json` by lookup with
`write-lab-10-templates.sh dist`. Each association ARN comes from
`max_by(Versions[?Version!='$LATEST'], &to_number(Version))`, so version 10 would sort
after 9. The script refuses to write an empty or `None` value. Then:

```text
distribution: E6X90N1YYWT91G  domain: e6x90n1yywt91g.cloudfront.net
```

**Floci accepts anything here.** On a throwaway probe it also accepted a `$LATEST` ARN
without complaint, so this build performs none of the association checks real AWS does.
I therefore kept the guide's Path B structural validation on Path A too
(`scripts/utilities/lab-10-validate-distribution.py`): eleven checks on the config file,
including "every ARN is version-qualified".

![Checkpoints 4-6: Lambda@Edge eligibility for usms-edge-viewer-request and usms-edge-origin-response, each ok no environment variables, memory 128 MB (cap 128), timeout 5 s, runtime nodejs20.x, no VPC configuration, 1 published version; distribution E6X90N1YYWT91G Deployed e6x90n1yywt91g.cloudfront.net True; associations viewer-request :1 and origin-response :1; eleven structural checks ok](../../screenshots/lab10-02-checkpoints4-6-eligibility-distribution.png)

The screenshot shows:
- **Eligibility:** both functions pass all six questions, with no `NO` line (Checkpoint 5).
- **The distribution:** `Deployed` and enabled (Checkpoint 6).
- **The associations,** read from the **live distribution** (`get-distribution-config`),
  not the template. Both are qualified with `:1` (Checkpoint 4).
- **The structural validation:** all eleven `ok`.

### 3.5 Checkpoint 7 - the edge chain

**What Floci does with a request to the distribution.**
- **No auth header:** `curl -H 'Host: e6x90n1yywt91g.cloudfront.net'
  http://localhost:4566/transcripts/evidence/lab-08-scaling-evidence.json` returns **`200`
  and the object**.
- **What is missing:** the response has no `x-usms-edge-chain`, no
  `strict-transport-security`, none of the origin-response headers
  (`outputs/lab-10-cloudfront-request.txt`).

So Floci routes the hostname to the S3 origin and never invokes either associated
function. On real AWS, the same request would get the viewer function's `403`.

**The simulator.** `scripts/utilities/usms-edge-simulate.sh` runs the chain in
CloudFront's order with direct invocations:
1. **viewer-request:** if it returns a response, stop.
2. **origin:** a simulated S3 `200` carrying the *modified* request.
3. **origin-response.**

The script is the guide's version, except that it finds the repository from
`${BASH_SOURCE[0]}` rather than `COURSE_ROOT` (Section 6.3).

![Checkpoint 7: usms-edge-simulate.sh with the denied event - viewer-request, decision DENY - the origin is never contacted, chain [viewer-request], status 403, x-usms-edge viewer-request-deny, cache-control no-store; with the allow event - chain viewer-request, origin, origin-response, decision allow, request_uri_after_normalisation /transcripts/2026/stu-00417.json, status 200, strict-transport-security, x-content-type-options nosniff, x-frame-options DENY, referrer-policy, cache-control public max-age=300 s-maxage=3600, x-usms-edge-chain viewer-request-allow;student=stu-00417;origin-response](../../screenshots/lab10-03-checkpoint7-edge-chain.png)

**Reading the screenshot.**
- **Deny:** the chain stops after one stage. The `403` carries `cache-control: no-store`,
  so a refusal is never cached.
- **Allow:** all three stages run. The final headers are the origin's two plus the
  function's six.

**Why the composition marker matters.** `x-usms-edge-chain` contains the viewer function's
stamp followed by `;origin-response`. The value written by the first function was read by
the second, and that is the evidence that they **compose**, not merely that each runs.

**The trace file.** The deny run is first and the allow run last, so
`outputs/lab-10-edge-trace.json` ends holding the three-stage trace that
`verify-lab-10.sh` checks.

**A limitation of the simulator.** It invokes the **unqualified** function, which is
`$LATEST`, not the version the distribution associates. During the core lab those were
the same code. After Exercise 2 they still are: `$LATEST` equals viewer `:2` and origin
`:3`. A version-faithful simulator would read the associated ARNs from
`get-distribution-config` and pass `--qualifier`.

### 3.6 Checkpoints 8-9 - the notifier, the resource policy and the notification

**Steps 17-18: the notifier.**
- **Configuration:** `notifier.handler`, Python 3.12, 256 MB, 30 s, with `USMS_BUCKET`
  and `USMS_NOTIFY_CHANNEL=stdout`.
- **Versions:** version 1 was published and alias `live` created.
- **"Your turn":** published version 2, moved `live` to 2, then back to 1.

Floci published version 2 even though nothing had changed. On real AWS, Lambda returns
the existing version when neither code nor configuration has changed, so the guide's
"gives you version 2" depends on this build.

**Step 19: the permission.** `add-permission --qualifier live --principal
s3.amazonaws.com --source-arn arn:aws:s3:::usms-student-data --source-account
000000000000`. The stored statement has the `ArnLike AWS:SourceArn` condition, but **no
`AWS:SourceAccount`**: Floci drops it.

**Step 20: the notification.** `templates/lab-10-bucket-notification.json` is written by
lookup, so the alias ARN is real. It is then put on the bucket, and the Lab 08 evidence
file is uploaded to `transcripts/evidence/`.

![Checkpoints 8-9: usms-transcript-notifier python3.12 notifier.handler 256 30 usms-student-data stdout; versions $LATEST, 2 lab-10 your-turn, 1 lab-10 baseline; alias live 1 ...:usms-transcript-notifier:live; resource policy Sid usms-s3-transcript-upload, Principal s3.amazonaws.com, Resource ...:live, Condition ArnLike AWS:SourceArn arn:aws:s3:::usms-student-data; notification usms-transcript-upload -> ...:live, s3:ObjectCreated:*, prefix=transcripts/ suffix=.json; objects notes/ignore-me.json, transcripts/evidence/ignore-me.txt, transcripts/evidence/lab-08-scaling-evidence.json; three USMS_NOTIFY log lines](../../screenshots/lab10-04-checkpoints8-9-notifier.png)

**The `USMS_NOTIFY` lines are the evidence that S3 really invoked the function.** There
are three:

| Key | Where it came from | `readable` |
|---|---|---|
| `lab-08-scaling-evidence.json` | the real Step 20 upload, delivered within a second | `true`, size 3254 (the function's own `head_object` read the object) |
| `synthetic-probe.json` | the Step 21 fallback: a hand-built event invoked against `--qualifier live` | `false` with `read_error: ClientError`, because the object does not exist; the handler's guard kept it running |
| `post-restart-check.json` | my delivery probe after the Step 22 restart, deleted afterwards so the inventory stayed identical | `true` |

**The filter works.**
- `notes/ignore-me.json` (wrong prefix) and `transcripts/evidence/ignore-me.txt` (wrong
  suffix) are both in the bucket, and neither has a log line. That is Step 21's
  "Your turn".
- The notifier has environment variables and the edge functions do not. That contrast is
  the point of `verify-lab-10.sh`'s `HAS environment variables` check.

### 3.7 Checkpoint 10 - persistence

**Step 22.** `scripts/utilities/lab-10-restart-facts.sh` is the guide's `inventory()`
function in a script, plus one line for the distribution. Every value comes from the
API. I first ran the restart myself during setup. Screenshot 05 is a second, real
restart.

![Checkpoint 10: lab-10-restart-facts.sh written to the pre-restart file; floci-down.sh, Container floci Stopped, state preserved in /Users/keldendrac/floci-data; floci-up.sh, storage mode hybrid, Floci is up at http://localhost:4566; post-restart inventory - three functions with runtimes and memory, version 1, live 1, three object keys, usms-transcript-upload, E6X90N1YYWT91G Deployed; IDENTICAL - every Lab 10 artefact survived the restart; simulate decision ALLOW and x-usms-edge-chain viewer-request-allow;student=stu-00417;origin-response; verify-lab-09 PASS=49 FAIL=1](../../screenshots/lab10-05-checkpoint10-persistence.png)

**What survived.** All three functions (runtime and memory), the version, the alias, the
objects, the notification and the distribution survived.

**The stronger check: the code still runs.** The simulator ran both functions after the
restart and still produced the composed `x-usms-edge-chain`. Names surviving is weaker
evidence than code surviving.

**The notification still delivers.** During my first restart I uploaded
`post-restart-check.json`, saw its `USMS_NOTIFY` line, and then deleted it.

**`verify-lab-09.sh`** is still `49/1`, so Lab 10 broke nothing Lab 09 built.

**EKS** recovered without help. The kubectl context in my own shell had been unset, and
I restored it (Section 6.4).

### 3.8 Regression

After the exercises, every earlier verify script gave
(`outputs/lab-10-regression.txt`):

```text
lab-02 33/0   lab-03 31/5   lab-04 39/0   lab-05 49/1   lab-06 39/3   lab-07 30/0   lab-08 33/1   lab-09 49/1
```

**Labs 02-06 and 09** match Lab 09's baseline exactly. **Labs 07 and 08** match their own
reports.

**A transient first pass.** On the first pass, run straight after Labs 02-06,
`verify-lab-07` reported `28/2` and `verify-lab-08` reported `32/2`. Rerun minutes later
they gave `30/0` and `33/1`, and a third run agreed. I did not capture which checks
failed on that first pass. The ones that can flap are the Kubernetes checks, so I record
it as a transient rather than claim a cause.

### 3.9 Verification and hygiene

**Step 23: the env file.** `scripts/utilities/write-lab-10-env.sh` writes
`configs/lab-10.env`.
- **25 exports**, every value looked up. The guide's heredoc takes `VIEWER_VERSION_ARN`,
  `ORIGIN_VERSION_ARN` and `EDGE_ROLE_ARN` from shell variables, which are empty in any
  new terminal.
- **`USMS_EDGE_ROLE_ARN`** is read from the viewer function's actual `Role`. So after
  Exercise 2 it names `usms-edge-exec-role` without anyone editing anything.
- **CloudFront** is `yes`, with the real ID and domain.

**Section 8.1: `verify-lab-10.sh`.** These are the guide's 51 checks, with two
adaptations, each explained in a comment:
- **`ROLE_NAME`.** `lab-01.env` stores `USMS_ROLE_LAMBDA` as an **ARN**, so `--role-name`
  received an ARN and four checks failed (`47/4` on the first run). The script now strips
  it with `${ROLE_NAME##*/}`.
- **"No secret is tracked".** The guide's test, `git ls-files | grep '^outputs/'`, fails
  on a correct repository because Lab 01 tracks `outputs/.gitkeep` deliberately. It now
  ignores exactly that one file.

![Section 8: verify-lab-10.sh with only section headers and PASS=51 FAIL=0; 25 exports; all values populated; USMS_EDGE_VIEWER_VERSION_ARN ...:1, USMS_EDGE_ORIGIN_VERSION_ARN ...:1, USMS_CLOUDFRONT_SUPPORTED=yes, USMS_CLOUDFRONT_DIST_ID=E6X90N1YYWT91G, USMS_CLOUDFRONT_DOMAIN=e6x90n1yywt91g.cloudfront.net; identity inventory valid JSON, 13 roles; audit ACCEPTED trust policy: service principal edgelambda.amazonaws.com, HIGH=0 MED=35 ACCEPTED=6 roles=13; nothing under outputs/, no .zip, no __pycache__, no root .env; .gitignore:8:outputs/* for usms-edge-viewer-request.zip and lab-10-edge-trace.json; git ls-files outputs/ only outputs/.gitkeep](../../screenshots/lab10-06-verify-env-and-hygiene.png)

**Reading the screenshot.**
- **`grep -v '✔'`** leaves only the section headers and the summary: no `✗` line.
- **The audit** was run against a **fresh** inventory. Lab 09's saved inventory predates
  this lab, so it still showed Lab 09's `HIGH=0 ACCEPTED=5`, because it had never seen
  the `edgelambda` statement. The fresh one found it (`HIGH=1`) until the accepted entry
  was added.

**After the exercises.**
- `verify-lab-10.sh` again reported `PASS=51 FAIL=0` (`outputs/lab-10-verify-final.txt`).
- The audit reported `HIGH=0 MED=36 ACCEPTED=7 roles=14`, with the new role and its
  accepted finding.

**Section 8.2: the cleanup.** `scripts/cleanup/lab-10-cleanup.sh` is the guide's script,
behind a typed confirmation. It has passed `bash -n` and has **not** been run.

**Step 24: the commit is left to me.** In this repository I commit and push myself. The
hygiene checks the step asks for are in screenshot 06.

### 3.10 Files

| File | Purpose |
|---|---|
| `labs/lab-10-lambda-edge/edge-viewer-request/index.mjs` | viewer-request handler (guide's code) |
| `labs/lab-10-lambda-edge/edge-origin-response/index.mjs` | origin-response handler; `Content-Security-Policy` added in Exercise 1 |
| `labs/lab-10-lambda-edge/transcript-notifier/notifier.py` | the regional notifier |
| `policies/trust-lambda-edge.json` | two-statement trust (`lambda` conditioned, `edgelambda`) |
| `policies/usms-edge-basic-policy.json` | `USMSEdgeBasic`, Exercise 2 |
| `templates/lab-10-viewer-request-event.json`, `-viewer-request-denied.json`, `-origin-response-event.json` | static CloudFront events |
| `templates/lab-10-distribution-config.json`, `-bucket-notification.json`, `-s3-event.json` | request bodies written by lookup |
| `configs/lab-10.env` | 25 exports |
| `configs/usms-iam-accepted-findings.tsv` | two new entries (`usms-lambda-exec-role`, `usms-edge-exec-role` `edgelambda`) |
| `docker-compose.yml` | the Lambda network fix (Section 6.1) |
| `scripts/utilities/write-lab-10-templates.sh` | `dist`, `notification`, `s3event` bodies by lookup |
| `scripts/utilities/lab-10-edge-eligibility.sh` | Step 14's six questions per function |
| `scripts/utilities/lab-10-validate-distribution.py` | 11 structural checks on the distribution config |
| `scripts/utilities/usms-edge-simulate.sh` | the chain in CloudFront's order |
| `scripts/utilities/lab-10-restart-facts.sh` | Step 22 inventory |
| `scripts/utilities/write-lab-10-env.sh` | Step 23 |
| `scripts/utilities/verify-lab-10.sh` | Section 8.1, 51 checks |
| `scripts/utilities/usms-edge-report.sh` | Exercise 3 |
| `scripts/utilities/lab-10-s3-readiness.sh` | Exercise 5 |
| `scripts/cleanup/lab-10-cleanup.sh` | Section 8.2, never run |
| `notes/lab-10-notes.md`, `notes/lab-10-edge-design.md` | notes, review questions, Exercise 4 |

---

## 4. Exercises 1-5

Full commands, output and reasoning are in [exercises.md](exercises.md). In short:

1. **CSP header.**
   - **Change:** one entry added to `SECURITY_HEADERS`, published as origin-response
     version 2.
   - **Check:** `$LATEST` and `:2` return five security headers, `:1` still returns four.
   - **Distribution:** the template and the live distribution were moved to `:2`.
2. **Dedicated edge role.**
   - **Created:** `usms-edge-exec-role` with `USMSEdgeBasic`. It allows log writes only,
     on `/aws/lambda/usms-edge-*` **and** `/aws/lambda/us-east-1.usms-edge-*` in any
     Region, because replicas log to the Region nearest the viewer under that prefix.
   - **Published:** new versions, viewer `:2` and origin `:3`, which the distribution
     now uses.
   - **Old versions keep their role:** `:1` still reports `usms-lambda-exec-role`. A
     rollback therefore restores the old role too, which is why the `edgelambda`
     statement stays on the old role for now.
3. **`usms-edge-report.sh`.** Valid JSON from any directory. The notifier is
   ineligible for **one** reason under the rule as stated (environment variables; its
   256 MB / 30 s are within the origin caps), not the two the guide expects. The
   exercise file explains why.
4. **Design.** [notes/lab-10-edge-design.md](../../notes/lab-10-edge-design.md):
   - **Session check:** viewer-request, bound to the student ID in the URI.
   - **Cache key:** the path only.
   - **Corrections:** invalidation on change, with the browser header set at
     viewer-response.
   - **Refusal report:** standard logs in Athena.
   - **Measure first:** the hit ratio.
5. **S3 readiness.**
   - **Validator:** the Lab 09 draft validates with no mismatches, and a planted-fault
     copy produces two.
   - **Two problems an ARN check cannot see:** `NotPrincipal` with role ARNs would deny
     the roles' own sessions, and nothing allows CloudFront.
   - **Not applied:** the draft is unapplied (`NoSuchBucketPolicy`).
   - **The trace:** uploaded, and the notifier saw it.
   - **`outputs/lab-10-s3-readiness.txt`:** generated by script, and git-ignored.

---

## 5. Review questions

Answered in prose in [notes/lab-10-notes.md](../../notes/lab-10-notes.md#review-questions-section-14):

1. **The enrolment API at the edge.** The data stays in one Region, and the edge runtime
   is the wrong runtime for an API. It would be right for cacheable, shared, read-heavy
   parts.
2. **CloudFront Functions versus Lambda@Edge.**
   - `/index.html`: a CloudFront Function.
   - A JWT: a CloudFront Function if HMAC, otherwise Lambda@Edge.
   - DynamoDB: Lambda@Edge.
3. **origin-response versus viewer-response.** Once per cache fill versus once per
   request. Per-viewer or not-to-be-cached headers force viewer-response.
4. **The two notifier policies.** The resource policy governs S3 calling Lambda; the
   execution role governs the code calling S3. The answer says what breaks without each.
5. **The confused deputy.** Another account's bucket invoking our function. The same idea
   as Lab 09's `aws:SourceAccount` / `aws:SourceArn` trust conditions.
6. **Where edge validation happens.** At association, not at configuration. So read the
   configuration back against the rules: exit 0 is not evidence.

---

## 6. Problems encountered

### 6.1 No Lambda function ran at all

**The symptom.** Every invocation failed inside the runtime container with "Failed to get
next invocation": Node timed out, Python exited with status 1.

**The cause.**
- Since Lab 05's ECS tasks, the Floci container is attached to two Docker networks: the
  compose network and the `usms-vpc` network, where it is `10.0.0.2`.
- Floci picks the `usms-vpc` address as the Runtime API endpoint it hands to Lambda
  containers.
- Those containers are on the compose network and cannot reach it.

**The fix** pins both ends in `docker-compose.yml`, with a comment explaining why:

```yaml
FLOCI_SERVICES_LAMBDA_DOCKER_HOST_OVERRIDE: floci
FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK: floci-course_default
```

Then I recreated Floci with `floci-down.sh` and `floci-up.sh`, and state was preserved.

**What to commit.** This is the one change to a tracked infrastructure file. It needs to
be committed with the lab, or every Lambda step fails for whoever runs it next.

### 6.2 The guide's Step 6 would have undone Lab 09

See Section 3.2. The fix:
- a two-statement trust document
- an accepted-finding entry with its reasons
- after Exercise 2, a second entry for `usms-edge-exec-role`

### 6.3 Values the guide keeps in shell variables, or in the wrong form

**Values carried in shell variables.**
- **The problem:** the guide carries ARNs between steps in shell variables, and points
  scripts at `COURSE_ROOT`. In this repository, `COURSE_ROOT` (in `configs/course.env`)
  still points at an old copy, `$HOME/aws-floci-course`.
- **The fix:** every Lab 10 script finds the repository from `${BASH_SOURCE[0]}`, and
  every body or config with a live value is written by lookup. A lookup that returns
  empty or `None` stops the script.

**Two of the guide's verify checks fail on a correct repository:**
- the ARN-valued `USMS_ROLE_LAMBDA`
- the tracked `outputs/.gitkeep`

Both are fixed and commented in the script (Section 3.9).

### 6.4 kubectl lost its current context

**The symptom.** After the restart, `wait-kube.sh` timed out, with `current-context is
not set` and kubectl defaulting to `localhost:8080`.

**The cause, and what was fine.** The cluster was fine: the k3s container had restarted
and was serving on `localhost:6500`. The `usms-eks` context was still in
`~/.kube/config`, but nothing was selected. Something outside this lab's scripts had
cleared the selection; `~/.kube/config` also holds `docker-desktop` and `minikube`
contexts, so I cannot say which tool it was.

**The fix.** `kubectl config use-context usms-eks`, after which `wait-kube.sh` reported
the API server and all three deployments ready.

### 6.5 Smaller ones

- **zsh does not word-split** an unquoted `$VAR`, so a probe loop of the form `aws $c`
  failed. I made the calls directly.
- **`filter-log-events` with a quoted term** containing dots and hyphens matched nothing
  on Floci. Filtering on `USMS_NOTIFY` and then using `grep` works.
- **`update-distribution` needs the original `CallerReference`,** so it cannot be fed the
  regenerated template. Exercises 1 and 2 used get-modify-put on the live config with
  its `ETag`.
- **The screenshot filenames** were saved as `.png.png`, and were renamed to `.png`.

---

## 7. Floci limitations versus real AWS

**Observed** on this build:
- functions created, updated, published and invoked
- the CloudFront event structure
- a request modified, a request refused with a response, a response modified
- the two functions composing
- versions and aliases
- the resource policy stored
- a real bucket and a really **delivered** filtered notification
- a distribution record with associations
- persistence across a restart

**Recorded only.** These were never enforced or exercised:
- the two-principal trust rule; no edge replica ever assumed the role
- association validation (qualified ARN, no environment variables, caps), which Floci
  does not perform; the eligibility script, the structural validator and
  `verify-lab-10.sh` stand in for it
- the resource policy and the execution role, neither of which Floci evaluates
- the `edgelambda` trust's lack of a usable condition

**Not available at all, so not claimed:**
- edge execution on a request path; Floci served the distribution without running either
  function
- replication, edge logs in viewer-nearest Regions, latency and cold starts
- the cache, TTL behaviour and hit ratio
- invalidation
- cost

| Behaviour | Real AWS | Floci 2.2.0, as observed |
|---|---|---|
| Lambda execution | Runs in a managed runtime | Runs in a Docker container, **once the network fix is in** |
| `--log-type Tail` | Last 4 KB of the log | `LogResult: None` |
| Log content | `START` / `END` / `REPORT` plus handler output | handler output only |
| S3 -> Lambda notification | Delivered | Delivered within about a second; filter honoured |
| `add-permission --source-account` | Stored as `StringEquals AWS:SourceAccount` | Dropped |
| `publish-version` on unchanged code | Returns the existing version | Creates a new one |
| CloudFront distribution | Real; `InProgress` then `Deployed` after minutes | A record, `Deployed` at once |
| Association validation | Rejects `$LATEST`, aliases, env vars, over-cap memory | Accepts anything |
| Request to the distribution | Runs viewer-request, the cache, origin-response | Proxies straight to S3; no function runs |

---

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh
source configs/course.env
source configs/lab-01.env
source configs/lab-10.env
./scripts/utilities/verify-lab-10.sh                    # PASS=51  FAIL=0
./scripts/utilities/usms-edge-simulate.sh               # three-stage chain
./scripts/utilities/lab-10-edge-eligibility.sh          # no NO lines
./scripts/utilities/usms-edge-report.sh                 # Exercise 3
./scripts/utilities/lab-10-s3-readiness.sh              # Exercise 5
```

`docker-compose.yml` must carry the two Lambda settings from Section 6.1, or every
invocation fails.
