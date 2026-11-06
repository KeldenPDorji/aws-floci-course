#!/usr/bin/env bash
# Lab 12 - write request bodies that embed a live value, BY LOOKUP (never a shell variable
# from an earlier step, which is empty in a new terminal).
#   ./scripts/utilities/write-lab-12-templates.sh codebuild   Step 13  templates/lab-12-codebuild-update.json
#   ./scripts/utilities/write-lab-12-templates.sh pipeline    Step 16  templates/lab-12-pipeline-current.json
#                                                                       + templates/lab-12-pipeline.json
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

case "${1:-}" in
codebuild)
  ECR_URI=$(aws ecr describe-repositories --repository-names usms-enrolment \
              --query 'repositories[0].repositoryUri' --output text)
  case "$ECR_URI" in */*) ;; *) echo "STOP - no pushable repositoryUri: '$ECR_URI'" >&2; exit 1 ;; esac
  cat > templates/lab-12-codebuild-update.json << EOF
{
  "name": "usms-enrolment-build",
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      { "name": "USMS_PROJECT",   "value": "USMS",           "type": "PLAINTEXT" },
      { "name": "USMS_SERVICE",   "value": "enrolment",      "type": "PLAINTEXT" },
      { "name": "IMAGE_REPO_URI", "value": "${ECR_URI}",     "type": "PLAINTEXT" },
      { "name": "AWS_REGION_COURSE", "value": "us-east-1",   "type": "PLAINTEXT" }
    ]
  }
}
EOF
  OUT=templates/lab-12-codebuild-update.json ;;
pipeline)
  # get (dropping metadata) -> modify (append ONE Deploy stage) -> write; update-pipeline is
  # a separate, deliberate step. Paranoid by design: refuses unexpected stages or a 2nd Deploy.
  aws codepipeline get-pipeline --name usms-enrolment-pipeline \
    --query 'pipeline' --output json > templates/lab-12-pipeline-current.json
  python3 - << 'PY'
import json

CURRENT = "templates/lab-12-pipeline-current.json"
OUT     = "templates/lab-12-pipeline.json"

pipeline = json.load(open(CURRENT))

names = [s["name"] for s in pipeline["stages"]]
assert names[:2] == ["Source", "Build"], f"unexpected stages: {names}"
if "Deploy" in names:
    raise SystemExit("a Deploy stage already exists - nothing to do")

deploy_stage = {
    "name": "Deploy",
    "actions": [
        {
            "name": "DeployToECS",
            "actionTypeId": {
                "category": "Deploy",
                "owner": "AWS",
                "provider": "ECS",
                "version": "1"
            },
            "runOrder": 1,
            "configuration": {
                "ClusterName": "usms-ecs-cluster",
                "ServiceName": "usms-enrolment-svc",
                "FileName": "imagedefinitions.json",
                "DeploymentTimeout": "10"
            },
            "inputArtifacts": [{"name": "BuildOutput"}],
            "outputArtifacts": []
        }
    ]
}

pipeline["stages"].append(deploy_stage)
json.dump({"pipeline": pipeline}, open(OUT, "w"), indent=2)

print("stages before:", names)
print("stages now:   ", [s["name"] for s in pipeline["stages"]])
print("wrote", OUT)
PY
  OUT=templates/lab-12-pipeline.json ;;
*) echo "usage: $0 codebuild|pipeline" >&2; exit 2 ;;
esac

python3 -m json.tool "$OUT" > /dev/null && echo "$OUT: valid JSON, $(grep -c '\$' "$OUT") unexpanded \$"
