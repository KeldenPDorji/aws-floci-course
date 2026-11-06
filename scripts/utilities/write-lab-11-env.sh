#!/usr/bin/env bash
# Generate configs/lab-11.env by LOOKUP (Lab 11 Step 21). Names, ARNs and IDs only.
# The guide's heredoc already looks most values up; this keeps its 26 exports and their
# sentinels, runs from any directory, and refuses to write the file if a lookup that
# must succeed comes back empty or None.
#   ./scripts/utilities/write-lab-11-env.sh            26 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

B=usms-pipeline-artifacts
VERSIONING=$(aws s3api get-bucket-versioning --bucket $B --query 'Status' --output text 2>/dev/null \
               | grep -E '^(Enabled|Suspended)$' || echo Unknown)
SRC_VID=$(aws s3api head-object --bucket $B --key source/usms-enrolment-src.zip \
            --query 'VersionId' --output text 2>/dev/null || echo not-created)
PROJ_ARN=$(aws codebuild batch-get-projects --names usms-enrolment-build \
             --query 'projects[0].arn' --output text 2>/dev/null | grep -E '^arn:' || echo not-created)
SRC_TYPE=$(aws codebuild batch-get-projects --names usms-enrolment-build \
             --query 'projects[0].source.type' --output text 2>/dev/null | grep -E '^[A-Z_]+$' || echo not-created)
STAGES=$(aws codepipeline get-pipeline --name usms-enrolment-pipeline \
           --query 'length(pipeline.stages)' --output text 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
BUILD_ROLE_ARN=$(aws iam get-role --role-name usms-codebuild-role --query 'Role.Arn' --output text)
PIPE_ROLE_ARN=$(aws iam get-role --role-name usms-codepipeline-role --query 'Role.Arn' --output text)
RELEASE=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
CICD_PATH=$(sed -n 's/^USMS_CICD_SUPPORT_PATH=//p' outputs/lab-11-support-probe.txt 2>/dev/null)
NOW=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

for v in "$SRC_VID" "$BUILD_ROLE_ARN" "$PIPE_ROLE_ARN" "$RELEASE"; do
  case "$v" in ""|None) echo "STOP - a lookup came back empty or None; configs/lab-11.env not written" >&2; exit 1 ;; esac
done

cat > configs/lab-11.env << EOF
# Lab 11 - CI/CD: source, build, and the pipeline that joins them
# Generated on ${NOW}
# Contains names, ARNs and IDs only. NO SECRETS. Safe to commit.
#
# Floci 2.2.0 note: the pipeline's builds receive no source and store no BuildOutput, so
# the source object is also built by usms-enrolment-build-standalone (S3 source). That
# project is a stand-in for this build only and is deliberately NOT exported here.

# --- artifact store and source ---
export USMS_PIPELINE_BUCKET=${B}
export USMS_PIPELINE_BUCKET_VERSIONING=${VERSIONING}
export USMS_SOURCE_KEY=source/usms-enrolment-src.zip
export USMS_SOURCE_VERSION_ID=${SRC_VID}
export USMS_BUILD_ARTIFACT_PREFIX=usms-enrolment-pipeline/BuildOutput/

# --- build project ---
export USMS_BUILD_PROJECT=usms-enrolment-build
export USMS_BUILD_PROJECT_ARN=${PROJ_ARN}
export USMS_BUILD_SOURCE_TYPE=${SRC_TYPE}
export USMS_BUILD_IMAGE=aws/codebuild/standard:7.0
export USMS_BUILD_COMPUTE_TYPE=BUILD_GENERAL1_SMALL
export USMS_BUILD_TIMEOUT_MINUTES=15
export USMS_BUILD_LOG_GROUP=/aws/codebuild/usms-enrolment-build

# --- build identity ---
export USMS_BUILD_ROLE=usms-codebuild-role
export USMS_BUILD_ROLE_ARN=${BUILD_ROLE_ARN}
export USMS_POLICY_CODEBUILD=USMSCodeBuildBase
export USMS_POLICY_CODEBUILD_ARN=arn:aws:iam::000000000000:policy/USMSCodeBuildBase

# --- pipeline ---
export USMS_PIPELINE_NAME=usms-enrolment-pipeline
export USMS_PIPELINE_STAGE_COUNT=${STAGES}
export USMS_PIPELINE_ROLE=usms-codepipeline-role
export USMS_PIPELINE_ROLE_ARN=${PIPE_ROLE_ARN}
export USMS_POLICY_CODEPIPELINE=USMSCodePipelineBase
export USMS_POLICY_CODEPIPELINE_ARN=arn:aws:iam::000000000000:policy/USMSCodePipelineBase

# --- source tree ---
export USMS_APP_SRC_DIR=labs/lab-11-cicd/app
export USMS_BUILDSPEC=labs/lab-11-cicd/app/buildspec.yml
export USMS_RELEASE_TAG=${RELEASE}
export USMS_CICD_SUPPORT_PATH=${CICD_PATH:-unknown}
EOF

echo "configs/lab-11.env: $(grep -c '^export' configs/lab-11.env) exports"
