# Lab 10 - Independent Exercises 1-5

All five exercises were done on Floci 2.2.0 after the six screenshots were taken. The
screenshots show the core lab: both edge functions at version 1 under
`usms-lambda-exec-role`. The exercises then moved the live state on.

**End state after the exercises:**

| Function | Versions | Associated with the distribution | Runs as |
|---|---|---|---|
| `usms-edge-viewer-request` | 1, 2 | `:2` | `usms-edge-exec-role` (v1 still `usms-lambda-exec-role`) |
| `usms-edge-origin-response` | 1, 2, 3 | `:3` | `usms-edge-exec-role` (v1, v2 still `usms-lambda-exec-role`) |
| `usms-transcript-notifier` | 1, 2 | not an edge function | `usms-lambda-exec-role`, alias `live` -> 1 |

`configs/lab-10.env` was regenerated afterwards: viewer version 2, origin version 3, edge
role `usms-edge-exec-role`. `verify-lab-10.sh` still reports `PASS=51 FAIL=0` and
`verify-lab-09.sh` still reports `PASS=49 FAIL=1`.

Raw output for every exercise is in `outputs/lab-10-ex*.txt` (git-ignored).

---

## Exercise 1 - Basic: extend the security header set

**What I changed.** One new entry in the `SECURITY_HEADERS` object of
`labs/lab-10-lambda-edge/edge-origin-response/index.mjs`, not a second block of code:

```js
  // Lab 10 Exercise 1 - published as version 2; version 1 keeps the four above.
  'content-security-policy':   { key: 'Content-Security-Policy',   value: "default-src 'self'" }
```

The value contains single quotes, so the JavaScript string is double-quoted.

**Deploy and publish.**
1. Rebuilt the archive from inside the function's directory.
2. Ran `update-function-code`.
3. Waited with `wait function-updated-v2`, then ran `publish-version`, which returned
   **version 2**.

**Proof.** The same Step 13 event was invoked against `$LATEST`, `--qualifier 1` and
`--qualifier 2` (`outputs/lab-10-ex1.txt`):

```text
latest  5 security headers CSP=default-src 'self'
v1      4 security headers no CSP
v2      5 security headers CSP=default-src 'self'
```

Version 1 is untouched. A published version is immutable, which is what makes it safe
to associate.

**The distribution.**
- `templates/lab-10-distribution-config.json` was rewritten by lookup with
  `USMS_DIST_ORIGIN_VERSION=2 USMS_DIST_VIEWER_VERSION=1 ./scripts/utilities/write-lab-10-templates.sh dist`.
  It named `usms-edge-origin-response:2`.
- This build has a real distribution (Path A), so I also updated it:
  `get-distribution-config` (config plus `ETag`), then changed only the origin-response
  ARN.
- Then `update-distribution --if-match <ETag>`, and `wait distribution-deployed`.

I did not send the template itself, because its `CallerReference` is new and
`update-distribution` needs the original one.

```text
viewer-request   ...:function:usms-edge-viewer-request:1
origin-response  ...:function:usms-edge-origin-response:2
```

Exercise 2 then moved both associations on again. Origin-response `:3` carries the same
code, CSP included (checked: `v3 CSP: default-src 'self'`).

---

## Exercise 2 - Intermediate: a dedicated edge execution role

**Policy.** `policies/usms-edge-basic-policy.json`, created as `USMSEdgeBasic`. It grants
only `logs:CreateLogGroup`, `logs:CreateLogStream` and `logs:PutLogEvents`, on two
resources:

```text
arn:aws:logs:*:000000000000:log-group:/aws/lambda/usms-edge-*:*
arn:aws:logs:*:000000000000:log-group:/aws/lambda/us-east-1.usms-edge-*:*
```

**Why two resources, and `*` for the Region.** When CloudFront runs a replica, Lambda@Edge
logs to the Region nearest the viewer, under a group named
`/aws/lambda/us-east-1.<function>`. A policy scoped only to
`arn:aws:logs:us-east-1:...:/aws/lambda/usms-edge-*` would cover direct invocations, but
not one line of real edge traffic. Both resources stay inside `usms-edge-*`, as the
constraint requires. Neither is `*`, and there is no S3 at all.

**Role.** `usms-edge-exec-role`, created from `policies/trust-lambda-edge.json` as-is,
with `USMSEdgeBasic` attached:

```text
lambda.amazonaws.com      True    <- the Lab 09 SourceAccount/SourceArn conditions
edgelambda.amazonaws.com  False
USMSEdgeBasic
```

**Repoint and publish.** For each edge function:
1. Ran `update-function-configuration --role <usms-edge-exec-role>`.
2. Waited with `wait function-updated-v2`.
3. Ran `publish-version`.

This gave viewer-request **version 2** and origin-response **version 3**.
`usms-lambda-exec-role` was not modified: it still carries `USMSLambdaBasic`, and the
notifier still runs as it.

**What each version reports** (`list-versions-by-function`, `outputs/lab-10-ex2.txt`):

