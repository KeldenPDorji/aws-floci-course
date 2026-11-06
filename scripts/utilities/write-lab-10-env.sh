#!/usr/bin/env bash
# Generate configs/lab-10.env by LOOKUP (Lab 10 Step 23). Names, ARNs and IDs only.
# The guide's heredoc takes three values from shell variables (VIEWER_VERSION_ARN,
# ORIGIN_VERSION_ARN, EDGE_ROLE_ARN) that only exist in the terminal that ran Steps 6-13;
# here every one of the 25 values is read from the API, and the file is refused if
# any value comes back empty or None.
#   ./scripts/utilities/write-lab-10-env.sh            25 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env 2>/dev/null || true
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

fn_arn() { aws lambda get-function-configuration --function-name "$1" --query FunctionArn --output text; }
# versions are strings: to_number keeps 10 after 9; \$LATEST is left for JMESPath
max_ver() { aws lambda list-versions-by-function --function-name "$1" \
              --query "max_by(Versions[?Version!='\$LATEST'], &to_number(Version)).Version" --output text; }
dist() { aws cloudfront list-distributions \
           --query "DistributionList.Items[?contains(Comment, 'usms-transcript-cdn')].$1 | [0]" --output text 2>/dev/null; }

VIEWER_ARN=$(fn_arn usms-edge-viewer-request);  VIEWER_V=$(max_ver usms-edge-viewer-request)
ORIGIN_ARN=$(fn_arn usms-edge-origin-response); ORIGIN_V=$(max_ver usms-edge-origin-response)
# The edge role is whichever role the viewer function actually runs as (Exercise 2 may move it).
EDGE_ROLE_ARN=$(aws lambda get-function-configuration --function-name usms-edge-viewer-request --query Role --output text)
NOTIFIER_ARN=$(fn_arn usms-transcript-notifier)
NOTIFIER_RT=$(aws lambda get-function-configuration --function-name usms-transcript-notifier --query Runtime --output text)
ALIAS_ARN=$(aws lambda get-alias --function-name usms-transcript-notifier --name live --query AliasArn --output text)
ALIAS_V=$(aws lambda get-alias --function-name usms-transcript-notifier --name live --query FunctionVersion --output text)
CF_SUPPORTED=$(aws cloudfront list-distributions >/dev/null 2>&1 && echo yes || echo no)
CF_ID=$(dist Id | grep -E '^[A-Z0-9]+$' || echo not-created)
CF_DOMAIN=$(dist DomainName | grep -E '\.' || echo not-created)
NOW=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

for v in "$VIEWER_ARN" "$VIEWER_V" "$ORIGIN_ARN" "$ORIGIN_V" "$EDGE_ROLE_ARN" "$NOTIFIER_ARN" "$NOTIFIER_RT" "$ALIAS_ARN" "$ALIAS_V"; do
  case "$v" in ""|None) echo "STOP - a lookup came back empty or None; configs/lab-10.env not written" >&2; exit 1 ;; esac
done

cat > configs/lab-10.env << EOF
# Lab 10 - Edge functions with AWS Lambda
# Generated on ${NOW}
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.

# --- origin ---------------------------------------------------------------
export USMS_BUCKET_ARN=arn:aws:s3:::${BUCKET}

# --- edge function 1: viewer-request --------------------------------------
export USMS_EDGE_VIEWER_FN=usms-edge-viewer-request
export USMS_EDGE_VIEWER_FN_ARN=${VIEWER_ARN}
export USMS_EDGE_VIEWER_VERSION=${VIEWER_V}
export USMS_EDGE_VIEWER_VERSION_ARN=${VIEWER_ARN}:${VIEWER_V}

# --- edge function 2: origin-response -------------------------------------
export USMS_EDGE_ORIGIN_FN=usms-edge-origin-response
export USMS_EDGE_ORIGIN_FN_ARN=${ORIGIN_ARN}
export USMS_EDGE_ORIGIN_VERSION=${ORIGIN_V}
export USMS_EDGE_ORIGIN_VERSION_ARN=${ORIGIN_ARN}:${ORIGIN_V}

export USMS_EDGE_RUNTIME=nodejs20.x
export USMS_EDGE_ROLE_ARN=${EDGE_ROLE_ARN}
export USMS_EDGE_TRACE_FILE=outputs/lab-10-edge-trace.json

# --- regional function: transcript notifier -------------------------------
export USMS_LAMBDA_NOTIFIER_FN=usms-transcript-notifier
export USMS_LAMBDA_NOTIFIER_FN_ARN=${NOTIFIER_ARN}
export USMS_LAMBDA_NOTIFIER_RUNTIME=${NOTIFIER_RT}
export USMS_LAMBDA_NOTIFIER_ALIAS=live
export USMS_LAMBDA_NOTIFIER_ALIAS_ARN=${ALIAS_ARN}
export USMS_LAMBDA_NOTIFIER_VERSION=${ALIAS_V}
export USMS_LOG_GROUP_NOTIFIER=/aws/lambda/usms-transcript-notifier

# --- s3 notification ------------------------------------------------------
export USMS_NOTIFICATION_ID=usms-transcript-upload
export USMS_NOTIFICATION_PREFIX=transcripts/
export USMS_NOTIFICATION_SUFFIX=.json

# --- cloudfront (Path A on this build: Floci 2.2.0 stores distributions) --
export USMS_CLOUDFRONT_SUPPORTED=${CF_SUPPORTED}
export USMS_CLOUDFRONT_DIST_ID=${CF_ID}
export USMS_CLOUDFRONT_DOMAIN=${CF_DOMAIN}
EOF

echo "configs/lab-10.env: $(grep -c '^export' configs/lab-10.env) exports"
