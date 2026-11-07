Support path: mixed (probe, Step 4) - logs, metric filters, custom metrics, alarms and dashboards work and are really evaluated; X-Ray is absent, composite alarms cannot be created, Logs Insights runs only `fields | limit`.

# Lab 13 - Centralized logging and monitoring with CloudWatch and X-Ray - my notes

## What the probe said, and what was true

`lab-13-support-probe.sh` is the guide's probe plus four lines of mine. Running things showed
more than the probe can, and in two places the guide's own "Floci vs Real AWS" table (Section 11)
is more pessimistic than this build.

| What | Observed on Floci 2.2.0 |
|---|---|
| Log groups, streams, `put-log-events`, `filter-log-events`, retention, `tag-resource` | Work. Retention is stored; expiry is not enforced |
| `test-metric-filter` | Works, including space-delimited fields and `extractedValues` (Exercise 1) |
| Metric filters on ingestion | **Evaluated** (the guide expects "frequently not"). `defaultValue` is emitted once per non-matching event, so a quiet group gives an empty `Datapoints` list and a busy one gives zeros |
| Quoted filter terms | `"ERROR USMS_EVENT"` works. A quoted term with hyphens, `"checkpoint-01-demo"`, matches nothing, while the unquoted form matches; AWS requires the quotes, so neither is portable |
| `put-metric-data`, `list-metrics`, `get-metric-statistics` | Work. No 1,440-datapoint limit (AWS has one) |
| `put-metric-alarm`, `set-alarm-state` | Work |
| Alarm **evaluation** | **Real** (the guide expects none). `usms-transcript-lag-high` went to ALARM 41 s after two slow transcripts and back to OK; `usms-notify-silence` fired by itself during a quiet spell; a forced state was reverted within about 11 s |
| `describe-alarm-history` | Unsupported |
| `put-composite-alarm` | Unsupported (both protocols). The composite exists as `templates/lab-13-composite-alarm.json`, evaluated locally by `lab-13-composite-eval.sh` |
| Dashboards | Stored, returned, validated (`DashboardValidationMessages: []`); nothing renders them |
| Logs Insights | `start-query` completes only `fields ... \| limit`; every `filter`, `stats` and `parse` query fails; `describe-queries` is unsupported. Recorded as `partial` |
| X-Ray | Absent: every call is `UnknownOperationException` |
| Lambda `TracingConfig: Active` | Stored per version; no `_X_AMZN_TRACE_ID` reaches the handler, so the notifier's `trace_id` is its request-id fallback |
| S3 notification to the notifier alias | Real: an upload invokes `live` and produces a `USMS_NOTIFY` line within seconds |

**Version numbers.** Lab 10's "Your turn" had already published a version 2, so the guide's "v2"
(the instrumented handler) is **version 3** here and its "v3" (active tracing) is **version 4**.
`write-lab-13-env.sh` finds both by their descriptions, not by assuming the numbers.

## Three things that changed what I built

- **The `--log-events` shorthand cannot carry a structured line.** Step 7's
  `timestamp=...,message=USMS_EVENT {"event":...}` fails with `ParamValidation` before anything is
  sent: the shorthand parser reads the quotes and commas inside the JSON as its own syntax. Every
  write of a `USMS_EVENT` line, including the emitter, sends JSON through a `file://` document.
- **Alarm states are not stable facts here.** Because Floci evaluates, the guide's restart
  inventory (which listed states) would differ for reasons that have nothing to do with
  persistence. The inventory lists alarm **configuration**; states are read separately.
- **The composite alarm is a document, not a resource.** Every place that would read it from
  CloudWatch reads `templates/lab-13-composite-alarm.json` instead, and says so.

## Step 7 "Your turn" - a line no filter should count

`health check ok: usms-transcript-notifier reachable` was written to the same stream, and
`rejectedLogEventsInfo` was `null`. `filter-log-events` returned 5 rows.