```text
usms-edge-viewer-request   $LATEST  role/usms-edge-exec-role
usms-edge-viewer-request   1        role/usms-lambda-exec-role
usms-edge-viewer-request   2        role/usms-edge-exec-role
usms-edge-origin-response  $LATEST  role/usms-edge-exec-role
usms-edge-origin-response  1        role/usms-lambda-exec-role
usms-edge-origin-response  2        role/usms-lambda-exec-role
usms-edge-origin-response  3        role/usms-edge-exec-role
```

### What happened to version 1's role, and why

**Nothing, and that is the point.** A published version is a snapshot of the code
**and** the configuration as it stood when it was published, and the execution role is
part of that configuration. `update-function-configuration` changes only `$LATEST`. The
role change reaches the world only through the next `publish-version`, which is why
version 2 (and origin-response 3) carry the new role and version 1 never will.

**The consequence for rollback.** Rolling back is repointing an association, or an
alias, at an older version, and the older version brings its old role with it. Reverting
the distribution to `:1` today would put the edge back on `usms-lambda-exec-role`, which
can read every object in `usms-student-data`. Rollback is a security change, not only a
code change.

**So the old role cannot be tidied yet.** The `edgelambda` statement stays on
`usms-lambda-exec-role` for as long as any version a rollback might target names that
role. Removing it now would make version 1 unrunnable at the edge exactly when it is
needed.

**Associations.** The new versions only matter if CloudFront uses them, so the
distribution was moved to `viewer-request:2` and `origin-response:3`. This used the same
get-modify-put as Exercise 1, and the template was regenerated by lookup. Results:
- the structural validation: 11 `ok`
- eligibility: 0 `NO` lines

**Audit.**
- **The new HIGH finding.** The new role has the same unconditioned `edgelambda`
  statement, so Lab 09's audit flagged it as HIGH. I added it to
  `configs/usms-iam-accepted-findings.tsv` with a reason, and corrected the
  `usms-lambda-exec-role` entry's reason to say why that statement stays.
- **After:** `HIGH=0 MED=36 ACCEPTED=7 roles=14`, against `HIGH=0 MED=35 ACCEPTED=6
  roles=13` before. The extra MED is the new role's missing permissions boundary.

---

## Exercise 3 - Problem solving: an edge-readiness report

`scripts/utilities/usms-edge-report.sh`.

**How it is built.**
- **One `list-functions`** with `starts_with(FunctionName, 'usms-')`, so there is no
  hard-coded list.
- **Per function,** one `list-versions-by-function` and one `list-aliases`.
- **All decisions in `python3`.** The JSON is built in Python, not concatenated in bash.
  A function with no `Environment` key is handled with `.get(...) or {}`, so `set -u`
  never sees it.
- **Output.** Diagnostics (`inspected 3 usms- function(s)` and any warnings) go to stderr.
  stdout carries only the JSON document.
- **Repository root** from `${BASH_SOURCE[0]}`. Temporary files go in `mktemp -d`,
  removed by a `trap`.

I added one field the exercise did not ask for: `not_eligible_because`, so that a `false`
always comes with a reason.

**Run from `/tmp`, to prove "from any directory"** (`outputs/lab-10-edge-report.json`):

```text
usms-edge-origin-response  nodejs20.x  128 MB  5 s   versions 3  aliases 0  env_vars false  edge_eligible true
usms-edge-viewer-request   nodejs20.x  128 MB  5 s   versions 2  aliases 0  env_vars false  edge_eligible true
usms-transcript-notifier   python3.12  256 MB  30 s  versions 2  aliases 1  env_vars true   edge_eligible false
                                                                  not_eligible_because: ["2 environment variable(s)"]
```

`python3 -m json.tool` accepts the output.

### Where my result differs from the guide's expected outcome

The guide expects the notifier to be ineligible for two independent reasons. Under the
rule as the exercise states it, I find **one**: its environment variables.
- Its name does not contain `viewer`, so it is judged against the origin caps: memory at
  most 10,240 and timeout at most 30.
- At 256 MB and exactly 30 s, it is within both.

The second reason only appears if the notifier is judged as a viewer function (256 > 128
and 30 > 5). Then it fails three ways, not two. I kept the rule as written rather than
bending the script to match the expected count. If the intended second reason was "its
timeout is at the cap with no headroom", that is a design opinion, not an eligibility
rule.

---

## Exercise 4 - Challenge: design the transcript delivery policy

The design is in [`notes/lab-10-edge-design.md`](../../notes/lab-10-edge-design.md).

**The trade-offs it settles:**
- **The session check runs at viewer-request,** so it also runs on cache hits. It is a
  CloudFront Function if the tokens are HMAC-signed, Lambda@Edge if RSA. It must bind the
  token to the student ID in the URI, which Lab 10's function does not do.
- **The cache key is the normalised path only.** The token is deliberately not in it, and
  Lab 10's forwarded `x-usms-student` header is called out as redundant.
- **Corrections:** a long edge TTL with invalidation on S3 `ObjectCreated`, through a
  regional function.
- **The browser header** is rewritten at viewer-response to `private, max-age=60`,
  because five minutes is end to end. This is the case that justifies viewer-response's
  cost.
