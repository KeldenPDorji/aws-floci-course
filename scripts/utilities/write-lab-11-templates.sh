#!/usr/bin/env bash
# Lab 11 - write the two request bodies that embed a role ARN, BY LOOKUP.
# The guide writes them with unquoted heredocs from BUILD_ROLE_ARN / PIPELINE_ROLE_ARN, which
# are empty in any new terminal; this reads each ARN from IAM and refuses to write a hole.
#   ./scripts/utilities/write-lab-11-templates.sh project    Step 10  templates/lab-11-codebuild-project.json
#   ./scripts/utilities/write-lab-11-templates.sh pipeline   Step 16  templates/lab-11-pipeline.json
#
# One deliberate difference from the guide's Step 10 template: no "buildspec": "buildspec.yml"
# in source. Floci 2.2.0 reads that value as an INLINE buildspec - the string parses as YAML with
# no phases, so every phase "succeeds" in ~30 ms with nothing run and no artifact. With the field
# omitted, CodeBuild (real AWS and Floci alike) reads buildspec.yml from the source root, which is
# what the guide's value means anyway.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

role_arn() { aws iam get-role --role-name "$1" --query 'Role.Arn' --output text; }
need() { case "${2:-}" in ""|None) echo "STOP - $1 is empty or None" >&2; exit 1 ;; esac; }

case "${1:-}" in
project|standalone)
  # standalone: the same project under a second name that KEEPS its S3 source, so the source
  # object can still be built in a real CodeBuild container after Step 18 hands
  # usms-enrolment-build to the pipeline. Needed on Floci 2.2.0 only: its pipeline gives a
  # CODEPIPELINE build an empty source directory and stores no BuildOutput (lab-11-report 6.2).
  BUILD_ROLE_ARN=$(role_arn usms-codebuild-role); need BUILD_ROLE_ARN "$BUILD_ROLE_ARN"
  if [ "$1" = standalone ]; then
    NAME=usms-enrolment-build-standalone; OUTFILE=templates/lab-11-codebuild-project-standalone.json
    DESC="Floci stand-in: builds source/usms-enrolment-src.zip outside the pipeline"
  else
    NAME=usms-enrolment-build; OUTFILE=templates/lab-11-codebuild-project.json
    DESC="Builds the USMS enrolment service artifact from labs/lab-11-cicd/app"
  fi
  cat > "$OUTFILE" << EOF
{
  "name": "${NAME}",
  "description": "${DESC}",
  "source": {
    "type": "S3",
    "location": "usms-pipeline-artifacts/source/usms-enrolment-src.zip"
  },
  "artifacts": {
    "type": "S3",
    "location": "usms-pipeline-artifacts",
    "path": "build",
    "name": "${NAME}.zip",
    "packaging": "ZIP",
    "namespaceType": "NONE"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": false,
    "environmentVariables": [
      { "name": "USMS_PROJECT", "value": "USMS", "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE", "value": "enrolment", "type": "PLAINTEXT" }
    ]
  },
  "serviceRole": "${BUILD_ROLE_ARN}",
  "timeoutInMinutes": 15,
  "queuedTimeoutInMinutes": 30,
  "logsConfig": {
    "cloudWatchLogs": {
      "status": "ENABLED",
      "groupName": "/aws/codebuild/usms-enrolment-build"
    }
  },
  "tags": [
    { "key": "Project", "value": "USMS" },
    { "key": "Tier", "value": "pipeline" },
    { "key": "Lab", "value": "11" }
  ]
}
EOF
  OUT="$OUTFILE" ;;
pipeline)
  PIPELINE_ROLE_ARN=$(role_arn usms-codepipeline-role); need PIPELINE_ROLE_ARN "$PIPELINE_ROLE_ARN"
  cat > templates/lab-11-pipeline.json << EOF
{
  "pipeline": {
    "name": "usms-enrolment-pipeline",
    "roleArn": "${PIPELINE_ROLE_ARN}",
    "artifactStore": {
      "type": "S3",
      "location": "usms-pipeline-artifacts"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "FetchSource",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "S3",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "S3Bucket": "usms-pipeline-artifacts",
              "S3ObjectKey": "source/usms-enrolment-src.zip",
              "PollForSourceChanges": "false"
            },
            "inputArtifacts": [],
            "outputArtifacts": [ { "name": "SourceOutput" } ]
          }
        ]
      },
      {
        "name": "Build",
        "actions": [
          {
            "name": "BuildArtifact",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "runOrder": 1,
            "configuration": {
              "ProjectName": "usms-enrolment-build"
            },
            "inputArtifacts": [ { "name": "SourceOutput" } ],
            "outputArtifacts": [ { "name": "BuildOutput" } ]
          }
        ]
      }
    ]
  }
}
EOF
  OUT=templates/lab-11-pipeline.json ;;
results)
  # Exercise 1. Reuses usms-codebuild-role. USMSCodeBuildBase's log statement names only
  # /aws/codebuild/usms-enrolment-build (and :* for its streams), so this project writes to
  # THAT group under its own stream name rather than to /aws/codebuild/usms-results-build,
  # which the policy would deny on real AWS. That keeps USMSCodeBuildBase at v1 for Lab 12.
  BUILD_ROLE_ARN=$(role_arn usms-codebuild-role); need BUILD_ROLE_ARN "$BUILD_ROLE_ARN"
  cat > templates/lab-11-results-build-project.json << EOF
{
  "name": "usms-results-build",
  "description": "Lab 11 Exercise 1 - builds the USMS results service from labs/lab-11-cicd/app-results",
  "source": {
    "type": "S3",
    "location": "usms-pipeline-artifacts/source/usms-results-src.zip"
  },
  "artifacts": {
    "type": "S3",
    "location": "usms-pipeline-artifacts",
    "path": "build",
    "name": "usms-results-build.zip",
    "packaging": "ZIP",
    "namespaceType": "NONE"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": false,
    "environmentVariables": [
      { "name": "USMS_PROJECT", "value": "USMS", "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE", "value": "results", "type": "PLAINTEXT" }
    ]
  },
  "serviceRole": "${BUILD_ROLE_ARN}",
  "timeoutInMinutes": 15,
  "queuedTimeoutInMinutes": 30,
  "logsConfig": {
    "cloudWatchLogs": {
      "status": "ENABLED",
      "groupName": "/aws/codebuild/usms-enrolment-build",
      "streamName": "usms-results-build"
    }
  },
  "tags": [
    { "key": "Project", "value": "USMS" },
    { "key": "Tier", "value": "pipeline" },
    { "key": "Lab", "value": "11" }
  ]
}
EOF
  OUT=templates/lab-11-results-build-project.json ;;
*) echo "usage: $0 project|standalone|results|pipeline" >&2; exit 2 ;;
esac

python3 -m json.tool "$OUT" > /dev/null && echo "$OUT: valid JSON, $(grep -c '\$' "$OUT") unexpanded \$"