**It is not later than the four events, as the guide asked.** It was sent first, while the
shorthand was still failing for the four structured lines, so its timestamp (`...447846`) falls
between events 2 and 3, and it sorts third. Separate `put-log-events` calls may arrive out of time
order; only the events **within** one call must be in order. It still did its job: Step 9's two
filters count neither it nor anything like it.

## Step 8 "Your turn" - a pattern for the error filter, and its false positive

Tested with `test-metric-filter` only (`outputs/lab-13-filter-test-errors.txt`):

| Pattern | Matches among the four Step 7 lines + `{"reason":"no ERROR here"}` |
|---|---|
| `ERROR` | 4 **and 5**: the false positive |
| `"ERROR USMS_EVENT"` (deployed) | 4 only |

**What the false positive did.** Plain `ERROR` is a term match anywhere in the message, so a
successful transcript whose payload merely contains the word is counted as a failure. In
production that is an error-rate alarm that fires on a reason string.

**Would I accept the deployed pattern?** For now, yes, but it has its own false positive, which I
found afterwards: `"ERROR USMS_EVENT"` is a phrase match, so a payload that quotes the phrase
(`{"note":"ERROR USMS_EVENT quoted in a payload"}`) also matches. The positional pattern
`[level="ERROR", marker="USMS_EVENT", payload]` matches only a line whose **first two tokens** are
the level and the marker, and rejects both false positives. I would move to it, because it
anchors on the line's structure rather than on words that can appear anywhere.

## Step 10 "Your turn" - is `defaultValue` doing anything?

`NotifyCount`, period 300 (`outputs/lab-13-step10-yourturn.txt`):
- **Window A**, 11:54-12:09Z, before any upload: `[]`.
- **Window B**, 12:09-12:24Z, including the upload: one datapoint, `Sum 2.0` from `SampleCount 4.0`.

**An empty `Datapoints` list** means nothing at all reached the filter in that window: no events
in the group. **A list of zeroes** would mean events arrived and none matched. My build produced
both kinds of evidence. Window A is empty, so `defaultValue` does **not** fill a silent period.
Window B has four samples for two matches, so it is emitted once per non-matching event: the
invocation's other log lines each contributed a 0. That is why `usms-notify-silence` must treat
missing data as breaching: on a quiet night there are no zeroes to compare with the threshold,
only nothing.

## Step 13 "Your turn" - roll back, confirm, roll forward

(`outputs/lab-13-step13-yourturn.txt`)
- **`live` -> 1:** executed version 1; payload keys `['keys', 'processed']`, no `trace_id`.
- **`live` -> 3:** executed version 3; keys `['keys', 'processed', 'seconds', 'trace_id']`.
- **Throughout:** `list-versions-by-function` showed `$LATEST`, 1, 2 and 3. Nothing was deleted.
  Step 14 then published 4 and moved `live` to it, where it stays.

**How long a real rollback would take.** One `update-alias` call, effective for the next
invocation within seconds; only invocations already running finish on the old version. Lab 10's
note on Lambda@Edge put that rollback at minutes: edge functions cannot be referenced through an
alias, so a rollback means pointing the distribution at an older numbered version and waiting
for it to replicate to every edge location. "Another replication", against one API call.

---

## Review questions (Section 14)

### 1. "We have logs, so we do not need metrics"

**Argument 1: the question "is it broken right now?" is cheap on a metric and expensive on
logs.** A metric is already aggregated: one number per period, whatever the traffic. An alarm
compares it with a threshold every minute for almost nothing. Answering the same question from
logs means scanning them every minute, which costs per GB scanned and gets slower as traffic
grows. And a log query cannot easily alarm on **nothing**: `usms-notify-silence` fires on the
absence of data, and there is no log line to find for a notification that never happened.