- **The refusal report** comes from CloudFront standard logs in one bucket, queried in
  Athena and joined to the faculty table, not from edge logs scattered across Regions.
- **Wrong tool:** the report itself, which is not on the request path, and resilience,
  which is an origin group plus `stale-if-error`.
- **Measure first:** the transcript cache hit ratio. If it is low, the whole caching
  design is not worth its machinery.

---

## Exercise 5 - Integration: hand the S3 lab a bucket it can start from

`scripts/utilities/lab-10-s3-readiness.sh`. It is re-runnable and applies nothing.

**1. The draft.** `outputs/lab-09-bucket-policy-draft.json` exists from Lab 09 Exercise
5, so the script uses it. If it were missing, the script would generate the equivalent
with Lab 09's `usms-bucket-policy-draft.sh`, the guide's "use this file if it exists"
pattern. The draft names **eight** roles plus the account root, not the three that carry
`USMSStudentDataReadWrite`. Lab 09 found eight roles with some S3 access to the bucket,
and the draft was kept as Lab 09 wrote it.

**2. Validation.**
- **Resources:** every one must be `arn:aws:s3:::usms-student-data` or start with it
  followed by `/`.
- **Principals:** every `Principal` and `NotPrincipal` ARN must appear in `list-roles`,
  or be this account's root.

```text
statements=10  principals=9  resources=3
MISMATCHES: none
```

A validator that has never failed proves nothing, so I ran it against a copy with two
faults planted (`USMS_DRAFT=<copy>`, `outputs/lab-10-ex5-validator-negative.txt`):

```text
MISMATCHES: 2
  AllowUsmsAnalyticsPartnerRole: resource arn:aws:s3:::usms-student-dta/reports/* is not this bucket
  AllowUsmsBackupOperatorRole: Principal arn:aws:iam::000000000000:role/usms-backup-operatr-role does not exist
```

**Two problems the ARN check cannot see.** I am reporting them for the S3 lab, not
fixing them:
- **`DenyEveryoneElse` uses `NotPrincipal` with role ARNs.** A request made with a role's
  credentials comes from an *assumed-role session*
  (`arn:aws:sts::000000000000:assumed-role/<role>/<session>`), not from the role ARN.
  As I read the IAM documentation on `NotPrincipal` with `Deny`, that deny would then
  match every one of the eight roles' sessions and lock them all out. I could not test
  this on Floci, which evaluates no bucket policy. The safer form is `Principal: "*"`
  with a `StringNotLike` condition on `aws:PrincipalArn`, which does match a session to
  its role.
- **Nothing allows CloudFront.** Lab 10 built a distribution in front of this bucket. If
  the S3 lab adds origin access control, `DenyEveryoneElse` will deny
  `cloudfront.amazonaws.com` too. It needs its own Allow, conditioned on the
  distribution's ARN, and an exemption from the deny.

**3. Not applied.**

```text
aws: [ERROR]: An error occurred (NoSuchBucketPolicy) when calling the GetBucketPolicy operation
no bucket policy - correct
```

**4. The allow trace,** uploaded to `transcripts/evidence/lab-10-edge-trace.json`. First I
regenerated it and checked that it holds the three-stage chain. The notifier saw it
(`outputs/lab-10-ex5-notify.txt`):

```text
USMS_NOTIFY {"bucket": "usms-student-data", "event": "ObjectCreated:Put", "key": "transcripts/evidence/lab-10-edge-trace.json", "readable": true, "size": 676}
```

My first attempt filtered the logs with the quoted term `'"lab-10-edge-trace.json"'`
and found nothing, even after 60 polls. Filtering on `USMS_NOTIFY` and then running
`grep` found the event straight away. On Floci 2.2.0, a quoted term with dots and
hyphens does not match.

**5. `outputs/lab-10-s3-readiness.txt`,** generated by the script:

```text
bucket                 usms-student-data
bucket ARN             arn:aws:s3:::usms-student-data
objects in transcripts/ 3
    transcripts/evidence/ignore-me.txt
    transcripts/evidence/lab-08-scaling-evidence.json
    transcripts/evidence/lab-10-edge-trace.json
notification
    id      usms-transcript-upload
    target  arn:aws:lambda:us-east-1:000000000000:function:usms-transcript-notifier:live
    events  s3:ObjectCreated:*
    filter  prefix=transcripts/, suffix=.json
functions (published versions)
    usms-transcript-notifier     1,2
    usms-edge-viewer-request     1,2
    usms-edge-origin-response    1,2,3
cloudfront supported   yes  (distribution E6X90N1YYWT91G)
bucket policy draft    outputs/lab-09-bucket-policy-draft.json  [existing (Lab 09 Exercise 5)]
    statements=10  principals=9  resources=3
    MISMATCHES: none
    state: no bucket policy - correct, the S3 configuration lab applies it
```

The file is git-ignored: `.gitignore:8:outputs/*  outputs/lab-10-s3-readiness.txt`.

There are three objects under `transcripts/` (the guide asks for at least two). One is
`ignore-me.txt` from Step 21's filter test. It is under the prefix but has the wrong
suffix, so it never triggered the notifier, and it is a useful object for the S3 lab to
find.
