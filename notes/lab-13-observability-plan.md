# USMS observability plan - transcript delivery

*Lab 13, Exercise 4. A design for a colleague to implement. No commands.*

**Where the numbers come from.** Each number below is marked with its source:
- **lab:** this repository, measured on Floci.
- **assumption:** my estimate, to be replaced by a measurement named in Section 7.
- **list price:** AWS us-east-1 prices as I remember them, to be checked on the CloudWatch and
  X-Ray pricing pages before this estimate is used for anything.

## 1. The four complaints, and the layer each one belongs to

| Complaint | Right layer | Why not the other two |
|---|---|---|
| Six hours unnoticed; the dashboard was green because the graphs were empty | **Metrics**, with an alarm that treats missing data as breaching | **Logs:** there is no log line for a notification that never happened, so nothing to search for. **Traces:** they are sampled, and an absent trace is indistinguishable from an unsampled one |
| Could not tell whether it was the upload, the function or the bucket | **Traces** | **Metrics:** they aggregate away the individual request, so they show *that* latency rose, not *where*. **Logs:** they sit in three groups with no common key. A shared trace id fixes that, and this lab's emitter wrote one into its log line for that reason, but that is borrowing the trace's identity |
| Who downloaded a particular transcript in March | **Logs**, in an audit group kept for long enough | **Metrics:** they have no identity in them, and must not (a student id as a dimension is 30,000 time series). **Traces:** they are sampled, so most downloads have none, and X-Ray keeps traces for 30 days |
| The monitoring bill exceeds the system's | **All three**, as a design question. The usual causes are log volume times retention, and metric cardinality | Not traces, mostly: sampling caps their cost by construction (Section 5) |

The second complaint has one right answer and this lab built it: the segment documents in
`templates/lab-13-segment-*.json` name the notifier, its three subsegments (`aws`, `remote`,
`aws`) and the bucket as a downstream segment, all under one trace id.

## 2. Log groups and retention

| Group | Contents | Retention | Who may read |
|---|---|---|---|
| `/usms/audit/transcript-access` | CloudTrail **data events** for `GetObject` on `usms-student-data/transcripts/*`, delivered to CloudWatch Logs: who, which object, when, from where | **400 days** minimum; the real figure comes from the university's records-retention schedule | The audit office and security only. Encrypted with a KMS key whose policy names those two roles. Application roles may not read it, delete it or change its retention |
| `/usms/central/application` | Structured `USMS_EVENT` lines from every USMS component | 30 days (lab) | Developers, operations |
| `/usms/ecs/enrolment`, `/ecs/usms-enrolment` | The enrolment service | 30 days (lab) | Developers, operations |
| `/aws/lambda/usms-transcript-notifier` | Function output, including `USMS_NOTIFY` (a metric filter depends on it) | 14 days (lab) | Developers |
| `/aws/codebuild/usms-*` | Build logs | 14 days (lab) | Developers |
| `/aws/lambda/us-east-1.usms-edge-*` (per Region) | Lambda@Edge output, written in the Region nearest each viewer | **7 days** | Developers |

**Why the audit group is the longest.** "Last March" asked in February is eleven months back. 400
days answers "this time last year" from any day of the year. That is the floor this question
needs, not a legal answer: the records office owns the real number, and I would ask them before
building. The group exists for one question, so its access policy is built around one reader.
CloudTrail is the source rather than our own log lines because it records the **principal** that
made the request, which our code cannot be trusted to report about itself.

**Why the edge logs are the shortest.** They are spread across Regions, noisy (one line per viewer
request), and every fact in them that matters later becomes a metric (`EdgeDenyCount`) or a central
line. Seven days covers "what happened at the weekend". Anything older is investigated from
metrics.

**Nothing is left on never-expire.** A group without retention is the one line on the bill that
grows every month for ever.

## 3. Service level indicators

Each one is something a student would notice. CPU utilisation is not one.

