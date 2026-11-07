# USMS - gaps at Project Checkpoint 1

What is not built, what does not behave as it would on AWS, and what I would do next. Each item
says where the evidence is.

## 1. Every FAIL in the verification block, explained

[inventory.txt](inventory.txt) runs all thirteen verification scripts. Eleven failures appear,
across five labs. **None is new at this checkpoint.** Each matches the baseline recorded in the
Lab 09 and Lab 10 reports, and each is a Floci limitation or a known consequence of one, not a
configuration error.

| Script | Result | Failing check(s) | Cause |
|---|---|---|---|
| `verify-lab-03.sh` | 31/5 | `usms-web-01 is running`; its user data reached the instance | The instance's container did not come back after the emulator was recreated for Floci 2.2.0 (recorded in Lab 06's report). The instance record is `stopped` |
| | | data volume attached; survives termination | Floci has no `AttachVolume` |
| | | `usms-db-01 has NO public address` | Floci gives every instance the placeholder address `127.0.0.1` |
| `verify-lab-05.sh` | 49/1 | the cutover left exactly one ingress rule | `revoke-security-group-ingress` returns `True` and removes nothing |
| `verify-lab-06.sh` | 39/3 | the morning and evening scheduled actions, and their ordering | `PutScheduledAction` returns `UnsupportedOperation` |
| `verify-lab-08.sh` | 33/1 | node group `maxSize` raised to 6 | `UpdateNodegroupConfig` returns `UnknownOperationException` |
| `verify-lab-09.sh` | 49/1 | `usms-db-01 has NO public address` | the placeholder address again |

**The configuration behind each of them is in the repository and correct.** For example, Lab 06's
scheduled actions are written and validated, and Lab 03's volume attachment is scripted. The
failing checks are the ones that read the effect back. I kept them failing rather than weakening
them: on AWS they would pass, and if they ever failed there, they should.

## 2. Things Floci cannot do, and what stands in

| Missing on Floci 2.2.0 | Consequence for USMS | What stands in |
|---|---|---|
| X-Ray (every operation) | No trace can be sent or read; the second registrar complaint ("upload, function or bucket?") cannot be answered here | Three segment documents and a sampling rule, checked by a structural validator (`lab-13-validate-segments.py`, 10 checks, with a negative test) |
| `PutCompositeAlarm` | `usms-transcript-pipeline-down` does not exist as an alarm | `templates/lab-13-composite-alarm.json`, evaluated against the live child states by `lab-13-composite-eval.sh` |
| Logs Insights beyond `fields \| limit` | No server-side aggregation | `lab-13-faculty-counts.sh` aggregates locally after `filter-log-events` |
| `describe-alarm-history` | No transition history from the service | States read with `lab-13-alarm-states.sh`; transitions captured as text at the time |
| CodePipeline's ECS deploy provider | The pipeline cannot deploy | `usms-ecs-deploy-action.sh`, from the real build artifact (Lab 12) |
| CloudFront running edge functions | The edge chain never runs | `usms-edge-simulate.sh` runs it in CloudFront's order (Lab 10) |
| IAM enforcement on real calls | A wrong policy would not fail a call | The IAM simulator's decisions (Labs 09, 12, 13) |
| AWS-published metrics (`AWS/ECS` and the rest) | The four target-tracking alarms Lab 06 created stay `INSUFFICIENT_DATA` | Custom metrics in `USMS/Application` |

## 3. Things that are not built yet

**1. Nobody is told when an alarm fires.** No alarm has an action. The draft exists
(`outputs/lab-13-alarm-actions-draft.json`, validated): the composite pages, and the two children
open tickets.
- **What its validation found:** the composite cannot be attached to on this build.
- **Next:** the SNS/SQS lab applies it with describe, merge, put.

**2. The silence alarm cannot tell "broken" from "quiet".** `usms-notify-silence` went to `ALARM`
during a quiet spell, which is correct for the alarm and wrong for a pager at 3 a.m.
- **Next:** a delivery-ratio alarm (notifications per upload, with metric math `FILL`), designed
  in `notes/lab-13-observability-plan.md`. The silence alarm then becomes the backstop.

**3. `usms-enrolment-queue-high` (Lab 06) watches a metric nobody publishes.** Lab 13 Exercise 3
found no datapoint in 7 days, so it will show `OK` for ever.
- **Next:** publish `EnrolmentQueueDepth` from the enrolment service, or delete the alarm.
  Keeping it as it is gives a false sense of cover.

**4. No audit trail for transcript downloads.** "Who downloaded this transcript in March?" cannot
be answered.
- **Next:** CloudTrail data events for `GetObject` on `transcripts/`, into a dedicated log group
  with a long retention period and a two-role read policy (the plan, Section 2). The retention
  figure must come from the records office.

**5. The latency threshold is not derived from data.** 2 s was chosen, not measured. The baseline
so far is six synthetic samples (max 2.7 s).
- **Next:** one term of real `TranscriptLagSeconds`, per faculty.

**6. The ECS service has no deployment circuit breaker.** Lab 12's rollback drill: an image that
cannot be pulled was retried 46 times in 90 s, with no events and no automatic rollback.
- **Next:** set `deploymentCircuitBreaker` with rollback on the service, and test it on real AWS,
  because Floci returns no deployment configuration.

## 4. Housekeeping I know about

- **A stray, empty ECR repository, `usms-enrolment6`.** A zsh modifier (`$URI:r6`) created it
  during Lab 12. The image was removed at the time; the repository was not. It holds nothing and
  nothing references it. I will delete it once I have confirmed nothing in Lab 12's evidence
  names it.
- **`usms-web-01` is `stopped`.** See the Lab 03 row above. It is not part of the end-to-end path.
- **The faculty dimension is derived from object keys.** A test upload under
  `transcripts/evidence/` produced a faculty called `evidence`. The value set is small, which is a
  cost guard, but it is not validated.
