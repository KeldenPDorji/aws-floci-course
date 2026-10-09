#!/usr/bin/env bash
# Lab 06 Exercise 5 points 3, 5 and 6.
#   3. measure how long capacity takes to appear when the FLOOR moves (python3 timestamps)
#   5. write outputs/lab-06-lab10-readiness.txt, bucket ARN READ from the IAM policy document
#   6. capture head-bucket's failure WITH its exit code
# Restores MinCapacity to 2 before it exits. Contains, reads and references no access key.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env
source configs/lab-04.env

now()   { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }
epoch() { python3 -c 'import time; print(int(time.time()))'; }
svc()   { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" --services "$USMS_ENROLMENT_SERVICE" \
            --query "services[0].$1" --output text; }
SVC_ARN=$(svc serviceArn); RID="${SVC_ARN##*:}"; DIM=ecs:service:DesiredCount
reg()   { aws application-autoscaling register-scalable-target --service-namespace ecs \
            --resource-id "$RID" --scalable-dimension "$DIM" --min-capacity "$1" --max-capacity 10 >/dev/null; }

# ---- point 3: raise the floor to 4 and time until runningCount == desiredCount >= 4 -------------
LAT=outputs/lab-06-scale-latency.txt
BEFORE_D=$(svc desiredCount)
T0=$(epoch); START=$(now)
reg 4
METHOD="MinCapacity 2->4 by re-registering the scalable target"
VERDICT="timeout"
while [ $(( $(epoch) - T0 )) -lt 90 ]; do
  D=$(svc desiredCount); R=$(svc runningCount)
  if [ "$D" -ge 4 ] && [ "$R" = "$D" ]; then VERDICT="running caught up"; break; fi
  python3 -c 'import time; time.sleep(2)'
done
END=$(now); ELAPSED=$(( $(epoch) - T0 ))
if [ "$(svc desiredCount)" -lt 4 ]; then
  # Floci 2.2.0 stores the new floor but does not raise desiredCount to meet it (Step 6 Your
  # turn). Record that, then measure the part this build CAN show: desired -> running, by hand.
  VERDICT="floor stored, desiredCount NOT raised by the registration (Floci limitation)"
  reg 2
  T0=$(epoch); START2=$(now)
  aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --desired-count 4 >/dev/null
  while [ $(( $(epoch) - T0 )) -lt 120 ]; do
    [ "$(svc runningCount)" = 4 ] && break
    python3 -c 'import time; time.sleep(2)'
  done
  END2=$(now); ELAPSED2=$(( $(epoch) - T0 ))
  aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" --desired-count 2 >/dev/null
fi
reg 2
{
  echo "method            $METHOD"
  echo "start             $START"
  echo "end               $END"
  echo "capacity          desired $BEFORE_D -> $(svc desiredCount) after the registration"
  echo "verdict           $VERDICT"
  if [ -n "${ELAPSED2:-}" ]; then
    echo "substitute        update-service --desired-count 4, timed until runningCount=4"
    echo "substitute_start  $START2"
    echo "substitute_end    $END2"
    echo "elapsed_seconds   $ELAPSED2"
  else
    echo "elapsed_seconds   $ELAPSED"
  fi
  echo "bounds_restored   $(aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "$RID" --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text | tr '\t' ' ')"
} > "$LAT"
cat "$LAT"; echo

# ---- point 5: readiness file, the bucket ARN READ from the policy document ----------------------
POLICY_ARN=$(aws iam list-attached-role-policies --role-name "$USMS_ECS_TASK_ROLE" \
  --query "AttachedPolicies[?PolicyName=='USMSStudentDataReadWrite'].PolicyArn | [0]" --output text)
VER=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
DOC=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VER" --query 'PolicyVersion.Document' --output json)
# The document has two Resources per bucket: the bucket itself and "<bucket>/*" for its objects.
# Record the bucket ARN (the one head-bucket and create-bucket act on), not the object wildcard.
BUCKET_ARN=$(echo "$DOC" | python3 -c '
import json,sys
d=json.load(sys.stdin); d=json.loads(d) if isinstance(d,str) else d
rs=[]
for s in d["Statement"]:
    r=s.get("Resource",[]); rs+= r if isinstance(r,list) else [r]
print(sorted({x for x in rs if x.startswith("arn:aws:s3:::") and "/" not in x})[0])')
GRANTS=$(echo "$DOC" | python3 -c '
import json,sys
d=json.load(sys.stdin); d=json.loads(d) if isinstance(d,str) else d
a=[]
for s in d["Statement"]:
    if s.get("Effect")=="Allow":
        x=s.get("Action",[]); a+= x if isinstance(x,list) else [x]
print(", ".join(sorted(set(a))))')
HIST=outputs/lab-06-scaling-history.json
OUT=outputs/lab-06-lab10-readiness.txt
{
  echo "history_file      $HIST  $(wc -c < "$HIST" 2>/dev/null | tr -d ' ') bytes"
  echo "scale_latency     $(awk '$1=="elapsed_seconds"{print $2}' "$LAT") s  (see $LAT for method)"
  echo "task_role_arn     $USMS_ECS_TASK_ROLE_ARN"
  echo "policy            $POLICY_ARN  version $VER"
  echo "bucket_arn        $BUCKET_ARN   (read from the policy document; objects are $BUCKET_ARN/*)"
  echo "grants            USMSStudentDataReadWrite allows: $GRANTS"
  echo "--- head-bucket, before Lab 10 creates the bucket ---"
  HB=$(aws s3api head-bucket --bucket "${BUCKET_ARN##*:::}" 2>&1) || true
  RC=$(aws s3api head-bucket --bucket "${BUCKET_ARN##*:::}" >/dev/null 2>&1; echo $?)
  echo "output            ${HB:-<none>}"
  echo "exit_code         $RC"
  echo "after_lab10       head-bucket returns 0 with no output, and at that instant usms-ecs-task-role's unchanged policy starts granting real access - no IAM change at all."
} > "$OUT"
cat "$OUT"