| SLI | Definition | Target | Alarm? |
|---|---|---|---|
| **Delivery** | Fraction of uploaded transcripts that produced a `USMS_NOTIFY`: `NotifyCount` divided by S3 `PutObject` requests under `transcripts/` | 99.9% over 28 days (assumption) | **Yes, page**, when below 99% for 15 minutes with uploads present |
| **Notification latency** | Upload-to-notification time, `TranscriptLagSeconds` | 95% under 5 s over 28 days (assumption; the lab's alarm uses 2 s) | **Yes, ticket**, through `usms-transcript-lag-high` |
| **Request-to-available time** | From `transcript.requested` to `transcript.processed`, which is hours or days because people are in the loop | 90% within 2 working days (assumption; the registrar's published promise, which I would look up) | **No.** Graphed weekly |

**Why the third SLI is not alarmed, and is not wasted.** Nobody can act on it at 3 a.m. It moves
over days, and the fix is staffing or process, not a restart. It is the number the registrar
reports to students, and it decides whether the first two targets are worth paying for. If
request-to-available is two days, a five-second notification target is not what students feel.
It belongs in the term review, not on a pager.

**Where the lab's numbers stand.** Exercise 5's baseline is six synthetic samples (min 0.38 s, max
2.7 s, average 1.22 s). That is enough to show the argument's shape and nothing more: the 2 s
threshold was never derived from data, and Exercise 3's report shows it was crossed only by
deliberately slow test events.

## 4. Alarms

| Alarm | Missing data | Urgency | Notes |
|---|---|---|---|
| `usms-transcript-pipeline-down` (composite) | (none: composite) | **Page** | `ALARM(lag-high) OR ALARM(delivery-ratio) OR ALARM(notify-silence)`. The only alarm that pages |
| `usms-delivery-ratio-low` (new) | `notBreaching` | via composite | Metric math with `FILL(NotifyCount, 0)` over uploads, so a period with uploads and no notifications computes as 0, not as missing. With no uploads the ratio is undefined, and that is correctly not a breach |
| `usms-notify-silence` | **`breaching`** | ticket, then via composite in business hours | Fires on any 15 minutes without a notification |
| `usms-transcript-lag-high` | `notBreaching` | ticket | No transcripts means no latency to judge |
| `usms-central-errors` (new) | `notBreaching` | ticket | `CentralErrorCount` Sum >= 3 in 15 minutes (assumption) |
| `usms-enrolment-queue-high` (Lab 06) | `notBreaching` | **remove, or wire up** | Exercise 3 found no data for at least 7 days: its metric is never published. An alarm on a metric nobody publishes shows green for ever and is worse than none |

**The alarm that would have caught the six-hour outage is `usms-notify-silence`.** When notifications
stop, no value arrives. A threshold alarm on a value, such as latency or error count, compares
data with a number, and with no data and `notBreaching` it stays `OK`, exactly as the green
dashboard did. Only an alarm that treats **missing data as breaching** can see an absence. On
Floci it did: it went to `ALARM` by itself, 28 minutes after the last notification, with nothing
forced.

**Why it is not the paging alarm on its own.** It cannot tell "broken" from "quiet". At 3 a.m. in
August there are no uploads, and it fires. `usms-delivery-ratio-low` asks the sharper question,
uploads arrived and notifications did not, and so it can page at night. The silence alarm stays
as a backstop for the case the ratio cannot see: the upload count itself disappearing.

## 5. Where the monitoring bill goes

The estimate is to an order of magnitude. Prices are list prices as I remember them; volumes are
assumptions.

| Line | Driver | Estimate |
|---|---|---|
| Custom metrics | about $0.30 per metric per month (list price). The proposed dimensions are `Faculty` (about 10; assumption, checked against the registrar's list) x `Stage` (3: `notify`, `render`, `origin`), plus a few undimensioned series | about 40 metrics, about **$12/month** |
| The same, with a student-id dimension | 30,000 series | about **$9,000/month**. This is the usual way a monitoring bill overtakes the system |
| Log ingestion | about $0.50/GB ingested (list price). Enrolment-week traffic assumed at about 6 million requests x 200 B = 1.2 GB | single-digit **dollars/month**, if nothing logs at DEBUG |
| Log storage | about $0.03/GB-month; bounded by Section 2's retention | cents. Unbounded without retention |
| Logs Insights | about $0.005/GB scanned | trivial per query; a scheduled query over 400 days of audit logs is not |
| Alarms, dashboards | about $0.10 per alarm per month; 3 dashboards free | under **$2/month** |
| X-Ray | about $5 per million traces recorded; the sampling rule records 2 per second plus 10% | **dollars/month** at USMS volume |

**The two changes with the largest effect:**
1. **No high-cardinality dimensions.** The cardinality of every proposed dimension is stated above,
   and none exceeds about 10. Per-student and per-request values go in log fields and trace
   annotations (Section 1).
2. **Retention on every group, and no DEBUG in production.** Log volume times retention is the
   other line that can grow without anyone deciding it should.

## 6. What I would not build yet

**Anomaly-detection alarms.** USMS traffic is seasonal (enrolment weeks, results day, graduation),
so static thresholds will eventually be wrong. But a model trained on one quiet term would treat
enrolment week as an anomaly and page everybody. I would keep static thresholds plus the absence
alarm until we have **one full academic year** of data.

**What would change my mind:** more than two false pages a month from a static threshold during
known peaks, after the threshold has been tuned once with `--datapoints-to-alarm`.

## 7. What I would measure before committing

- **The real latency distribution over one term**, per faculty, to replace the 2 s threshold and
  the 5 s target. They are currently a guess and six synthetic samples.
- **Log volume per group per day**, to replace Section 5's ingestion assumption. If the enrolment
  service logs every request body, the estimate is wrong by orders of magnitude.
- **The distinct values of `Faculty`** actually produced by the notifier. This lab produced an
  `evidence` faculty from a test path, which shows the value is derived from data, not declared.
- **Whether CloudTrail data events for one prefix in one bucket** give the audit office what it
  needs (principal, object, time, source IP). I would check one month in a test account before
  promising them anything.
