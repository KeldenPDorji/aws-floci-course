# Lab 10 - Edge functions with AWS Lambda - my notes

**Support path: A, on Floci 2.2.0.**
- **CloudFront works as a record.** `list-distributions`, `create-distribution`,
  `get-distribution-config`, `update-distribution` and `wait distribution-deployed` all
  answer. The distribution `E6X90N1YYWT91G` exists and reports `Deployed`.
- **Floci never runs an associated edge function.** A request to localhost:4566 with
  `Host: e6x90n1yywt91g.cloudfront.net` is proxied straight to the S3 origin:
  - **with no `x-usms-student` header:** `200`, the object, and none of the
    origin-response headers (`outputs/lab-10-cloudfront-request.txt`)
  - **the same on real AWS:** the viewer function would return `403` before the cache
    was even consulted

  So the request path proves nothing about the functions. `usms-edge-simulate.sh` is
  the evidence that they compose.

**Lambda did not run at all until I fixed the network.**
- **The symptom.** Every runtime container failed with "Failed to get next invocation":
  - Node invocations timed out
  - Python exited with status 1
- **The cause.** Since Lab 05's ECS tasks, Floci also sits on the `usms-vpc` Docker
  network as `10.0.0.2`, and advertises that address as its Runtime API. A Lambda
  container on the compose network cannot reach it.
- **The fix.** I pinned both ends in `docker-compose.yml`:

  ```yaml
  FLOCI_SERVICES_LAMBDA_DOCKER_HOST_OVERRIDE: floci
  FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK: floci-course_default
  ```

  Then I recreated Floci with `floci-down.sh` and `floci-up.sh`. State survived, as
  always.

**Logs on this build.**
- **What is missing:**
  - `--log-type Tail` returns `LogResult: None`
  - there are no `START`/`END`/`REPORT` lines
- **What works:**
  - the log group `/aws/lambda/<fn>` is created, with a stream
  - everything the handler prints (`console.log`, `print`) lands in it
  - `filter-log-events --filter-pattern USMS_NOTIFY` finds the notifier's lines
- **One snag:** a quoted term containing dots and hyphens (`'"lab-10-edge-trace.json"'`)
  matched nothing. Filtering on `USMS_NOTIFY` and then using `grep` works.

**S3 notifications are delivered,** within about a second of the upload. The filter is
honoured, which is what Step 21's "Your turn" tests.

**`add-permission` drops `--source-account`.** The stored statement keeps
`ArnLike AWS:SourceArn arn:aws:s3:::usms-student-data`, but there is no
`StringEquals AWS:SourceAccount`. Real AWS stores both.

## Step 6 - the trust policy, and a guide step I did not follow as written

**The guide's version would have undone Lab 09.** Step 6 replaces the trust policy with
one statement naming both principals and no condition. That would have silently removed
the `aws:SourceAccount` and `aws:SourceArn` conditions that Lab 09 Exercise 2 put on
`lambda.amazonaws.com`. `update-assume-role-policy` replaces the whole document.

**What I used instead.** `policies/trust-lambda-edge.json` has **two statements**:
- `lambda.amazonaws.com`, with the Lab 09 conditions unchanged
- `edgelambda.amazonaws.com` alone

Before and after are in `outputs/lab-10-lambda-role-trust-{before,after}.json`:

```text
before: [lambda.amazonaws.com, conditioned]
after : [lambda.amazonaws.com, conditioned], [edgelambda.amazonaws.com, no condition]
```

**The audit.** The `edgelambda` statement is now a HIGH finding in Lab 09's audit. It is
recorded in `configs/usms-iam-accepted-findings.tsv` with its reason:
- AWS's documented edge trust has no condition
- edge replicas run in other Regions
- Floci never assumes the role for a replica, so a condition could not be tested here

## Step 9 "Your turn" - the deny path

`templates/lab-10-viewer-request-denied.json` is the allow event with the
`x-usms-student` header removed and `requestId` set to `lab06-deny-0001`. Invoking the
function with it returns a **response**, not a request:

