# Lab 13 - Centralized Logging and Monitoring with CloudWatch and X-Ray

## 1. Summary

This lab gave USMS an observability layer: logs that expire deliberately, metrics derived from
those logs and published directly, two alarms with opposite missing-data policies joined by a
composite rule, a dashboard kept in version control, and a trace design.

**Logs:**
- **A central group.** `/usms/central/application`, 30 days, tagged `Project=USMS`, `Lab=13`.
- **Retention everywhere.** Every USMS log group now has a retention period: 30 days for
  application groups, 14 for function and build groups. Before this lab only one had any.
- **Structured events.** `USMS_EVENT` lines written with millisecond timestamps, plus one line no
  filter should count.

**Metrics:**
- **From logs.** `usms-notify-count` (on the notifier's group) and `usms-central-errors` (on the
  central group), both tested with `test-metric-filter` before they were deployed.
- **Published directly.** `TranscriptsProcessed` with and without dimensions,
  `TranscriptLagSeconds` and `EdgeDenyCount`, all in `USMS/Application`.
- **Permission.** `USMSObservabilityWrite`, on the Lambda and EC2 roles. Its `PutMetricData` is
  conditioned on that namespace, and the simulator shows `AWS/Lambda` is refused.

**The notifier:**
- **Instrumented.** Version 3 publishes its own metrics and a `USMS_SUMMARY` line.
- **Traced.** Version 4 adds tracing `Active`; `live` follows it.
- **Why the numbers differ from the guide.** Lab 10 had already made a version 2, so the guide's
  "v2" and "v3" are 3 and 4 here.

**Alarms, dashboard, traces:**
- **Two alarms.** `usms-transcript-lag-high` (Maximum, 2 of 3 minutes, `notBreaching`) and
  `usms-notify-silence` (Sum below 1 for 15 minutes, `breaching`).
- **The composite.** `usms-transcript-pipeline-down` joins them.
- **The dashboard.** `usms-overview`, 5 widgets (6 after Exercise 2).
- **Traces.** Three segment documents, a sampling rule, and a telemetry emitter that joins a log
  line, a metric and a trace id.

**What ran on Floci 2.2.0: more than the guide expects in one place, less in another.**
1. **The guide expects alarms never to evaluate. Here they really do.**
   - **A real breach.** Two slow transcripts put `usms-transcript-lag-high` into `ALARM` after 41 s
     and back to `OK` after 92 s.
   - **A forced state.** It was reverted by evaluation within about 11 s.
   - **The silence alarm.** It fired **by itself**, 28 minutes after the last notification, with
     nothing forced.

   Metric filters are evaluated on ingestion too.
2. **X-Ray is absent and composite alarms cannot be created.** Every X-Ray call returns
   `UnknownOperationException`, and so does `PutCompositeAlarm`.
   - **The traces.** The segment documents are checked by a structural validator (10 checks, and
     a negative test that catches 4 faults).
   - **The composite.** It is a committed request document, evaluated against the live child
     states by a script.
3. **Logs Insights is partial.** Only `fields ... | limit` completes. Step 23's question was
   answered by retrieving and aggregating locally.

**Verification:**
- **`verify-lab-13.sh`:** `PASS=49 FAIL=0`, with five commented adaptations, one of which fixes a
  JMESPath bug in the guide. After Exercise 2 the widget count it checks is 6; still `49/0`.
- **Regression:** Lab 10 `51/0`, Lab 12 `45/0`. Every earlier lab matches its recorded baseline.
- **`configs/lab-13.env`:** 28 exports, all populated.

**What exists at the end of this lab**

| Category | Resources |
|---|---|
| CloudWatch Logs | `/usms/central/application` (30 d, tagged; streams `lab-13-20261106`, `emitter-20261106`); retention on the 8 other USMS groups (30 d app, 14 d function and build); Floci's own `/aws/ecr/registry` left alone |
| Metric filters | `usms-notify-count` (USMS_NOTIFY to `NotifyCount`), `usms-central-errors` (`"ERROR USMS_EVENT"` to `CentralErrorCount`), `usms-transcript-seconds` (Exercise 1, extracts `$seconds`) |
| Metrics | `USMS/Application`: the five the lab defines, plus `TranscriptSecondsFromLogs` (Exercise 1) |
| IAM | `USMSObservabilityWrite` on `usms-lambda-exec-role` and `usms-ec2-app-role` |
| Lambda | `usms-transcript-notifier` versions 1-4; `live` on 4 (`Active`); 3 is the instrumented, PassThrough version |
| Alarms | `usms-transcript-lag-high`, `usms-notify-silence` (tagged `Lab=13`, no actions); the composite as `templates/lab-13-composite-alarm.json` |
| Dashboard | `usms-overview`, generated from `templates/lab-13-dashboard.json`, 6 widgets |
| Files | 1 policy, 7 templates, `configs/lab-13.env`, the notifier v2 source, the scripts in Section 3.11, `scripts/cleanup/lab-13-cleanup.sh` (never run), and `project/checkpoint-01/` |

