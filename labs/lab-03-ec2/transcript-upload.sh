#!/usr/bin/env bash
# Lab 03 Exercise 5 - runs ON usms-web-01, not on your laptop.
# Uploads one transcript to s3://usms-student-data/transcripts/<student-id>/<filename>.
#
# It carries no credentials and reads none. The AWS CLI on the instance finds
# temporary ones itself, from the instance profile (usms-ec2-app-profile) via the
# Instance Metadata Service, and they rotate without anyone touching this script.
#
# Usage: transcript-upload.sh <student-id> <file>
set -euo pipefail

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

usage() {
  echo "usage: $(basename "$0") <student-id> <file>" >&2
  echo "  e.g. $(basename "$0") S2026001 ./transcript-2026.pdf" >&2
  exit 2
}

[ $# -eq 2 ] || usage
student_id=$1
file=$2

[[ "$student_id" =~ ^[A-Za-z0-9-]+$ ]] \
  || { echo "error: student id '$student_id' must be letters, digits and hyphens only" >&2; exit 2; }
[ -f "$file" ] || { echo "error: '$file' is not a readable file" >&2; exit 2; }
[ -r "$file" ] || { echo "error: '$file' is not readable" >&2; exit 2; }

key="transcripts/${student_id}/$(basename "$file")"
aws s3 cp "$file" "s3://${BUCKET}/${key}" --only-show-errors
echo "uploaded s3://${BUCKET}/${key}"
