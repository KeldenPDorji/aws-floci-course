# Transcript delivery at the edge - design (Lab 10 Exercise 4)

For: the registrar's office and whoever implements this.
Scope: serving `/transcripts/*` from `usms-student-data` through CloudFront.

## The requirements, restated

1. **Session check.** No transcript is served without a valid session token, and the
   check must not cost an origin request.
2. **Corrections.** A corrected transcript stops being served within five minutes.
3. **No needless re-fetching.** Unchanged transcripts are not re-fetched every five
   minutes.
4. **Refusal report.** Refused requests are counted, by faculty, for the Dean's
   office.
5. **Resilience.** Delivery survives one edge location being unable to reach the
   origin.

## 1. Where each piece of logic runs

| Logic | Runs as | Why |
|---|---|---|
| Session-token check | **CloudFront Function, viewer-request** if tokens are HMAC-signed (HS256); **Lambda@Edge, viewer-request** if they are RSA-signed or must be checked against a revocation list | It has to be viewer-request: that trigger runs on every request, **cache hits included**, before CloudFront looks in the cache. A check at origin-request would run only on misses, so a cached transcript would be served to anyone. A CloudFront Function costs about a sixth as much per request and finishes in under a millisecond. But it has no network access and, as far as I know, only hash and HMAC crypto (`cloudfront-js-2.0` with a KeyValueStore for the key). I would verify that against the runtime docs before committing to it. |
| Bind the token to the transcript | Same function | The Lab 10 function only checks that `x-usms-student` is present. The real check must also compare the token's student ID with the one in the URI (`/transcripts/2026/STU-00417.json`). Otherwise any logged-in student can read any transcript. |
| URI normalisation (lower-casing) | Same function | It is cheap, and it has to happen before the cache key is computed so that `STU-00417` and `stu-00417` are one object. |
| Security headers and TTLs on the stored object | **Lambda@Edge, origin-response** (Lab 10's `usms-edge-origin-response`), or a response headers policy | Anything added at origin-response is stored with the object, so it runs once per cache fill, not once per request. A response headers policy does the four static headers with no code at all, and I would prefer it. |
| Browser-facing `Cache-Control` | **viewer-response** (CloudFront Function) | See section 3. This is the one place the cheaper trigger point is wrong. |
| Invalidate on correction | **Regional Lambda** on S3 `ObjectCreated` for `transcripts/` (the same wiring as `usms-transcript-notifier`) | This happens when an object is written, not when it is requested. |
| Refusal report | **Not a function.** CloudFront logs, queried in Athena | See sections 4 and 5. |

## 2. The cache key

**In the key:** the normalised URI path, and nothing else. CloudFront still compresses
by `Accept-Encoding`, which it handles itself.

**Not in the key, deliberately:**
- **The session token or `Authorization` header.** Every token would become its own
  cache entry, so the hit ratio would fall to roughly zero and the edge would protect
  nothing. The token is checked at viewer-request; it does not need to be part of the
  key.
- **`x-usms-student`.** Lab 10's distribution forwards it in the key. That is harmless
  while it is a student ID that matches the path, but it is redundant: the path already
  identifies the student. And the day someone puts a token in that header, the cache is
  gone.
- **Cookies, query strings, `User-Agent`.**

Anything the origin needs that should not split the cache goes in an **origin request
policy**, not the cache policy.

## 3. Corrections within five minutes, without re-fetching every five minutes

Two different caches are involved:
- `s-maxage` governs CloudFront.
- `max-age` governs the browser.

Lab 10's `public, max-age=300, s-maxage=3600` therefore lets a stale transcript live at
the edge for up to an hour, plus five minutes in the browser. It does **not** meet the
correction requirement on its own.

**Option A - short edge TTL, cheap revalidation.**
- Set `s-maxage=240`.
- When an object expires, CloudFront revalidates with `If-None-Match`, and an unchanged
  transcript costs a `304` with no body.
- The cost is one small origin request per object per four minutes, but only for
  transcripts that are actually being requested.
- Simple, with nothing to fail silently.

**Option B - long edge TTL, invalidate on change (my choice).**
- Keep `s-maxage` long (an hour or a day).
- When a corrected object lands in `transcripts/`, the S3 notification triggers a
  regional function that calls `CreateInvalidation` for that one path.
- Unchanged transcripts are never re-fetched, which meets requirement 3 exactly.
- The cost: invalidation is asynchronous, the first 1,000 paths a month are free and
  later ones are charged, and a failed invalidation fails quietly. So the function must
  retry and alarm.

**Either way, the browser is the limit.**
- Five minutes is end to end. With `max-age=300`, a browser that fetched a transcript
  just before the correction keeps it for five more minutes after the edge is fixed.
- Transcripts are personal records, so `public` is also wrong for shared proxies.
- So the edge keeps its own TTL from the cache policy, and a **viewer-response** function
  rewrites the browser's header to `private, max-age=60` on every response.
- This is the requirement that justifies viewer-response's per-request cost (review
  question 3).
