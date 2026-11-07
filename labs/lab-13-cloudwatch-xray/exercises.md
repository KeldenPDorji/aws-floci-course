# Lab 13 - Independent Exercises 1-5

All five exercises were done on Floci 2.2.0, after the eight screenshots. Raw output is in
`outputs/lab-13-ex*.txt` and the files each exercise names (all git-ignored).

**What the exercises changed:**
- a third metric filter, `usms-transcript-seconds`, and the emitter line it reads (Exercise 1)
- the dashboard, now generated, with six widgets; `verify-lab-13.sh` counts 6 (Exercise 2)
- four new scripts, listed per exercise

**End state.** `verify-lab-13.sh` reports `PASS=49 FAIL=0` (re-run after every change), and
`verify-lab-10.sh` `PASS=51 FAIL=0`. No alarm has an action.

The guide asks for three "Your turn" notes in this file. They are short here; the full account is
in [notes/lab-13-notes.md](../../notes/lab-13-notes.md).
- **Step 8, the false positive.** Plain `ERROR` also counted
  `{"reason":"no ERROR here"}`. The deployed `"ERROR USMS_EVENT"` does not, but it does match a
  payload that quotes that phrase. `[level="ERROR", marker="USMS_EVENT", payload]` rejects both,
  and is what I would move to.
- **Step 10, `defaultValue`.** The window before any upload returned `[]`; the window with it
  returned `Sum 2.0` from `SampleCount 4.0`. An **empty** list means no events reached the filter.
  A list of zeroes means events arrived and none matched. This build produces zeroes only per
  non-matching event, so a silent period stays empty.
- **Step 13, rollback.** A real rollback is one `update-alias` call, effective within seconds.
  Lab 10's Lambda@Edge rollback is a global replication, taking minutes.

---

## Exercise 1 - Basic: extract a value instead of counting events

**Neither dialect could read the existing line.** The emitter wrote

```text
USMS_EVENT {"event":"transcript.processed","faculty":"science","seconds":0.42,"trace_id":"1-..."}
```

- **The JSON dialect** (`$.seconds`) needs the whole message to be JSON, and the `USMS_EVENT `
  prefix rules it out.
- **The text dialect's space-delimited fields** see exactly two tokens: the marker, and a
  compact JSON object with no spaces in it. There is no token that **is** the number.

**So I changed what the emitter writes**, which the constraint allows. The seconds are repeated
as a third token:

```text
USMS_EVENT {"event":"transcript.processed",...,"seconds":0.63,...} 0.63
```

**What it cost:**
- **The value is written twice.** The JSON copy stays, so nothing that reads the payload lost a
  field.
- **The line's shape is now an interface to the filter.** If someone "tidies" the trailing token
  away, the metric silently stops, with no error anywhere.
- **One reader broke.** `lab-13-faculty-counts.sh` parsed the body with `json.loads`, which
  rejects the trailing token as "Extra data". It now uses `raw_decode`, which stops at the end of
  the object, and still counts every line. An Insights `parse` on real AWS would need the same
  care.
- **The emitter now refuses a non-numeric seconds argument** before sending anything, because a
  bad third token would silently match nothing.

**The filter** (`scripts/utilities/lab-13-ex1-seconds-filter.sh`, output `outputs/lab-13-ex1.txt`):

```text
pattern:   [marker="USMS_EVENT", payload, seconds>=0]
transform: metricName=TranscriptSecondsFromLogs, metricNamespace=USMS/Application,
           metricValue=$seconds, unit=Seconds        (no defaultValue)
```

- **`seconds>=0`** makes the third field a number, so a malformed line is not counted.
- **There is no `defaultValue`**, unlike Step 9's counters. A 0 for every non-matching event is
  right for a count and wrong for a measurement: it would drag `Average` towards zero and make
  `Minimum` meaningless.

**`test-metric-filter` first**, against six message shapes:
- Step 7's three line types, as written
- an Exercise 1 emitter line
- the health-check line
- a line whose third token is `slow`

```text
4	0.63
```

Only the emitter line matched, extracting `0.63`. Neither the `ERROR` line (its first token is
`ERROR`) nor the non-numeric token matched.