```text
status=403 Forbidden  x-usms-edge=viewer-request-deny  uri key present=False
body={"message":"transcript access requires an authenticated session"}
```

The missing `uri` key is how CloudFront, and `usms-edge-simulate.sh`, know to stop: a
response means "do not go to the origin".

## Step 14 - the deliberate mistake

Setting two environment variables on `usms-edge-viewer-request` **succeeded**, and the
eligibility check then said `NO 2 environment variables set`. I cleared them with
`--environment 'Variables={}'`, after which both functions had no `NO` lines.

Version 1 was published **before** the mistake, so it never had the variables. Had I
published after the mistake and forgotten, the bad version would have been the one to
associate.

## Step 18 "Your turn" - roll forward and back

- **Publish.** `publish-version` on an unchanged `$LATEST` gave **version 2** on Floci.
  On real AWS, Lambda does not create a new version when neither code nor configuration
  has changed since the last one; it returns the existing version. So the guide's "gives
  you version 2" relies on this build. On AWS I would change something first, such as
  the description in the function configuration or a code comment.
- **Repoint.** `update-alias --function-version 2`, then back to `1`. The S3
  notification targets `...:live` and was never touched. That is the whole value of an
  alias: the trigger stays still while the version moves.

## Step 21 "Your turn" - the filter

I uploaded:
- `notes/ignore-me.json` (wrong prefix)
- `transcripts/evidence/ignore-me.txt` (wrong suffix)

The notifier's log gained nothing from either. The only `USMS_NOTIFY` lines are:
- `transcripts/evidence/lab-08-scaling-evidence.json`, the real upload
- `synthetic-probe.json`, the Step 21 fallback invoke
- later, `post-restart-check.json` and `lab-10-edge-trace.json`

