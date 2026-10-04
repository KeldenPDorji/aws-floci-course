#!/usr/bin/env bash
# Generate configs/lab-03.env by LOOKUP (Lab 03 Step 22), never from shell variables.
# The base AMI is the one input that cannot be looked up by tag, so it is passed in:
#   ./scripts/utilities/write-lab-03-env.sh "$AMI_ID"
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

AMI_ID="${1:?usage: write-lab-03-env.sh <base-ami-id>}"

# Unquoted heredoc: every $(...) must run NOW and its result land in the file.
cat > configs/lab-03.env << EOF
# Lab 03 - EC2 outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains IDs only. NO SECRETS. Safe to commit.
# The private key for usms-app-key lives in outputs/ and is NOT recorded here.

export USMS_KEY_PAIR=usms-app-key

export USMS_WEB_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-web-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
export USMS_DB_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=usms-db-01" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

export USMS_WEB_EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=usms-web-eip" \
  --query 'Addresses[0].AllocationId' --output text)
export USMS_WEB_PUBLIC_IP=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=usms-web-eip" \
  --query 'Addresses[0].PublicIp' --output text)

export USMS_WEB_DATA_VOLUME=$(aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=usms-web-data-vol" \
  --query 'Volumes[0].VolumeId' --output text)

export USMS_WEB_AMI=$(aws ec2 describe-images --owners self \
  --query "Images[?starts_with(Name, 'usms-web-golden')] | [0].ImageId" --output text)

export USMS_BASE_AMI=$AMI_ID
export USMS_INSTANCE_TYPE=t3.micro
EOF

echo "wrote configs/lab-03.env"