- I would also check whether CloudFront itself declines to cache an object whose
  origin-side header says `private`. That is why the browser header is set at
  viewer-response rather than stored at origin-response.

## 4. Where the refusal report comes from

**Not from the function's logs.** Lambda@Edge logs go to CloudWatch Logs in the Region
nearest the viewer, in a group named `/aws/lambda/us-east-1.<function>`. One day's
refusals would be scattered across a dozen Regions, and a CloudFront Function's logs land
in a single Region regardless.

**From CloudFront's own logs.**
- **Source:** CloudFront standard logs, delivered to one S3 bucket.
- **What they record:** every response CloudFront returned, including a `403` generated
  by an edge function, with its status and URI.

**The query.** An Athena query takes the `403`s on `/transcripts/`, extracts the student
ID from the URI, and joins it to the registrar's student-to-faculty table.

**Two caveats:**
- **A refusal for a malformed URI has no student ID.** It is reported as "unattributed"
  rather than dropped.
- **No token or student identity in edge logs.** Faculty is derived after the fact,
  never logged at the edge.

## 5. Where an edge function is the wrong tool

**The refusal report.** It is a batch question about yesterday, not a decision about this
request. Putting a counter in the viewer function would add latency and a failure mode to
every transcript request, just to produce a number the logs already hold. Athena, run on
a schedule by EventBridge, is the right tool.

**Resilience is also not an edge-function job.** If an edge location cannot reach the
bucket:
- **An origin group** (primary `usms-student-data`, secondary a replicated bucket in
  another Region) fails over on connection errors and 5xx.
- **`stale-if-error`** in the edge TTL lets CloudFront serve a cached copy while the
  origin is unreachable.

Writing retry logic in an origin-request function would reinvent both, badly.

## What I would measure first

1. **The transcript cache hit ratio,** from CloudFront's cache statistics or the logs:
   how often the same transcript is requested twice within an hour.
   - **What would change my mind:** if it is low (each transcript is fetched once or
     twice, at application time), caching barely matters. I would drop option B and the
     invalidation machinery for option A, or simply not cache transcripts at the edge.
     The session check stays at viewer-request either way.
2. **Invalidation completion time,** at the 95th percentile.
   - **What would change my mind:** if it regularly exceeds three minutes, option B
     cannot meet the five-minute window together with a 60-second browser TTL, and
     option A wins.
3. **Corrections per day.** If corrections are rare, invalidation cost is irrelevant.
   If they arrive in bulk, for example after a grading-period correction run, I would
   send a wildcard invalidation per batch rather than one per object.

## Things I would verify before building

- Whether `cloudfront-js-2.0` can verify the token's signature algorithm. If it is RSA,
  the check moves to Lambda@Edge.
- CloudFront's handling of `Cache-Control: private` from the origin with a non-zero
  minimum TTL.
- Whether CloudFront signed cookies with a trusted key group could replace the custom
  token check entirely. They would remove the function, but tie session issuance to
  CloudFront's key format.
