#!/usr/bin/env bash
# Generate configs/lab-04.env by LOOKUP (Lab 04 Step 12), never from shell variables,
# so a populated value in the file is evidence the resource actually exists.
#   ./scripts/utilities/write-lab-04-env.sh
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

# Unquoted heredoc: every $(...) must run NOW and its result land in the file.
cat > configs/lab-04.env << EOF
# Lab 04 - ECS cluster, task definition, roles and service outputs
# Generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Contains names, IDs and ARNs only. NO SECRETS. Safe to commit.
#
# Lab 05 attaches a load balancer to the service recorded here. Lab 06 registers
# this service as a scalable target, using the baseline desired count as its floor.

export USMS_ECS_CLUSTER=usms-ecs-cluster
export USMS_ECS_CLUSTER_ARN=$(aws ecs describe-clusters --clusters usms-ecs-cluster \
  --query 'clusters[0].clusterArn' --output text)

export USMS_ENROLMENT_SERVICE=usms-enrolment-svc
export USMS_ENROLMENT_SERVICE_ARN=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].serviceArn' --output text)
export USMS_ECS_DESIRED_BASELINE=$(aws ecs describe-services \
  --cluster usms-ecs-cluster --services usms-enrolment-svc \
  --query 'services[0].desiredCount' --output text)

export USMS_ENROLMENT_TASK_FAMILY=usms-enrolment
export USMS_ENROLMENT_TASK_REVISION=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.revision' --output text)
export USMS_ENROLMENT_CONTAINER=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment \
  --query 'taskDefinition.containerDefinitions[0].name' --output text)
export USMS_ECS_TASK_CPU=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.cpu' --output text)
export USMS_ECS_TASK_MEMORY=$(aws ecs describe-task-definition \
  --task-definition usms-enrolment --query 'taskDefinition.memory' --output text)

export USMS_ENROLMENT_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=usms-enrolment-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)

export USMS_ECS_EXEC_ROLE=usms-ecs-exec-role
export USMS_ECS_EXEC_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-exec-role \
  --query 'Role.Arn' --output text)
export USMS_ECS_TASK_ROLE=usms-ecs-task-role
export USMS_ECS_TASK_ROLE_ARN=$(aws iam get-role --role-name usms-ecs-task-role \
  --query 'Role.Arn' --output text)
export USMS_POLICY_ECS_EXEC=USMSECSTaskExecution

export USMS_LOG_GROUP_ENROLMENT=/usms/ecs/enrolment
EOF

echo "wrote configs/lab-04.env"