**Argument 2: logs are expensive to keep and metrics are not.** Logs are billed per GB ingested and
stored, so we set retention to 14 or 30 days and lose the history. A metric costs the same per
month whether it summarises ten events or ten million, and CloudWatch keeps it for 15 months at
decreasing resolution. "Was last September's enrolment week slower than this one?" can be
answered from metrics long after the logs have expired.

**When they are right.** When the number they need can be **derived** from logs they already
write. Then they do not need to publish metrics separately: a metric filter makes one at no code
cost, as `NotifyCount` and `CentralErrorCount` were in this lab. They still need metrics; they
do not need to instrument for them. Logs are also the only answer to a one-off forensic question
about a single event ("who downloaded this transcript?"), which no metric can answer.

### 2. Metric filter or direct metric

| | Metric filter (Step 9) | `put-metric-data` (Step 11) |
|---|---|---|
| Retroactive? | No: it counts only events ingested **after** it was created. Step 7's lines were never counted by Step 9's filters | No: data exists from the first call. But logs keep history, so a query can still answer retrospectively within retention, which a missing metric cannot |
| Cost | The log ingestion we already pay for, plus the custom metric | An API call per publish, plus the custom metric; nothing to ingest |
| To add a measurement | Configuration only, **if** the line already carries it. Exercise 1 showed the catch: extracting a value forced a change to the line itself | A code change and a deployment (Step 13 published a new version for it) |
| Code that is not ours | The only option: we can filter its logs, not edit its calls | Impossible |

**"How many transcript downloads happened"** belongs to a filter. A download is an event that is
logged anyway, often by a component we do not own (S3 access logs, CloudFront logs), and
counting lines is what a filter does well.

**"How long the render took"** belongs to a direct metric. It is a **measured value**: the code
that renders knows it precisely, can attach the right unit and dimensions, and is ours to change.
Getting it through logs means designing the log line around the filter's tokeniser, which is
what Exercise 1 cost.

**Why the answers differ.** A count is the natural shape of a log. A measurement is the natural
shape of a metric, and the code that measures should publish it.

### 3. Missing data: `notBreaching` on the lag alarm, `breaching` on the silence alarm

**`breaching` on `usms-transcript-lag-high` would be wrong.** No data means no transcripts were
processed, so there is no latency to judge. Treating that as slow would page someone every quiet
night for a latency problem that does not exist.