**Deployed, then three emitter runs with known values** (`0.63 1.37 1.84`, all under the lag
alarm's 2 s, so no alarm fired):

```text
TranscriptSecondsFromLogs   n=3.0  min=0.63  max=1.84  sum=3.84  avg=1.28  unit=Seconds
expected:                   n=3    min=0.63  max=1.84  sum=3.84
TranscriptLagSeconds        n=3.0  min=0.63  max=1.84  sum=3.84          (same window, direct)
usms-central-errors  "ERROR USMS_EVENT"  CentralErrorCount  1           (untouched)
```

**Two routes to the same number, and the one I would keep.** Both metrics are the same transcript's
processing time. `TranscriptLagSeconds` is published directly by the emitter with
`put-metric-data`. `TranscriptSecondsFromLogs` is derived by CloudWatch from the log line the same
emitter writes. They agree to the hundredth here because one process produced both.

I would keep **`TranscriptLagSeconds`**:
- It carries the `Stage` dimension.
- The alarm and the dashboard already use it.
- It does not depend on the layout of a log line.
- It is one custom metric instead of two.

The filter route is the right one only when the emitting code is **not ours** to change. Then
the log line is the only interface we have, and this exercise shows what designing a line for a
filter costs. I left the filter in place as a cross-check during this lab. In production I would
delete one of the two.

---

## Exercise 2 - Intermediate: make the dashboard portable and add a widget

**The generator.** `scripts/utilities/write-lab-13-dashboard.sh` builds the document in Python
from:
- `USMS_ACCOUNT_ID` (`configs/lab-01.env`)
- `AWS_REGION_COURSE` (`configs/course.env`)
- the namespace and alarm names from `configs/lab-13.env`

It writes `templates/lab-13-dashboard.json`. With `--put`, it also deploys the document and checks
it; with `--stdout`, it prints the document only. Variables already set in the environment take
precedence, so the generator can be shown to follow them.

**The sixth widget.** It covers the full grid below the others (`x 0, y 12, 24 x 6`; the five end
at `y = 12`): `CentralErrorCount` Sum per 5 minutes over `-PT3H`, with an
`annotations.horizontal` line.

**There is no `CentralErrorCount` alarm**, so the line is labelled
`proposed alarm threshold (no alarm yet)` at 1. A threshold line on a graph reads as a promise
that something pages, so it says it is a proposal (the alarm is proposed in Exercise 4).

`outputs/lab-13-ex2.txt`:

```text
-- the generator holds no account id or region literal:
none
-- the first five widgets are unchanged from Step 22's document:
identical
-- every ARN follows the variable (USMS_ACCOUNT_ID=123456789012, AWS_REGION_COURSE=eu-west-2):
   4 "region": "eu-west-2"
   1 arn:aws:cloudwatch:eu-west-2:123456789012:alarm:usms-notify-silence
   1 arn:aws:cloudwatch:eu-west-2:123456789012:alarm:usms-transcript-lag-high
   1 arn:aws:cloudwatch:eu-west-2:123456789012:alarm:usms-transcript-pipeline-down
-- generate, put, check:
wrote templates/lab-13-dashboard.json (6 widgets, account 000000000000, region us-east-1)
put-dashboard usms-overview, DashboardValidationMessages:
[]
deployed widgets : 6
max right edge   : 24 (grid is 24)
overlapping      : False
-- re-run is idempotent:
same bytes on a second run
-- verify-lab-13.sh, widget count updated to 6:
  ✔ dashboard has 6 widgets
  ✔ no two widgets overlap
PASS=49  FAIL=0
```

**"No literal account id" is a property of the generator, not of its output.** The committed
template still contains `000000000000`, because that **is** the account it was generated for. The
proof that the value is derived is the second run: a different account and Region in the
environment, and every ARN and `region` follows. The Step 22 version is kept as
`outputs/lab-13-dashboard-v1-5widgets.json`.

**A hard-coded widget count is useful and annoying.**
- **Useful:** `put-dashboard` is replace-only. A regenerated document that silently lost a widget
  would still return `[]` and still pass "valid JSON" and "no overlaps". Only the count notices.
- **Annoying:** every deliberate addition needs a hand edit to `verify-lab-13.sh` (done, with a
  comment). That is the price of a check that cannot tell "lost" from "removed on purpose".
- **A better check** compares the deployed widget **titles** with the template's. It would fail on
  any drift in either direction and need no edit when both change together.

---

## Exercise 3 - Problem solving: are these thresholds defensible?

**The script.** `scripts/utilities/usms-threshold-report.sh [--hours N]`.

**How it meets the constraints:**
- **Nothing is hard-coded.** Alarms are found with `describe-alarms --alarm-name-prefix usms-`,
  both types, and metric names come from each alarm.
- **Output.** The JSON is built in Python. Only the report goes to stdout; diagnostics go to
  stderr.
- **Runs from any directory:** it finds the repository with `${BASH_SOURCE[0]}`. Run from
  `/tmp`, it gave exit 0 and valid JSON.
- **An alarm with no dimensions** (`usms-notify-silence`) passes no `--dimensions` at all, rather
  than an empty one.
- **A metric with no data** gives `observed: null`, not a crash.
- **A composite alarm** has every metric field `null`. Floci 2.2.0 cannot create one, so a
  composite that exists only as a committed document (`templates/*composite-alarm*.json`) is
  reported with `"deployed": false` rather than left out. That is honest, and the code path is
  exercised.
- **The 1,440-datapoint limit.** `get-metric-statistics` returns at most 1,440 datapoints per call.
  A 7-day window at 60 s is 10,080, which Floci answered and AWS would refuse, so long windows
  are asked for in chunks.

**Three fields beyond the exercise's list,** because the list alone misleads on two alarms:
- **`alarm_view`:** the metric as the alarm sees it, with the alarm's statistic at the alarm's
  period. `observed` summarises raw samples.
- **`threshold_ever_breached`:** computed from `alarm_view`, not from raw samples.
- **`empty_periods`:** alarm periods in the window with no datapoint at all.

The result (`outputs/lab-13-threshold-report.json`, 24 h), condensed:

```text
alarm                          state  ever_breached  empty_periods  observed
usms-enrolment-queue-high      OK     false          1440 of 1440   null
usms-notify-silence            ALARM  false          286 of 288     min 0.0 avg 0.4 max 1.0 (15 samples)
usms-transcript-lag-high       OK     true           1434 of 1440   min 0.02 avg 1.55 max 4.2 (13)
usms-transcript-pipeline-down  -      null           null           null  (composite, deployed: false)
```

**The findings:**

1. **`usms-enrolment-queue-high` (Lab 06) has never been near its threshold, because it has no
   data.** Its metric exists in `list-metrics`, but has no datapoint in 24 hours or in 7 days.
   An alarm on a metric nobody publishes shows `OK` for ever, which is worse than having no
   alarm. This is the finding the exercise exists to produce. The guide's sources call it "the
   alarm nobody was told was an alarm", and it is also an alarm nobody feeds.
2. **`usms-notify-silence` is in `ALARM` without ever crossing its threshold.**
   - **Why no datapoint crossed it:** its alarm view never fell below 1. The two five-minute
     periods with data had Sums of 2 and 4.
   - **Why it is in ALARM anyway:** of 288 periods, 286 had **no data**, and it treats missing
     data as breaching. That is its purpose.
   - **What a threshold-only report would show:** a breaching alarm whose threshold "has never
     been breached".
   - **The `observed` minimum of 0.0** is `defaultValue` at work: one zero per non-matching
     notifier line.
3. **`usms-transcript-lag-high`'s 2 s was crossed only by deliberately slow test events:**
   - Step 17's emitter runs, at 2.4 s and 3.1 s
   - the real-evaluation test after Step 19, at 3.5 s and 4.2 s
   - Exercise 5's 2.7 s

   It is defensible as a starting point. It was not derived from anything, which Exercise 5's
   baseline begins to address.

---

## Exercise 4 - Challenge: design the USMS observability plan

[notes/lab-13-observability-plan.md](../../notes/lab-13-observability-plan.md). The parts I would
want a reviewer to read first:

- **The audit group.** `/usms/audit/transcript-access` is fed by CloudTrail data events, because
  CloudTrail records the requesting principal, which our own code cannot be trusted to report.
  It keeps a 400-day floor, and the real figure belongs to the records office. It is readable by
  two roles only.
- **The alarm that caught the outage.** `usms-notify-silence` is the only alarm that would have
  caught the six-hour outage, and it should **not** be the one that pages, because it cannot tell
  "broken" from "quiet". The plan adds a delivery-ratio alarm built with metric math (`FILL`),
  which can.
- **The Lab 06 alarm.** `usms-enrolment-queue-high` is marked "remove, or wire up", from
  Exercise 3's finding.
- **The bill.** About $12/month of custom metrics at the proposed cardinality, against about
  $9,000/month if a student id becomes a dimension.
- **What not to build yet:** anomaly detection, until a full academic year of data exists.

---

## Exercise 5 - Integration: leave an alarm the next alerting lab can attach to

**The script.** `scripts/utilities/lab-13-alerting-readiness.sh draft|validate|emit|baseline|readiness|all`
(output `outputs/lab-13-ex5.txt`).

**1. The draft** (`outputs/lab-13-alarm-actions-draft.json`) has three actions:

| Alarm | Urgency | Topic |
|---|---|---|
| `usms-transcript-pipeline-down` | page | `usms-oncall-page`, as alarm action and OK action |
| `usms-transcript-lag-high` | ticket | `usms-platform-tickets` |
| `usms-notify-silence` | ticket | `usms-platform-tickets` |

- **The ARNs** are built from `configs/lab-01.env`'s `USMS_ACCOUNT_ID` and `configs/course.env`'s
  Region. The generator contains no account id.
- **The urgencies follow the dashboard's own rule,** "Alarms page the composite alarm only". The
  silence alarm's note explains why it is a ticket: it fires on quiet nights.

**2. Validation.** It makes one `describe-alarms` call for all three names, covering both alarm
types. The ARN regex requires six fields, the account from `lab-01.env`, and a well-formed Region.

```text
  MISMATCH  alarm does not exist  usms-transcript-pipeline-down
  ok        alarm exists          usms-transcript-lag-high
  ok        alarm exists          usms-notify-silence
validation: 1 mismatch(es)
```

**The mismatch is reported, not fixed.** The composite does not exist on Floci 2.2.0, so the
future alerting lab cannot attach to it here. That is exactly what the next lab needs to know.

A negative copy (in the scratchpad, not in the repository) had:
- a five-field ARN
- an ARN with another account
- a misspelt alarm name

The validator caught all three, plus the composite: `validation: 4 mismatch(es)`, exit 1.

**3. Not applied:**

```text
aws cloudwatch describe-alarms --alarm-names usms-transcript-lag-high --query 'MetricAlarms[0].AlarmActions'
[]
```

The readiness file repeats the check for both metric alarms (`0` actions each).

**4. The latency session.** Six emitter runs, across three faculties (science, engineering,
business), with latencies `0.38 1.12 0.91 2.70 1.55 0.67`. Only one value is above 2 s, alone in
its minute, so the session contains a breach without driving the 2-of-3 alarm into `ALARM`.

`outputs/lab-13-latency-baseline.json` holds the per-minute datapoints read back from CloudWatch,
not the values I typed:

```text
summary: samples 6, min 0.38, max 2.7, avg 1.2217
```

Its `caveat` field says what it is: six synthetic runs, a baseline for the shape of the
argument and not a production distribution.

**5. The readiness file** (`outputs/lab-13-alerting-readiness.txt`, 39 lines) is generated, not
typed, from the API, `configs/lab-13.env`, the composite template, the validator and the
baseline. It records:
- the alarms with their missing-data policies and current states (the composite "not deployed")
- the composite rule
- the namespace and its metrics: the five the lab defines, plus Exercise 1's
  `TranscriptSecondsFromLogs`, listed honestly
- `alias live -> version 4, tracing Active`
- X-Ray `no`, Insights `partial`
- the validation result above
- AlarmActions `0` and `0`
- the observed maximum, `2.7 s`

A second run differed only in its timestamp line. All three outputs are git-ignored:

```text
.gitignore:8:outputs/*	outputs/lab-13-alerting-readiness.txt
.gitignore:8:outputs/*	outputs/lab-13-alarm-actions-draft.json
.gitignore:8:outputs/*	outputs/lab-13-latency-baseline.json
```

`verify-lab-13.sh` still reports `PASS=49 FAIL=0`.
