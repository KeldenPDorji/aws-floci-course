#!/usr/bin/env bash
# Lab 10 - write the three request bodies that embed live values, BY LOOKUP.
# The guide writes these with unquoted heredocs from shell variables (VIEWER_VERSION_ARN,
# ORIGIN_VERSION_ARN, NOTIFIER_ALIAS_ARN), which are empty in any new terminal; this looks
# every value up from the API and refuses to write a body with a hole in it.
#   ./scripts/utilities/write-lab-10-templates.sh dist           Step 15  templates/lab-10-distribution-config.json
#   ./scripts/utilities/write-lab-10-templates.sh notification   Step 20  templates/lab-10-bucket-notification.json
#   ./scripts/utilities/write-lab-10-templates.sh s3event        Step 21  templates/lab-10-s3-event.json
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-01.env
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

latest_version_arn() {   # $1 = function name -> ARN of its highest published version
  local arn v
  arn=$(aws lambda get-function-configuration --function-name "$1" --query FunctionArn --output text)
  v=$(aws lambda list-versions-by-function --function-name "$1" \
        --query "max_by(Versions[?Version!='\$LATEST'], &to_number(Version)).Version" --output text)
  echo "$arn:$v"
}
need() { case "${2:-}" in ""|None|*:None) echo "STOP - $1 is empty or None" >&2; exit 1 ;; esac; }

case "${1:-}" in
dist)
  # USMS_DIST_VIEWER_VERSION / USMS_DIST_ORIGIN_VERSION pin a specific version
  # (Exercise 1 points origin-response at version 2 this way).
  FN=arn:aws:lambda:us-east-1:$(aws sts get-caller-identity --query Account --output text):function
  VIEWER_VERSION_ARN=${USMS_DIST_VIEWER_VERSION:+$FN:usms-edge-viewer-request:$USMS_DIST_VIEWER_VERSION}
  ORIGIN_VERSION_ARN=${USMS_DIST_ORIGIN_VERSION:+$FN:usms-edge-origin-response:$USMS_DIST_ORIGIN_VERSION}
  VIEWER_VERSION_ARN=${VIEWER_VERSION_ARN:-$(latest_version_arn usms-edge-viewer-request)}
  ORIGIN_VERSION_ARN=${ORIGIN_VERSION_ARN:-$(latest_version_arn usms-edge-origin-response)}
  need VIEWER_VERSION_ARN "$VIEWER_VERSION_ARN"; need ORIGIN_VERSION_ARN "$ORIGIN_VERSION_ARN"
  cat > templates/lab-10-distribution-config.json << EOF
{
  "CallerReference": "usms-transcript-cdn-$(date +%s)",
  "Comment": "usms-transcript-cdn - USMS transcript delivery with edge functions",
  "Enabled": true,
  "PriceClass": "PriceClass_All",
  "DefaultRootObject": "",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "usms-student-data-origin",
        "DomainName": "${BUCKET}.s3.us-east-1.amazonaws.com",
        "OriginPath": "",
        "CustomHeaders": { "Quantity": 0 },
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "usms-student-data-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "MinTTL": 0,
    "DefaultTTL": 300,
    "MaxTTL": 3600,
    "SmoothStreaming": false,
    "FieldLevelEncryptionId": "",
    "TrustedSigners": { "Enabled": false, "Quantity": 0 },
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": { "Forward": "none" },
      "Headers": { "Quantity": 1, "Items": ["x-usms-student"] },
      "QueryStringCacheKeys": { "Quantity": 0 }
    },
    "LambdaFunctionAssociations": {
      "Quantity": 2,
      "Items": [
        {
          "EventType": "viewer-request",
          "LambdaFunctionARN": "${VIEWER_VERSION_ARN}",
          "IncludeBody": false
        },
        {
          "EventType": "origin-response",
          "LambdaFunctionARN": "${ORIGIN_VERSION_ARN}"
        }
      ]
    }
  }
}
EOF
  OUT=templates/lab-10-distribution-config.json ;;
notification)
  ALIAS_ARN=$(aws lambda get-alias --function-name usms-transcript-notifier --name live --query AliasArn --output text)
  need NOTIFIER_ALIAS_ARN "$ALIAS_ARN"
  cat > templates/lab-10-bucket-notification.json << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "usms-transcript-upload",
      "LambdaFunctionArn": "${ALIAS_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "transcripts/" },
            { "Name": "suffix", "Value": ".json" }
          ]
        }
      }
    }
  ]
}
EOF
  OUT=templates/lab-10-bucket-notification.json ;;
s3event)
  cat > templates/lab-10-s3-event.json << EOF
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "us-east-1",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "s3SchemaVersion": "1.0",
        "bucket": {
          "name": "${BUCKET}",
          "arn": "arn:aws:s3:::${BUCKET}"
        },
        "object": {
          "key": "transcripts/evidence/synthetic-probe.json",
          "size": 1024,
          "eTag": "0123456789abcdef0123456789abcdef"
        }
      }
    }
  ]
}
EOF
  OUT=templates/lab-10-s3-event.json ;;
*) echo "usage: $0 dist|notification|s3event" >&2; exit 2 ;;
esac

python3 -m json.tool "$OUT" > /dev/null && echo "$OUT: valid JSON, $(grep -c '\$' "$OUT") unexpanded \$"
