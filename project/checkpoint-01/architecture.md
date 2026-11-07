# USMS - architecture at Project Checkpoint 1

The University Student Management System (USMS) as built in Labs 01-13, on the Floci 2.2.0 AWS
emulator (account `000000000000`, `us-east-1`). This document describes it as one system:
- what each part is for
- what it depends on
- the one path that runs through all of it

[inventory.txt](inventory.txt) is the generated list of what exists. [gaps.md](gaps.md) says what
is missing or does not behave as it would on AWS.

## 1. The system in one picture

```text
                       ┌──────────────── IDENTITY (Lab 01, reviewed Lab 09) ───────────────┐
                       │ 16 usms-* roles, 20 USMS* customer-managed policies,              │
                       │ a permissions boundary on usms-deploy-role, scoped iam:PassRole   │
                       └──────────────┬──────────────────────┬─────────────────────────────┘
                                      │ assumed by           │ assumed by
   NETWORK (Lab 02)                   v                      v
   usms-vpc 10.0.0.0/16      ┌── COMPUTE ───────────────────────────────┐
   5 tagged subnets          │ EC2 usms-web-01 / usms-db-01 (Lab 03)    │
   security groups, NACL,    │ ECS usms-enrolment-svc behind            │
   S3 gateway endpoint ─────>│   usms-enrolment-alb, autoscaled (04-06) │
                             │ EKS usms-eks-cluster: enrolment, results,│
                             │   gateway, HPAs (07-08)                  │
                             └───────────────▲──────────────────────────┘
                                             │ deploys image r7 (stand-in action)
   DELIVERY (Labs 11-12)                     │
   S3 source ──> CodePipeline ──> CodeBuild ──> ECR usms-enrolment (r6, r7)

   STORAGE AND FUNCTIONS (Lab 10)
   usms-student-data ── ObjectCreated: transcripts/evidence/* ──> usms-transcript-notifier:live (v4)
          │                                                                │
          └── CloudFront usms-transcript-cdn + 2 Lambda@Edge functions      │ logs, metrics
                                                                           v
   OBSERVABILITY (Lab 13)
   logs: /usms/central/application (30 d) and every USMS group on 14 or 30 days
   metrics: USMS/Application - NotifyCount, CentralErrorCount (from logs),
            TranscriptsProcessed, TranscriptLagSeconds, EdgeDenyCount (published)
   alarms: usms-transcript-lag-high, usms-notify-silence -> usms-transcript-pipeline-down (rule)
   dashboard: usms-overview (6 widgets)
   traces: segment documents and a sampling rule (no X-Ray service on this build)
```

## 2. The parts, and why each one exists

**Identity (Lab 01, reviewed in Lab 09).** Every workload runs as its own role, and every role's
permissions come from customer-managed `USMS*` policies, not inline ones. That is what lets a
later lab add a capability by attaching one more policy, without editing a shared one:
- Lab 13 gave the notifier and the web tier `USMSObservabilityWrite`.
- That policy's `PutMetricData` is conditioned on `cloudwatch:namespace = USMS/Application`.

Lab 09 reviewed the whole set:
- a permissions boundary on `usms-deploy-role`
- `iam:PassRole` scoped to named roles and services
- the IAM simulator's own decisions as evidence

Floci does not enforce IAM on real calls, so the simulator is the evidence.

**Network (Lab 02).** One VPC with public and private subnets, security groups that reference
each other by tier, and an S3 gateway endpoint, so private workloads reach the student-data
bucket without the internet. Lab 09 re-applied two tiers' group-referenced rules that an older
Floci had dropped.

**Compute (Labs 03-08).** Three generations of the same idea, kept side by side because each
taught a different operating model:
- **EC2 (Lab 03):** `usms-web-01` and `usms-db-01`.
- **ECS (Labs 04-06):** the enrolment API as an ECS service behind an Application Load Balancer,
  with target-tracking and step scaling. It now runs the course's own image, `r7`,
  rather than a placeholder (Lab 12).
- **EKS (Labs 07-08):** a real k3s cluster running enrolment, results and a gateway, with HPAs
  that scaled under load.

**Storage and functions (Lab 10).** `usms-student-data` holds transcripts. Its `ObjectCreated`
notification for `transcripts/evidence/` invokes `usms-transcript-notifier` through the alias
`live`, never a version number, so a release or a rollback is one alias update. Lab 10 also
built:
- the transcript CDN
- two Lambda@Edge functions for request checks and response headers