**`notBreaching` on `usms-notify-silence` would be wrong.** No data **is** the condition it exists
to detect. When nothing invokes the notifier, nothing is logged and the filter emits nothing, not
even a zero (Step 10's "Your turn"). With `notBreaching`, the alarm could never fire for the only
reason anyone created it.

**An incident only the second catches.** Someone runs `put-bucket-notification-configuration` to
add an unrelated rule and leaves ours out: it is a replace-only API, it returns success, and the
bucket stops calling the notifier. Uploads still succeed, nothing errors, no latency is recorded.
`usms-transcript-lag-high` sees no data and stays `OK`; `usms-notify-silence` goes to `ALARM`
after three empty five-minute periods. On this build it did exactly that, by itself, during the
lab's quiet spell: the newest `USMS_NOTIFY` line was at 12:21:46Z and the alarm changed at
12:50:05Z, with no `set-alarm-state` involved.

**The dashboard during it.** All green. The latency graph shows no points, so it never crosses
its threshold line. "Notifications in the last 5 minutes" shows no value, and the lag alarm tile
reads OK. Only the silence alarm's tile, and the composite, would show anything wrong. That is
the registrar's first complaint in Exercise 4, word for word.

### 4. Metric dimension or X-Ray annotation

**A dimension** is part of a metric's identity. Every distinct combination of dimension values
is a separate time series, aggregated in advance and billed as a separate custom metric. It is
indexed for **graphing, statistics and alarms**: "the Maximum latency for engineering, per
minute". As distinct values grow, the number of metrics, and the bill, grows with them, and each
series becomes too sparse to alarm on.

**An annotation** is an indexed key-value pair on a trace segment. It is indexed for **finding
traces**: `annotation.faculty = "science" AND responsetime > 2`. Its cardinality hardly matters,
because each trace simply carries its own value. But traces are sampled, so annotations answer
"show me examples", never "how many".

**Placing the four values:**
- **The transcript's faculty: a dimension** (and an annotation too, harmlessly). It has about ten
  values, and per-faculty counts and alarms are exactly what we want. One caution from this lab:
  the notifier derives it from the object key, and a test upload under `transcripts/evidence/`
  created a faculty called `evidence`. A small set of values is a cost guard, not a guarantee
  that the values are right.
- **The student's id: an annotation, never a dimension.** Thirty thousand students would be thirty
  thousand time series, each with almost no data. As an annotation it lets support find "the
  trace for this student's failed request", which is the only question anyone asks about a single
  student.
- **The origin's HTTP status: a dimension, bucketed** into `2xx`, `4xx` and `5xx`, so the error rate
  can be graphed and alarmed. The exact code goes on the trace as an annotation (X-Ray records it
  in `http.response` anyway) for finding examples.
- **The renderer's name: an annotation**, so "show me slow traces from renderer B" is one filter
  expression. It becomes a dimension only if there are a handful of renderers and we intend to
  alarm on each one's latency separately.

### 5. Why a configuration change needed its own version

(Guide numbering: Step 13's "version 2" is version 3 here, and Step 14's "version 3" is version 4.)

**A published version is an immutable snapshot of the code and the configuration.** That
includes `TracingConfig`. `update-function-configuration` changes only `$LATEST`. The alias points
at a numbered version, so production would not see the change until a version containing it was
published and the alias moved to it.

**Leaving the alias on version 3 would have looked fine and changed nothing.** The unqualified
`get-function-configuration` would report `Active`, because it reads `$LATEST`, while every real
invocation through `live` ran on PassThrough. The command succeeded; it simply did not do what I
meant. Screenshot 04 shows both at once: `live` is version 4 with `Active`, and version 3 is still
`PassThrough`, because publishing 4 did not and could not change 3.

**Lab 10 Step 11 said a version freezes code and configuration.** This is that claim, observed:
the same handler in two versions, differing only in one configuration field, each keeping its own
value for ever. It is also why the rollback in Step 13's "Your turn" is safe: version 1 still has
Lab 10's exact code **and** settings.

### 6. What forcing an alarm proves

**What it proves.** The alarm exists under the name the runbook uses, it can change state, and the
transition is recorded with a reason (`outputs/lab-13-alarm-history.json`). On real AWS,
`set-alarm-state` also runs the alarm's actions, so it is the standard way to test the notification
path without breaking anything.

**What it does not prove.** Anything about the threshold, statistic, period, dimensions or
missing-data policy. A forced `ALARM` succeeds on an alarm whose dimension set matches no data at
all, which would sit in `INSUFFICIENT_DATA` for ever.

**What the equivalent test proves on real AWS and cannot here.** That the action chain works: the
SNS topic exists, its policy lets CloudWatch publish, someone is subscribed, and the page arrives.
Floci invokes no actions, and these alarms have none yet (Exercise 5's draft is unapplied).

**Why test after the alarm fires, even with a good threshold.** The moment an alarm fires is the
one moment everything downstream must work, and it is the moment least often exercised. An
unconfirmed email subscription or a topic policy that drops CloudWatch's publish fails silently,
and is discovered during the incident it was meant to announce.

**The rule about apparent success.** `set-alarm-state` returned success and the state changed. That
looks like proof, but it proved only that the state can be written. On this build, Floci's
evaluation put the alarm back to `OK` within about 11 seconds. That reversion, and the separate
real-evaluation test (two slow transcripts, `ALARM` after 41 s, `OK` again after 92 s,
`outputs/lab-13-alarm-real-evaluation.txt`), are the evidence that the **configuration** works.
The forced transition is evidence only that the alarm exists.