**The fallback invoke.** The synthetic event names an object that does not exist. The
notifier's guarded `head_object` recorded `"read_error": "ClientError", "readable":
false` and still returned `{"processed": 1, ...}`. That guard is there because
credentials inside a Floci Lambda container cannot be relied on.

## Step 22 - persistence

After `floci-down.sh` and `floci-up.sh`, the inventory was identical, and the edge chain
still composed. I also proved the notification still **delivers**, not just that it is
still configured:
1. Uploaded `transcripts/evidence/post-restart-check.json`.
2. Saw its `USMS_NOTIFY` line.
3. Deleted it, so the inventory matched again.

That is why its log line appears in screenshot 04 with no matching object.

**EKS after the restart.**
- **The cluster** came back without help: the k3s container restarted, the API server
  was ready, and all three deployments were ready.
- **This shell's kubectl** had lost its *current context*. The `usms-eks` context was
  still in `~/.kube/config`, so I ran `kubectl config use-context usms-eks` to restore it.

## Things the guide assumes that are not true in this repository

- **`COURSE_ROOT`.** In `configs/course.env` it still points at `$HOME/aws-floci-course`,
  an old copy. Every Lab 10 script derives `REPO_ROOT` from `${BASH_SOURCE[0]}` instead.
- **`USMS_ROLE_LAMBDA`.** In `lab-01.env` it is an ARN, so `verify-lab-10.sh` strips it
  to the name.
- **`outputs/.gitkeep`.** It is tracked on purpose, so the guide's "no `outputs/` path
  is tracked" check would fail on a correct repository. It now ignores exactly that file.
- **Shell variables.** The guide carries values in shell variables between steps
  (`EDGE_ROLE_ARN`, `VIEWER_VERSION_ARN`, ...). They are empty in a new terminal, so
  `write-lab-10-templates.sh` and `write-lab-10-env.sh` look every value up and refuse
  to write a hole.

---

## Review questions (Section 14)

### 1. "Move the whole enrolment API to Lambda@Edge, it will be faster for everyone"

**Argument 1: the data does not move.** The enrolment API is a read-write service in
front of one database in one Region. An edge function near a student in Thimphu still
has to cross to `us-east-1` for every enrolment, now from a function that is
cold-started separately at each point of presence. The round trip to the data dominates,
and you have added a hop in front of it. Edge compute is fast only for work that can be
answered **at** the edge: a header, a redirect, a signature check, a cached object.

**Argument 2: the edge is the wrong runtime for an API.**
- **The constraints:**
  - no environment variables, so no per-stage configuration or secrets except by lookup
  - 5 s and 128 MB at the viewer triggers
  - no VPC, so no private path to `usms-db-01`
- **Deployment:** every change is a new version, replicated globally, which takes
  minutes. A rollback is another replication.
- **Logs:** they land in whichever Region was nearest each viewer, so one incident's
  logs are spread across a dozen Regions.

ECS behind an ALB, or Lambda in the Region with the database, has none of these limits.

**When they would be right.** For a part of the API that is read-heavy, the same for
many users, and tolerant of slightly stale data, such as the published course catalogue
or the term timetable. Then the edge, through **caching** in front of the regional API
and perhaps an edge function to normalise the cache key, makes it faster for everyone.
That is CloudFront doing its job, not the API moving to the edge.

### 2. CloudFront Functions versus Lambda@Edge

| | CloudFront Functions | Lambda@Edge |
|---|---|---|
| Runtime | A restricted JavaScript runtime (`cloudfront-js-1.0` / `2.0`) | Node.js or Python, a full Lambda runtime |
| Trigger points | viewer-request, viewer-response only | all four: viewer-request/response, origin-request/response |
| Limits | sub-millisecond compute, small code size, **no network**, no request body | 128 MB / 5 s at viewer triggers, up to 10,240 MB / 30 s at origin triggers; network allowed; body available on request triggers |
| Where it runs | every edge location | Regional edge caches |
| Relative cost | about one-sixth of Lambda@Edge per request, with no duration charge | per request plus per GB-second |

- **Append `/index.html` to a URI: CloudFront Function, viewer-request.** It is a string
  operation on the request, needed on every request, needing no network. Paying Lambda@Edge
  prices and latency for it would be waste.
- **Check a JWT signature: CloudFront Function, if the algorithm is HMAC.** The 2.0
  runtime has HMAC, and a KeyValueStore holds the key. If the token is RSA-signed, or must
  be checked against a revocation list, it is **Lambda@Edge, viewer-request**, because
  that needs asymmetric crypto or a network call. Either way it is viewer-request, so the
  check also covers cache hits.
- **Fetch a per-user redirect from DynamoDB: Lambda@Edge.** CloudFront Functions cannot
  make network calls at all. I would put it at viewer-request, because the answer is
  per-user and must not be cached under a shared key. I would keep the table small and
  replicated (a global table), or the "edge" function makes a cross-ocean read on every
  request.

### 3. origin-response versus viewer-response for the security headers

**The two trigger points run at different times.**
- **origin-response** runs once, when CloudFront receives the object from the origin and
  **before** it is stored in the cache. The headers become part of the cached object, so
  every later hit is served with them at no further cost.
- **viewer-response** runs on **every** response to a viewer, hits included.

The output is identical. The invocation count is not: a 95% hit ratio means
viewer-response runs twenty times as often for the same headers.

**What forces viewer-response anyway: anything that must differ per viewer, or must not
be stored.**
- **A value computed per request:** a CSP nonce, a request ID echoed back, or a
  `Set-Cookie`. If stored at origin-response, it would be cached and served to everyone.
- **A browser-facing `Cache-Control`** that differs from the edge's own caching. For
  Exercise 4's transcripts I want CloudFront to hold an object for an hour, but the
  browser to see `private, max-age=60`.

  If origin-response wrote `private`, it would be stored with the object, and could
  affect whether CloudFront caches it at all. Writing it at viewer-response changes only
  what the browser receives.

### 4. The notifier's two policies are not redundant

They govern **different calls, made by different principals.**

**The resource policy on `usms-transcript-notifier:live`** answers "who may call
`lambda:InvokeFunction` on this function?". It lets `s3.amazonaws.com` do so, from
`arn:aws:s3:::usms-student-data`.
- **The call:** S3 invoking Lambda, when an object is created.
- **If deleted:** uploads still succeed, but S3 can no longer invoke the function, so
  notifications stop, with no error at the uploader.
- **On real AWS,** `put-bucket-notification-configuration` would also refuse to save a
  configuration naming a target S3 cannot invoke. That is the troubleshooting entry
  "Unable to validate the following destination configurations".

**The execution role, `usms-lambda-exec-role` with `USMSLambdaBasic`,** answers "what may
the function's own code call?". It grants `s3:GetObject` on `usms-student-data/*` and log
writes.
- **The call:** the function calling `head_object` and writing logs.
- **If deleted:** S3 still invokes it, the function runs, and then its own `head_object`
  is denied. The notifier would log `readable: false` for every object, and without the
  log permissions you would not even see that.

**The analogy:** one is the lock on the function's front door, the other is the keys the
function carries. On Floci neither is checked, which is why the evidence for both is the
documents, read back.

### 5. `--source-arn` and `--source-account`: the confused deputy

**The attack.** Without them, the statement says "the S3 service may invoke this
function", for **any** bucket, in **any** account.
1. An attacker creates their own bucket, in their own account.
2. They point its `ObjectCreated` notification at
   `arn:aws:lambda:us-east-1:000000000000:function:usms-transcript-notifier:live`.
3. S3, the deputy, holds the permission and invokes our function on the attacker's
   behalf.
4. Our function runs with our role, on events the attacker controls. They can trigger it
   at will (cost, log noise), feed it object keys of their choosing, and exploit whatever
   the function does with them. A notifier that later posted to a registrar channel would
   post their messages.

**What the conditions do.** `--source-arn arn:aws:s3:::usms-student-data` restricts the
grant to events from our bucket. `--source-account` closes the gap S3 ARNs leave: bucket
names are global, and an ARN contains no account, so a bucket deleted and re-created
elsewhere with the same name would otherwise still match. Floci stored the first and
dropped the second, so that gap is real on this build.

**The Lab 09 equivalent:** the `aws:SourceAccount` and `aws:SourceArn` conditions on
`usms-ecs-task-role`'s, and in Exercise 2 `usms-lambda-exec-role`'s, **trust** policies.

**Why they are the same idea.** In both cases a service principal acts for someone, and
the policy must say **for whom**. "This service may do X" is never enough when the
service serves every AWS customer. The condition binds the grant to our own resource and
account. Lab 09 applied it to who may **assume** a role; Lab 10 applies it to who may
**invoke** a function.

### 6. Environment variables on an edge function: where validation happens

**Lambda has no idea the function is meant for the edge.** To Lambda,
`usms-edge-viewer-request` is an ordinary regional function, and environment variables
are perfectly legal on one. So `update-function-configuration` succeeds, and so does
`publish-version`.

**Validation happens only when the edge use is declared:** when a distribution update
associates that version with a trigger. CloudFront (on real AWS) then checks the version
against the trigger's rules:
- a qualified ARN, in `us-east-1`
- no environment variables
- within the caps
- a supported runtime

It rejects the **whole** `update-distribution`, minutes later, with an error about a
resource other than the one you just edited. On Floci it is not validated at all: the
distribution accepted a `$LATEST` ARN without complaint.

**What this means for checking edge configuration.** It has to be done by **reading the
configuration back against the rules, yourself, before the association**. That is what
`lab-10-edge-eligibility.sh`, Exercise 3's report, the distribution validator and
`verify-lab-10.sh`'s static checks do. They are not duplicates of a validation that will
happen anyway. On this build they are the only validation, and on AWS they move the
failure from "a distribution update failed later" to "this function is not eligible,
now".

**The general rule.** Step 14's command exited 0 and did exactly what it was told. It did
not do what I meant, which was "configure an edge function". An exit code reports that
the API accepted the request, not that the result is valid for its purpose. Evidence
comes from reading the state back against the requirement: the eligibility check's
`NO 2 environment variables set` is the evidence, and the `0` from the update was not.