---

## 2. Evidence index

Eight screenshots, each on one screen. Everything else is command output under `outputs/`
(git-ignored), quoted where it is used. The exercises came after the screenshots; their evidence
is `outputs/lab-13-ex*.txt` and [exercises.md](exercises.md).

| # | Proves | Section |
|---|---|---|
| 01 | Checkpoints 1-2: the support probe, each line named for the call it makes; Step 5's inventory (one group of nine with retention); every USMS group now on 14 or 30 days; the central group's tags `Lab=13`, `Project=USMS` | [3.1](#31-checkpoints-1-2---probe-inventory-retention) |
| 02 | Checkpoints 3-4: six central events with millisecond timestamps, including the non-matching health line; Step 8's test (one match); the error-pattern test (`ERROR` matches 4 and 5, `"ERROR USMS_EVENT"` matches 4); both filters on the right groups | [3.2](#32-checkpoints-3-4---events-and-filters) |
| 03 | Checkpoints 5-6: `NotifyCount` empty before the upload and `Sum 2 / SampleCount 4` with it; the metrics by dimension set; lag statistics; `[]` for a dimension set never published; `CentralErrorCount` read back | [3.3](#33-checkpoints-5-6---metrics) |
| 04 | Checkpoints 7-8: the policy on both roles; `USMS/Application` allowed, `AWS/Lambda` `implicitDeny`; `live` = 4 `Active`, 3 `PassThrough`; the instrumented `USMS_NOTIFY` and `USMS_SUMMARY` lines; the dimensions the function published | [3.4](#34-checkpoints-7-8---iam-and-the-notifier) |
| 05 | Checkpoints 9-10: X-Ray absent; 10 validator checks pass and the negative test fails 4; the sampling rule complete and accepted by the CLI's request model; 6 trace ids; the last trace id found in the central log | [3.5](#35-checkpoints-9-10---traces) |
| 06 | Checkpoint 11: both alarms' configuration; real evaluation in both directions; the forced transition, its reversion, the restore; the silence alarm firing by itself; the composite evaluated | [3.6](#36-checkpoint-11---alarms) |
| 07 | Checkpoints 12-13: 5 widgets of 3 types; validation `[]`; the Insights probe; faculty counts by path B; identical inventories either side of the restart; 3 data points before and after | [3.7](#37-checkpoints-12-13---dashboard-queries-restart) |
| 08 | Section 8: `PASS=49 FAIL=0`; 28 exports and the looked-up values; only `outputs/.gitkeep` tracked; `outputs/*` ignored; `verify-lab-12` `45/0` | [3.8](#38-verification-and-hygiene) |

---

## 3. Build walkthrough (Steps 1-26)

### 3.1 Checkpoints 1-2 - probe, inventory, retention

**Steps 1-3.** Floci was up; every `configs/lab-NN.env` sourced without error; `whoami.sh`
reported `000000000000`. Lab 10's verification was `51/0` before anything changed.

**Step 4.** `lab-13-support-probe.sh` is the guide's probe in a script, with four probes added
for calls later steps depend on: `get-trace-summaries`, `test-metric-filter`, Insights
`start-query`, and a read of composite alarms. Two lines are labelled differently from the guide,
because the first screenshot showed them misleading:
- **The guide labels its `describe-queries` probe "Insights start-query".** It is now labelled
  for the call it makes. A separate `start-query` probe shows that call is accepted.
- **My composite probe only reads.** It is labelled `composite: describe only`, with a note that
  `PutCompositeAlarm` is unsupported. A write probe would create an alarm on real AWS.

**Step 5.** `lab-13-telemetry-inventory.sh` found what seven labs had already produced:
- nine log groups, eight of them on never-expire, including `/ecs/usms-enrolment` at 224 kB
- five alarms nobody in this lab created: Lab 06's four target-tracking alarms (all
  `INSUFFICIENT_DATA`, because Floci publishes no `AWS/ECS` metrics) and `usms-enrolment-queue-high`
- two custom namespaces

**Step 6.**
- **The central group** was created and tagged with `tag-resource` (the ARN read back, `:*`
  included).
- **A retention function** set 30 days on the three application groups and 14 on the six
  function and build groups, reporting `absent, skipped` for any it could not find.
- **Floci's own `/aws/ecr/registry`** is not a USMS group and was left alone.

![Checkpoints 1-2: lab-13-support-probe.sh - logs, metric filters, list-metrics, describe-alarms, list-dashboards, get-function-config, test-metric-filter, Insights start-query and composite describe SUPPORTED; Insights describe-queries and three X-Ray probes UNSUPPORTED; note that PutCompositeAlarm is unsupported and Insights runs fields|limit only; the Step 5 inventory with every group but /usms/ecs/enrolment on None; every USMS group now 14 or 30, /aws/ecr/registry None, /usms/central/application 30; tags 13 USMS](../../screenshots/lab13-01-checkpoint1-probe-retention.png)

### 3.2 Checkpoints 3-4 - events and filters

**Step 7.**
- **The guide's `--log-events` shorthand failed** with `ParamValidation` on the first structured
  line (Section 6.1), before anything was sent. All four events went as a JSON document through
  `file://`, with `rejectedLogEventsInfo` `null`.
- **The "Your turn" health-check line** was sent first, while the shorthand was still failing, so
  its timestamp sorts third, not last. It is still the negative case Step 9 needed. Separate calls
  may be out of order; events within one call may not.

**Step 8.** `test-metric-filter` with `USMS_NOTIFY` against the notifier's real message shapes
gave exactly one match. **Your turn:**
- **Plain `ERROR`** matched the error line **and** the false positive `{"reason":"no ERROR here"}`.
- **`"ERROR USMS_EVENT"`** matched the error line only. I deployed it.
- **Exercise-time follow-up:** it also matches a payload that quotes that phrase. The positional
  `[level="ERROR", marker="USMS_EVENT", payload]` rejects both, and the notes recommend it.

**Step 9.** Both filters were put with `defaultValue=0` and read back on the right groups. Each
metric filter's group is checked by `verify-lab-13.sh`, because a filter on the wrong group
counts nothing and reports nothing.

![Checkpoints 3-4: six events in lab-13-20261106 with 13-digit timestamps, including the health-check line; TestMetricFilter one match on the USMS_NOTIFY line; ERROR matches events 4 and 5, "ERROR USMS_EVENT" matches 4 only; usms-central-errors on /usms/central/application "ERROR USMS_EVENT" CentralErrorCount and usms-notify-count on /aws/lambda/usms-transcript-notifier USMS_NOTIFY NotifyCount](../../screenshots/lab13-02-checkpoints2-4-central-log-filters.png)

### 3.3 Checkpoints 5-6 - metrics

**Step 10.** An upload to `transcripts/evidence/` invoked the notifier through `live`, and one
`USMS_NOTIFY` line reached its group. The filter produced a `NotifyCount` datapoint: Floci
evaluates filters on ingestion, so the guide's "record why not" fallback was not needed.

**Your turn: is `defaultValue` doing anything?**

| Window | Result |
|---|---|
| Before any upload | `[]` |
| Including the upload | `Sum 2.0` from `SampleCount 4.0` |

The four samples are the two matching lines, plus one zero for each of the invocation's other
lines. So on this build `defaultValue` is emitted per **non-matching event**, never for a silent
period. That is what makes the silence alarm need `breaching` (notes, question 3).

**Step 11.** `templates/lab-13-metric-data.json` (generated with a fresh timestamp) published
`TranscriptsProcessed` with `Faculty,Stage` and without dimensions, plus `TranscriptLagSeconds`
and `EdgeDenyCount`. The read-back makes the identity rule visible:
- `TranscriptLagSeconds` with `Stage=notify`: `SampleCount 2`, `Maximum 1.91`, `Unit Seconds`.
- The same metric asked with **no** dimensions: `[]`.

A metric's identity is namespace, name and the **complete** dimension set.

![Checkpoints 5-6: window A empty, window B 2.0 4.0; list-metrics by dimension set - CentralErrorCount, EdgeDenyCount Stage, NotifyCount, TranscriptLagSeconds Stage, TranscriptsProcessed with none and three Faculty,Stage sets; lag statistics SampleCount 2.0 Average 1.165 Sum 2.33 Maximum 1.91 Unit Seconds; asking with no dimensions returns []; CentralErrorCount 1.0 1.0](../../screenshots/lab13-03-checkpoints5-6-metrics.png)

### 3.4 Checkpoints 7-8 - IAM and the notifier

**Step 12.** `USMSObservabilityWrite` is the guide's document, verbatim:
- **`WriteApplicationLogs`:** log-group ARNs ending in `:*`.
- **`PublishCustomMetricsInOurNamespaceOnly`:** `PutMetricData` with
  `cloudwatch:namespace = USMS/Application`.
- **`SendTraces`.**

It was created once and attached to both roles; `USMSLambdaBasic` was not edited. Floci
enforces no IAM, so the condition was shown with the simulator against the document:
`USMS/Application` `allowed`, `AWS/Lambda` `implicitDeny`.

**Step 13.** The guide's v2 handler (`transcript-notifier-v2/notifier.py`, verbatim) was deployed,
given its environment, and published as **version 3**. `live` moved to it. The verify invocation
returned `200`, a payload with `trace_id` and `seconds`, and a `USMS_SUMMARY` line. The function
published its own metrics with the `Faculty` and `Stage` dimensions.

**What the test object revealed.** The probe object sits under `transcripts/evidence/`, so the
handler's `faculty_of()` derived a faculty called `evidence`. The value set stays small, which is
a cardinality guard. It is not a correctness guard (notes, question 4).

**Your turn:**
- **`live` -> 1:** an invocation returned `['keys', 'processed']`.
- **`live` -> 3:** it returned `['keys', 'processed', 'seconds', 'trace_id']`.
- **Throughout:** versions `$LATEST`, 1, 2 and 3 were listed.

**Step 14.** `TracingConfig Mode=Active`, published as **version 4**; `live` moved to it.
- **Version 3 stays `PassThrough`.** A version freezes configuration as well as code.
- **Floci passes no `_X_AMZN_TRACE_ID`,** so the handler's `trace_id` is its request-id fallback.

![Checkpoints 7-8: the policy attached to both roles; usms-lambda-exec-role USMSLambdaBasic USMSObservabilityWrite and usms-ec2-app-role USMSStudentDataReadWrite USMSObservabilityWrite; three statements Allow; PutMetricData into USMS/Application allowed, into AWS/Lambda implicitDeny; live -> 4; 4 Active; 3 PassThrough; the USMS_NOTIFY line with faculty evidence and metric_published true; USMS_SUMMARY; Faculty engineering, evidence, science and Stage notify](../../screenshots/lab13-04-checkpoints7-8-iam-notifier.png)

### 3.5 Checkpoints 9-10 - traces

**Steps 15-16.** The three documents were written as the guide shapes them, with one trace id
(`1-6aedc66f-...`), and are committed as templates:
- **The parent segment:** `usms-transcript-notifier`, with annotations `faculty`, `stage`,
  `transcript_bytes` and `readable`.
- **The same segment with three subsegments:** `s3-head-object` (`aws`), `render-pdf` (`remote`)
  and `cloudwatch-put-metric-data` (`aws`).
- **A downstream segment:** `usms-student-data`, whose `parent_id` is the notifier's segment, with
  `http.response.status 200`.

`put-trace-segments` returned `UnknownOperationException`, so nothing could be read back.

**The guide's fallback is structural validation**, and `lab-13-validate-segments.py` performs
ten checks:
- the id formats
- one shared trace id
- the parent link
- times in order, and subsegments inside their parent's window
- annotation types
- the HTTP status

A negative test on scratch copies, with the parent id cut to 8 characters and a list annotation,
fails four checks and exits 1.

**Step 17.** `usms-emit-telemetry.sh` writes the log line (as JSON via `file://`, Section 6.1)
and the metric, and reports the trace as `SKIPPED`. It appends to `outputs/lab-13-trace-ids.txt`.
- **The join works.** The last trace id finds exactly its own `USMS_EVENT` line in the central log.
- **Search and service graph:** `GetTraceSummaries` is unsupported.

**Step 18.** The sampling rule declares all 11 required fields: reservoir 2, rate 0.10,
priority 1000.
- **`CreateSamplingRule`:** unsupported.
- **The CLI's own request model accepts it.** It was sent to an address with nothing listening
  (`127.0.0.1:9`), so it failed only at connection, and nothing was created anywhere.

![Checkpoints 9-10: GetSamplingRules and PutTraceSegments UnknownOperationException; the validator's ten ok checks for trace 1-6aedc66f-7707a95cf51069bab3e64edf, errors []; the negative test's four FAIL lines and exit=1; sampling rule valid JSON, 11/11 fields, CreateSamplingRule unknown, accepted by the CLI request model; 6 trace ids; the USMS_EVENT line for 1-6aedc9d1-1b9a2aef1cbf2c7010925c8c](../../screenshots/lab13-05-checkpoints9-10-xray-documents.png)

### 3.6 Checkpoint 11 - alarms

**Step 19.** Both alarms were created as the guide writes them and tagged `Lab=13`. They started in
`INSUFFICIENT_DATA`, as on AWS.

**A test the guide does not have: real evaluation.** Floci evaluated the alarms, so I gave it
something to evaluate: two slow transcripts (3.5 s and 4.2 s), one minute apart
(`outputs/lab-13-alarm-real-evaluation.txt`).

| Time | State | Reason |
|---|---|---|
| +0 s | `OK` | 0 datapoints breaching |
| +41 s | `ALARM` | 2 datapoints breaching |
| +92 s | `OK` | 1 datapoint breaching, so below 2 of 3 |

**Step 20.**
- **The forced transition.** `set-alarm-state ALARM` with a `Lab 13 Step 20` reason was recorded.
- **Its reversion.** Watching for 90 s showed evaluation put the alarm back to `OK` within about
  11 s.
- **The restore.** It was performed anyway, so the reason trail is complete.

`describe-alarm-history` is unsupported, so the transition record is the state read back at the
time (`outputs/lab-13-alarm-history.json`).

**Step 21.** `PutCompositeAlarm` is unsupported, through both the query and JSON protocols.
- **The document.** `templates/lab-13-composite-alarm.json` is the full request, accepted by the
  CLI's request model.
- **The evaluation.** `lab-13-composite-eval.sh` evaluates its rule against the live child states.
  I drove a child into `ALARM` and the composite went to `ALARM`; I restored it and it went back
  to `OK`. A rule naming a misspelt child is refused.

**The silence alarm fired on its own.** The newest `USMS_NOTIFY` line was at 12:21:46Z. At
12:50:05Z Floci moved `usms-notify-silence` to `ALARM` ("3 datapoints breaching, missing
datapoints treated as breaching"), with no `set-alarm-state` involved. That is the alarm doing
its job, and it is why one verify check was adapted (Section 3.8).

![Checkpoint 11: lag-high TranscriptLagSeconds Maximum 60 2/3 GreaterThanThreshold 2.0 notBreaching and notify-silence NotifyCount Sum 300 3/3 LessThanThreshold 1.0 breaching; real evaluation +0s OK, +41s ALARM, +92s OK; Step 20 forced ALARM, +1s ALARM, +11s OK, restored; usms-notify-silence ALARM at 18:50:05+06:00 with the newest USMS_NOTIFY at 12:21:46Z; composite request model accepted, notify-silence ALARM, lag-high OK, composite ALARM](../../screenshots/lab13-06-checkpoint11-alarms-composite.png)

### 3.7 Checkpoints 12-13 - dashboard, queries, restart

**Step 22.** `usms-overview` was put from `templates/lab-13-dashboard.json`:
- `DashboardValidationMessages` `[]`
- 5 widgets of types `alarm`, `metric` and `text`
- a 24-column grid, with no overlaps

Exercise 2 later replaced the hand-written template with a generated one and added a sixth
widget.

**Step 23.** Path A, Logs Insights, is partial (`outputs/lab-13-insights-probe.txt`):
- Only `fields @timestamp, @message | limit 2` completes.
- Every `filter`, `stats` and `parse` query ends `Failed`, with no rows.

Path B, `lab-13-faculty-counts.sh`, retrieves with `filter-log-events` and aggregates locally:
science 5, engineering 5. This is correct, but every event crosses the network, which is the
case **for** Insights at scale, not against it.

**Step 24.** The guide's inventory function, as `lab-13-restart-facts.sh`, lists configuration
only:
- groups and retention
- filters
- metrics
- alarm **configuration**
- the composite document
- dashboards
- attachments
- the notifier's version and tracing

It leaves out alarm states, because this build evaluates alarms, so a state can change between two
readings for reasons that have nothing to do with persistence. Floci was restarted between the
two readings: the container's `StartedAt` is 12:47:20Z, between the pre (12:47:01Z) and post
(12:47:24Z) inventories.

**Result:** the inventories are identical, and the metric data points counted separately are 3
before and 3 after.

![Checkpoints 12-13: 5 ['alarm', 'metric', 'text']; validation []; usms-overview 2317 bytes; widgets 5, grid width 24, overlapping False; Insights: fields|limit Complete rows=2, five filter/stats queries Failed; science 5, engineering 5; pre/post restart inventories identical; metric data points before=3 after=3](../../screenshots/lab13-07-checkpoints12-13-dashboard-queries-restart.png)

### 3.8 Verification and hygiene

**Step 25.** `write-lab-13-env.sh` writes the guide's 28 exports, by lookup:
- **The two notifier versions** are found by the descriptions they were published with. They are
  3 and 4 here, not the guide's 2 and 3.
- **The stream** is the most recently written one (`emitter-20261106`), with `| head -1` against
  a `NextToken` line.
- **The last trace id** goes through `grep -E '^1-' || echo none`.
- **The capability flags:** X-Ray `no`, Insights `partial`.

If any must-succeed lookup is empty or `None`, it stops without writing.

**Section 8.1, `verify-lab-13.sh`: the guide's 49 checks, `PASS=49 FAIL=0`.** Five adaptations,
each marked `Adapted` in the script:
1. **Role names.** `lab-01.env` holds role **ARNs**; `--role-name` needs the name (`${ROLE##*/}`).
2. **The composite.** The two composite checks fall back to the committed document when the API
   has no composite alarm.
3. **The ALARM check.** "No alarm left in `ALARM`" became "no alarm left in a state Steps 20/21
   **forced**": `ALARM` with a `Lab 13 Step` reason. Real evaluation puts `usms-notify-silence` in
   `ALARM` after any 15 quiet minutes, which is the alarm working, not something left behind.
4. **`outputs/.gitkeep`.** "No secret is tracked" ignores exactly this file, which Lab 01 tracks on
   purpose.
5. **A bug in the guide's `metric_dims`.** `Metrics[].join(...) || \`NONE\`` applies `||` to the
   whole projected **list**, which is truthy whenever any metric exists. So an empty dimension set
   printed as an empty string, never `NONE`, and the "published without dimensions" check could
   not pass on any build. `Metrics[].[join(...) || \`NONE\`]` applies it per element. The first
   run was `48/1` on exactly that check.

Exercise 2 then raised the widget count from 5 to 6; still `49/0`.

**Section 8.2.** `scripts/cleanup/lab-13-cleanup.sh` is the guide's script, plus Exercise 1's
filter. It passed `bash -n` and has not been run. Its warning names the future alerting lab as
the dependant, not the guide's "Lab 09", a numbering leftover.

![verify-lab-13.sh: ten sections, PASS=49 FAIL=0; 28 exports; USMS_LOG_STREAM_CENTRAL emitter-20261106, VERSION_INSTRUMENTED 3, VERSION_TRACED 4, ALIAS_VERSION 4, TRACING_MODE Active, XRAY_SUPPORTED no, LAST_TRACE_ID 1-6aedc9d1-1b9a2aef1cbf2c7010925c8c, INSIGHTS_SUPPORTED partial; git ls-files outputs/ shows only outputs/.gitkeep; .gitignore:8:outputs/* covers outputs/lab-13-verify.txt; verify-lab-12.sh PASS=45 FAIL=0](../../screenshots/lab13-08-verify-env-and-hygiene.png)

**Step 26.** The commit is mine to make: Claude does not commit in this repository.
`git status --short` lists no `outputs/` path and no `.zip` (the deployment archive is
`outputs/lab-13-notifier-v2.zip`).

### 3.9 Regression

Before the screenshots (`outputs/lab-13-regression.txt`) and again with the project inventory:

```text
lab-01 34/0  lab-02 33/0  lab-03 31/5  lab-04 39/0  lab-05 49/1  lab-06 39/3  lab-07 30/0
lab-08 33/1  lab-09 49/1  lab-10 51/0  lab-11 46/0  lab-12 45/0  lab-13 49/0
```

Each earlier result matches the baseline recorded in the Lab 09 and Lab 10 reports. The failures
are explained in `project/checkpoint-01/gaps.md`, Section 1. Lab 10's notifier was changed by
design, and its verify script still passes, so `live` was rolled forward, not left on version 1.

### 3.10 Project Implementation Checkpoint 1 (the appendix)

`project/checkpoint-01/` is committed, because it is a submission:
- **[architecture.md](../../project/checkpoint-01/architecture.md):** the system as one design,
  and the one path through it.
- **[gaps.md](../../project/checkpoint-01/gaps.md):** every FAIL in the inventory explained,
  Floci's missing pieces and their stand-ins, and what is not built yet.
- **[demo.md](../../project/checkpoint-01/demo.md):** the 8-minute walkthrough, with fallbacks.
- **`inventory.txt`:** from `usms-project-inventory.sh`, the guide's script with two fixes:
  - **"tracked secrets".** It printed `0` twice: `grep -c` prints 0, then exits 1 into
    `|| echo 0`.
  - **The verification rows.** They printed `tail -1`, which for Labs 05, 06 and 09 is a
    footnote, so two FAILs were hidden behind prose. Each row now prints the `PASS=` line.
- **`evidence/`:** `verify-lab-10.txt` (`51/0`), `verify-lab-13.txt` (`49/0`),
  `telemetry-inventory.txt`, and `end-to-end.txt`.

**`end-to-end.txt`** comes from `usms-end-to-end-demo.sh`: the guide's nine stages, plus a stage
5b. The guide's stage 5 says "upload a transcript" but runs the emitter, which never touches the
bucket. 5b uploads a real object and waits for the notifier's own `USMS_NOTIFY` line naming that
key, which arrived within seconds.

The guide's self-check passes (four files, four evidence files, not ignored), and the secret scan
finds nothing.

### 3.11 Not done, and files

Section 13.1 is the in-class practical assessment (an edge-deny alarm, a diagnosis, a short
essay, a break-and-catch). It is done in class, at a machine, and is not part of this submission.

| File | Purpose |
|---|---|
| `policies/usms-observability-write-policy.json` | Step 12, verbatim |
| `templates/lab-13-metric-data.json` | Step 11's `--metric-data` document |
| `templates/lab-13-segment-parent.json`, `-subsegments.json`, `-downstream.json` | Steps 15-16, one trace id |
| `templates/lab-13-sampling-rule.json` | Step 18, verbatim |
| `templates/lab-13-composite-alarm.json` | Step 21 as a request document (no composite alarms on Floci) |
| `templates/lab-13-dashboard.json` | Step 22; generated since Exercise 2 |
| `labs/lab-13-cloudwatch-xray/transcript-notifier-v2/notifier.py` | Step 13, verbatim |
| `configs/lab-13.env` | 28 exports |
| `scripts/utilities/lab-13-support-probe.sh`, `lab-13-telemetry-inventory.sh` | Steps 4-5 |
| `scripts/utilities/usms-emit-telemetry.sh` | Step 17; JSON log events; the seconds as a trailing token (Exercise 1) |
| `scripts/utilities/lab-13-validate-segments.py` | Step 16's fallback, 10 checks |
| `scripts/utilities/lab-13-alarm-states.sh`, `lab-13-composite-eval.sh` | Steps 20-21 |
| `scripts/utilities/lab-13-faculty-counts.sh` | Step 23, path B |
| `scripts/utilities/lab-13-restart-facts.sh` | Step 24, configuration only |
| `scripts/utilities/write-lab-13-env.sh`, `verify-lab-13.sh` | Step 25, Section 8.1 |
| `scripts/cleanup/lab-13-cleanup.sh` | Section 8.2, never run |
| `scripts/utilities/lab-13-ex1-seconds-filter.sh` | Exercise 1 |
| `scripts/utilities/write-lab-13-dashboard.sh` | Exercise 2 |
| `scripts/utilities/usms-threshold-report.sh` | Exercise 3 |
| `scripts/utilities/lab-13-alerting-readiness.sh` | Exercise 5 |
| `scripts/utilities/usms-project-inventory.sh`, `usms-end-to-end-demo.sh` | the project appendix |
| `notes/lab-13-notes.md` | notes, "Your turn" answers, review questions |
| `notes/lab-13-observability-plan.md` | Exercise 4 |
| `project/checkpoint-01/` | Project Implementation Checkpoint 1 |

---

## 4. Exercises 1-5

Full commands, output and reasoning are in [exercises.md](exercises.md).

| # | What | Result |
|---|---|---|
| 1 | A filter that extracts a value | `[marker="USMS_EVENT", payload, seconds>=0]`, `metricValue=$seconds`, no `defaultValue`. Neither dialect could read the old line, so the emitter now repeats the seconds as a third token (and the one strict reader was fixed). Three runs: `n=3 min 0.63 max 1.84 sum 3.84`, as passed and as the direct metric reports |
| 2 | A portable dashboard, sixth widget | Generated from `USMS_ACCOUNT_ID` and `AWS_REGION_COURSE`; the first five widgets byte-identical to Step 22; another account and Region followed in every ARN; 6 widgets, `[]`, no overlaps; verify updated to 6, `49/0` |
| 3 | Are the thresholds defensible? | `usms-enrolment-queue-high` has no data in 7 days: it watches a metric nobody publishes. `usms-notify-silence` is in `ALARM` without a datapoint ever crossing its threshold, through 286 empty periods. The 2 s lag threshold was crossed only by deliberately slow test events |
| 4 | Observability plan | [notes/lab-13-observability-plan.md](../../notes/lab-13-observability-plan.md): an audit group fed by CloudTrail data events; three SLIs; the silence alarm as the one that would have caught the outage but not the one that should page; about $12/month of metrics against about $9,000 with a student-id dimension |
| 5 | Ready for alerting, not applied | A draft with three actions from `lab-01.env`'s account; validation reports the composite as a mismatch rather than hiding it; `AlarmActions` `[]`; a baseline of 6 real samples (max 2.7 s); a reproducible, git-ignored readiness file |

## 5. Review questions

Answered in prose in [notes/lab-13-notes.md](../../notes/lab-13-notes.md). In brief:

1. **Logs without metrics.** Metrics answer "is it broken now?" and "has it stopped?" cheaply and
   keep 15 months of history. Logs answer a question nobody anticipated. The colleague is right
   only when a metric filter can derive the number from logs already written.
2. **Filter or direct metric.** Count downloads with a filter: an event, logged anyway, often by
   code that is not ours. Measure render time directly: a value with a unit and dimensions, from
   code we own.
3. **Missing data.** `breaching` on the lag alarm pages on quiet nights. `notBreaching` on the
   silence alarm makes it unable to fire. A deleted bucket notification is the incident only the
   second catches, behind an all-green dashboard.
4. **Dimension or annotation.** Faculty: dimension. Student id: annotation, never a dimension.
   HTTP status: a bucketed dimension, plus the exact code as an annotation. Renderer: annotation.
5. **A version for a configuration change.** A version freezes configuration. Screenshot 04 shows
   version 3 still `PassThrough` beside version 4 `Active`.
6. **Forcing an alarm.** It proves the alarm exists and can transition, and on AWS tests the
   actions. It proves nothing about the threshold. Here evaluation undid it in 11 s, and a real
   breach was the evidence.

---

## 6. Problems encountered

### 6.1 The `--log-events` shorthand cannot carry a structured line

**The symptom.** The guide's `timestamp=...,message=USMS_EVENT {"event":...}` failed with
`ParamValidation: Expected: ',', received: '"'` before any request was sent.

**The cause.** The CLI's shorthand parser reads the JSON's quotes and commas as its own syntax.
Every `USMS_EVENT` line has both, so no structured line can be sent this way.

**The fix.** Events go as a JSON document through `file://` (a `mktemp` file in the emitter). The
health-check line, sent while the shorthand was still failing, kept its earlier timestamp
(Section 3.2).

### 6.2 What this build evaluates, and what it does not

**The probe, and running things, showed more than the guide's Section 11 expects:**
- metric filters fire on ingestion
- alarms evaluate in both directions
- a forced state does not survive the next evaluation

**And less:**
- **X-Ray:** absent.
- **Composite alarms:** `PutCompositeAlarm` is unsupported. Through the query protocol, my first
  attempt was even routed to SQS (no authorisation header). With a `monitoring` credential scope
  it was simply unsupported.
- **Alarm history:** `describe-alarm-history` is unsupported.
- **Logs Insights:** it runs `fields | limit` and nothing else. My first `start-query` attempt
  printed only `}`, which was the clue.

Each gap has a labelled stand-in (Sections 3.5-3.7). Each difference from the guide is in the
evidence, not only described.

### 6.3 Two verify checks the guide could not pass

- **The `metric_dims` bug.** See Section 3.8, item 5. It cost one run at `48/1`.
- **"No alarm stuck in `ALARM`".** Item 3. It would have failed for the right behaviour.

### 6.4 The restart inventory

The guide's `inventory()` includes alarm states. On a build that evaluates alarms, comparing two
readings of a state tests the evaluator, not persistence. `lab-13-restart-facts.sh` lists alarm
configuration, and states are read with `lab-13-alarm-states.sh`.

### 6.5 Found while preparing the screenshots and the checkpoint

- **The support probe's labels.** The first screenshot showed `UNSUPPORTED (Insights start-query)`
  for a probe that calls `describe-queries`, and `SUPPORTED (composite alarms)` for a read-only
  probe on a build that cannot create one. I relabelled them, added a real `start-query` probe and
  a note, and retook the screenshot.
- **An empty evidence file.** `outputs/lab-13-validate-negative.txt` contained only "negative exit".
  The negative test was re-run on scratch copies of the templates, leaving the repository
  untouched, and the four failures recorded.
- **A quoted term with hyphens.** `--filter-pattern '"checkpoint-01-demo"'` matched nothing on
  Floci, while the unquoted form matched. AWS requires the quotes for such a term, so the demo
  filters on `USMS_NOTIFY` and selects the key with JMESPath `contains()`, which works on both.
- **Two small bugs in the guide's inventory script.** See Section 3.10.

---

## 7. Floci limitations versus real AWS

| Feature | Real AWS | Floci 2.2.0, observed | Status |
|---|---|---|---|
| Log groups, streams, events, retention, tags | Full; retention enforced by deletion | Works; retention stored, not enforced | **Implemented** |
| `test-metric-filter` | Full | Works, including space-delimited extraction | **Implemented** |
| Metric filters on ingestion | Every event | Evaluated; `defaultValue` per non-matching event | **Implemented** |
| Quoted filter terms with punctuation | Matched | A hyphenated quoted term matches nothing | **Floci Limitation** |
| Custom metrics | Full; 1,440 datapoints per request | Works; no datapoint limit | **Implemented** |
| AWS-published metrics (`AWS/ECS`, `AWS/Lambda`) | Automatic | None, so target-tracking alarms stay `INSUFFICIENT_DATA` | **Floci Limitation** |
| Alarm evaluation | Per period | **Real**, in both directions; forced states reverted | **Implemented** |
| Alarm actions | SNS, Auto Scaling and others | None configured here (Lab 06 showed Auto Scaling actions invoked) | Not exercised |
| `describe-alarm-history` | Full | Unsupported | **Floci Limitation** |
| Composite alarms | Full | `PutCompositeAlarm` unsupported | **Floci Limitation** |
| Dashboards | Stored, validated, rendered | Stored and validated; not rendered | **Floci Limitation** |
| Logs Insights | Full query language | `fields \| limit` only | **Floci Limitation** |
| X-Ray (segments, summaries, service graph, sampling) | Full | Absent | **Floci Limitation** |
| Lambda `TracingConfig: Active` | A segment per sampled invocation | Stored per version; no trace header reaches the handler | **Floci Limitation** |
| IAM conditions on `PutMetricData` | Enforced | Not enforced; correct in the simulator | **Conceptual / Real AWS** |
| CloudWatch agent, Container and Lambda Insights, metric math, anomaly detection, subscription filters | Available | Absent | **Conceptual / Real AWS** |
| Cost | Per GB, per metric, per alarm, per trace, per GB scanned | Free | **Conceptual / Real AWS** |

**Observed, recorded, not available**, in the guide's three categories:
- **Observed:**
  - log groups and retention
  - millisecond events
  - filters tested, attached and firing
  - metrics with and without dimensions
  - the alias repointed and rolled back
  - real alarm evaluation, a forced transition and its reversion
  - the dashboard document
  - persistence across a restart
- **Recorded only:**
  - the composite rule
  - the segment documents
  - the sampling rule
  - active tracing
  - the IAM condition
- **Not available:**
  - X-Ray
  - Insights aggregation
  - alarm history
  - AWS-published metrics
  - a rendered dashboard
  - the agent, Container and Lambda Insights, metric math, anomaly detection, subscription
    filters, cost

## 8. Reproducing this lab

```bash
cd ~/Desktop/aws-floci-course
./scripts/setup/floci-up.sh
source configs/course.env
source configs/lab-01.env
source configs/lab-13.env
./scripts/utilities/verify-lab-13.sh          # PASS=49  FAIL=0
./scripts/utilities/verify-lab-10.sh          # PASS=51  FAIL=0 - the notifier still works for Lab 10
./scripts/utilities/usms-end-to-end-demo.sh   # the checkpoint's end-to-end path
```

`usms-notify-silence` will be in `ALARM` after any 15 minutes without a notification, which is
correct. Uploading to `transcripts/evidence/` returns it to `OK` within a few periods.