**Delivery (Labs 11-12).** A pipeline from an S3 source through CodeBuild to ECR:
- The buildspec writes `imagedefinitions.json`.
- Images are tagged with releases and read back by digest.
- The ECS deploy action is the one step Floci cannot run. A labelled stand-in performs it from
  the real build artifact.

**Observability (Lab 13).** The layer that makes the rest operable:
- **Logs.** Every USMS log group has a deliberate retention period. One central group carries
  structured `USMS_EVENT` lines from every component.
- **Metrics from logs.** Two metric filters turn log lines into metrics. A third, from
  Exercise 1, extracts a value from them.
- **Metrics published directly.** The notifier and the telemetry emitter publish custom metrics
  in one namespace, with low-cardinality dimensions (`Faculty`, `Stage`).
- **Alarms.** One watches latency and treats missing data as fine. The other watches for silence
  and treats missing data as the failure.
- **The composite.** A rule joins the two alarms into one incident.
- **The dashboard.** A generated document, kept in version control.

## 3. One path through the whole system

[evidence/end-to-end.txt](evidence/end-to-end.txt) is this path, captured by
`scripts/utilities/usms-end-to-end-demo.sh`. Each stage is a different practical:

| Stage | What happens | Built in |
|---|---|---|
| 1 | The caller is account `000000000000`; the notifier's role holds `USMSLambdaBasic` and `USMSObservabilityWrite` | Labs 01, 13 |
| 2-3 | `usms-student-data` exists; its notification targets `usms-transcript-notifier:live` | Lab 10 |
| 4 | `live` is version 4, `python3.12`, tracing `Active` | Labs 10, 13 |
| 5 | A transcript event is emitted as a log line, a metric and a trace id that joins them | Lab 13 |
| 5b | **A real object is uploaded**; the bucket invokes the notifier, which logs a `USMS_NOTIFY` line naming that key | Labs 10, 13 |
| 6-7 | The central log holds the event; `USMS/Application` holds the metrics | Lab 13 |
| 8 | The alarms, their missing-data policies, and the composite rule evaluated against them | Lab 13 |
| 9 | The dashboard has its six widgets | Lab 13 |

**Stage 5b is not in the guide's demonstration, and I added it on purpose.** The guide's stage 5
runs the telemetry emitter, which never touches the bucket, so it describes the path without
exercising it. 5b uploads an object and waits for the function's own log line, so the link from
bucket to function to log to metric is shown working, not asserted.

## 4. Design decisions that cut across labs

- **Names, not IDs.** Every script looks resources up by name and writes IDs into
  `configs/lab-NN.env` at the end of a lab, never by hand. The environment files are generated,
  committed, and contain no secrets.
- **Replace-only APIs are read before they are written.** Bucket notifications, alarm
  definitions, dashboards, task definitions and pipeline documents are all replace-only. Each
  later change used describe, merge, put. Exercise 5 in Lab 13 deliberately did **not** apply
  alarm actions for this reason.
- **Every lab has a verification script and a cleanup script.** The verification scripts are the
  system's regression suite: [inventory.txt](inventory.txt)'s last block runs all thirteen.
  None of the cleanup scripts has been run.
- **Floci's behaviour is measured, not assumed.** Each lab starts with a support probe, and each
  difference from AWS is labelled where it occurs. Where Floci cannot run a step, a stand-in
  says so in its name and output. Examples: the ECS deploy action, the edge-function chain, the
  composite alarm's evaluation.
- **Evidence stays out of Git.** Command output lives in `outputs/`, which is ignored. Only this
  checkpoint's evidence, which is a submission, is committed (`tracked secrets : 0`).

## 5. What the system can and cannot do today

**It can:**
- take a transcript upload and notify through a versioned, rollback-ready function
- count and time that work in CloudWatch
- alarm on slowness and on silence
- deploy a new enrolment image to ECS by digest
- scale enrolment on ECS and EKS
- prove its IAM design with the simulator

**It cannot yet:**
- tell anyone when an alarm fires: there are no actions, and the next lab adds them
- answer an audit question about who downloaded a transcript: there is no audit trail
- trace a request across services: X-Ray is absent on this build, and the trace design exists
  as documents

[gaps.md](gaps.md) lists these with what I would do next.
