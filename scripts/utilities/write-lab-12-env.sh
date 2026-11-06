#!/usr/bin/env bash
# Generate configs/lab-12.env by LOOKUP (Lab 12 Step 20). Names, ARNs, tags and digests only.
# The guide's 26 exports and sentinels, runnable from any directory. The registry host is
# derived in the shell (${URI%%/*}) before the heredoc, so the guide's cut -d/ workaround
# is not needed. Stops if a must-succeed lookup returns empty or None.
#   ./scripts/utilities/write-lab-12-env.sh            26 exports
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

q()  { "$@" 2>/dev/null || true; }
URI=$(q aws ecr describe-repositories --repository-names usms-enrolment --query 'repositories[0].repositoryUri' --output text)
MUT=$(q aws ecr describe-repositories --repository-names usms-enrolment --query 'repositories[0].imageTagMutability' --output text | grep -E '^[A-Z]+$' || echo not-created)
SCAN=$(q aws ecr describe-repositories --repository-names usms-enrolment --query 'repositories[0].imageScanningConfiguration.scanOnPush' --output text | grep -Ei '^(true|false)$' || echo unknown)
TAG=$(tr -d '[:space:]' < labs/lab-11-cicd/app/VERSION)
DIGEST=$(q aws ecr describe-images --repository-name usms-enrolment --image-ids "imageTag=$TAG" --query 'imageDetails[0].imageDigest' --output text | grep -E '^sha256:' || echo not-pushed)
# Latest ACTIVE revision, asked for explicitly: on Floci 2.2.0 a bare family name in
# describe-task-definition returns the newest revision even when it is INACTIVE (:5 here),
# where real AWS returns the newest ACTIVE one.
TD_ARN=$(q aws ecs list-task-definitions --family-prefix usms-enrolment --status ACTIVE --sort DESC \
           --query 'taskDefinitionArns[0]' --output text | grep -E '^arn:' || echo not-created)
REV=$(printf '%s' "${TD_ARN##*:}" | grep -E '^[0-9]+$' || echo 0)
SVC_TD=$(q aws ecs describe-services --cluster usms-ecs-cluster --services usms-enrolment-svc --query 'services[0].taskDefinition' --output text | grep -E '^arn:' || echo not-created)
STAGES=$(q aws codepipeline get-pipeline --name usms-enrolment-pipeline --query 'length(pipeline.stages)' --output text | grep -E '^[0-9]+$' || echo 0)
CBV=$(q aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodeBuildBase --query 'Policy.DefaultVersionId' --output text | grep -E '^v[0-9]+$' || echo unknown)
CPV=$(q aws iam get-policy --policy-arn arn:aws:iam::000000000000:policy/USMSCodePipelineBase --query 'Policy.DefaultVersionId' --output text | grep -E '^v[0-9]+$' || echo unknown)
CD=$(sed -n 's/^USMS_CODEDEPLOY_SUPPORTED=//p' outputs/lab-12-deploy-probe.txt 2>/dev/null); CD="${CD:-unknown}"
DP=$(sed -n 's/^USMS_CICD_DEPLOY_PATH=//p' outputs/lab-12-deploy-probe.txt 2>/dev/null); DP="${DP:-unknown}"
NOW=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

case "$URI" in */*) ;; *) echo "STOP - no repositoryUri for usms-enrolment; configs/lab-12.env not written" >&2; exit 1 ;; esac
# The rollback target is the revision the service runs now (Step 18 rolled back to it).
ROLLBACK="${SVC_TD##*:}"

cat > configs/lab-12.env << EOF
# Lab 12 - CI/CD: the image, the registry, and the deploy stage
# Generated on ${NOW}
# Contains names, ARNs, tags and digests only. NO SECRETS. Safe to commit.
#
# Floci 2.2.0: the pipeline's Deploy stage (provider ECS) fails at run time ("Provider ECS is
# not available in Floci CodePipeline"); revisions 4 and 5 were registered by
# scripts/utilities/usms-ecs-deploy-action.sh, a stand-in for that action. Revision 5
# (image r8, never pushed) is deregistered and tagged usms:status=failed-deploy.

# --- registry ---
export USMS_ECR_REPO=usms-enrolment
export USMS_ECR_REPO_URI=${URI}
export USMS_ECR_REGISTRY=${URI%%/*}
export USMS_ECR_TAG_MUTABILITY=${MUT}
export USMS_ECR_SCAN_ON_PUSH=${SCAN}
# Floci's configured ECR range; its registry sidecar publishes 127.0.0.1:5100 itself, and
# pushes go through 4566 (the repositoryUri), so the range is NOT published on the floci container.
export USMS_ECR_PORT_RANGE=5100-5104

# --- image ---
export USMS_IMAGE_TAG=${TAG}
export USMS_IMAGE_DIGEST=${DIGEST}
export USMS_IMAGEDEFS_FILE=imagedefinitions.json
export USMS_DOCKERFILE=labs/lab-11-cicd/app/Dockerfile

# --- task definition and service ---
export USMS_TASK_FAMILY=usms-enrolment
export USMS_TASK_REVISION_CICD=${REV}
export USMS_TASK_DEF_ARN_CICD=${TD_ARN}
export USMS_SERVICE_TASK_DEF=${SVC_TD}
export USMS_ROLLBACK_REVISION=${ROLLBACK}

# --- pipeline deploy stage ---
export USMS_DEPLOY_STAGE=Deploy
export USMS_DEPLOY_ACTION=DeployToECS
export USMS_DEPLOY_PROVIDER=ECS
export USMS_PIPELINE_STAGES=${STAGES}

# --- policy versions ---
export USMS_POLICY_CODEBUILD_VERSION=${CBV}
export USMS_POLICY_CODEPIPELINE_VERSION=${CPV}

# --- blue/green, conceptual ---
export USMS_CODEDEPLOY_SUPPORTED=${CD}
export USMS_CODEDEPLOY_APP=usms-enrolment-app
export USMS_CODEDEPLOY_DG=usms-enrolment-dg
export USMS_APPSPEC_FILE=templates/lab-12-appspec.yaml
export USMS_CICD_DEPLOY_PATH=${DP}
EOF

echo "configs/lab-12.env: $(grep -c '^export' configs/lab-12.env) exports"
