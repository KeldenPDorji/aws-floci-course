#!/usr/bin/env bash
# Lab 09 - write the six policy and rule documents that embed IDs, BY LOOKUP.
# The guide writes these with unquoted heredocs in Steps 7, 8, 13, 14 and 16; one script
# does all six so no document can be written with an empty variable in it.
#   policies/trust-ecs-tasks-scoped.json      Step 7   account, region
#   policies/usms-deploy-policy.json          Step 8   account
#   policies/trust-deploy.json                Step 8   account, admin user
#   policies/usms-enrolment-sg-egress.json    Step 13  the S3 managed prefix list
#   policies/usms-alb-sg-egress.json          Step 14  usms-enrolment-sg
#   policies/usms-app-sg-ssh-bastion.json     Step 16  usms-bastion-sg (reused from Lab 02 Exercise 2)
#   policies/usms-app-sg-egress.json          Ex. 1    the S3 prefix list, usms-alb-sg, usms-db-sg
#   policies/trust-lambda-scoped.json         Ex. 2    account, region
#   policies/trust-breakglass.json            Ex. 2    account, admin user
# The four static documents (read-only policy, boundary, db egress, allow-all undo) are
# plain files with nothing to expand.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-01 lab-02 lab-04; do source "configs/$f.env"; done

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION_COURSE:-us-east-1}"
ADMIN_USER=$(aws iam get-user --user-name "${USMS_ADMIN_USER:-usms-admin-01}" --query 'User.UserName' --output text)
ENROLMENT_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-enrolment-sg" "Name=vpc-id,Values=$USMS_VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
BASTION_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-bastion-sg" "Name=vpc-id,Values=$USMS_VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
# Step 13 Part 1: the guide's first source. This build's private route table has no
# prefix-list route (Lab 02's endpoint route was never injected), so the fallback is moot.
S3_PREFIX_LIST=$(aws ec2 describe-prefix-lists --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.s3" --query 'PrefixLists[0].PrefixListId' --output text)

ALB_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-alb-sg" "Name=vpc-id,Values=$USMS_VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
DB_SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-db-sg" "Name=vpc-id,Values=$USMS_VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
# The Amazon-provided resolver is the VPC CIDR's base address plus two (Lab 02's reserved addresses).
RESOLVER=$(python3 -c "import ipaddress,sys;print(ipaddress.ip_network(sys.argv[1]).network_address+2)" "$USMS_VPC_CIDR")

for V in ACCOUNT REGION ADMIN_USER ENROLMENT_SG BASTION_SG S3_PREFIX_LIST ALB_SG DB_SG RESOLVER; do
  case "${!V:-}" in ""|None) echo "STOP - $V is empty or None" >&2; exit 1 ;; esac
done

cat > policies/trust-ecs-tasks-scoped.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcsTasksMayAssumeThisRoleForThisAccountOnly",
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT}" },
        "ArnLike": {
          "aws:SourceArn": "arn:aws:ecs:${REGION}:${ACCOUNT}:*"
        }
      }
    }
  ]
}
EOF

cat > policies/usms-deploy-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DeployTheContainerPlatform",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:DeregisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:ListTasks",
        "ecs:DescribeTasks",
        "elasticloadbalancing:Describe*",
        "application-autoscaling:Describe*",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassOnlyTheseThreeRolesAndOnlyToTheseServices",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${ACCOUNT}:role/usms-ecs-exec-role",
        "arn:aws:iam::${ACCOUNT}:role/usms-ecs-task-role",
        "arn:aws:iam::${ACCOUNT}:role/usms-transcripts-reader-role"
      ],
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "NeverPassAnythingToEC2",
      "Effect": "Deny",
      "Action": "iam:PassRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    }
  ]
}
EOF

cat > policies/trust-deploy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OnlyTheAdminUserMayDeploy",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT}:user/${ADMIN_USER}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

cat > policies/usms-enrolment-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "PrefixListIds": [
      {
        "PrefixListId": "${S3_PREFIX_LIST}",
        "Description": "S3 via the Lab 02 gateway endpoint - transcripts, and nothing leaves the AWS network"
      }
    ]
  },
  {
    "IpProtocol": "tcp",
    "FromPort": 443,
    "ToPort": 443,
    "IpRanges": [
      {
        "CidrIp": "0.0.0.0/0",
        "Description": "HTTPS out for the container image pull and the awslogs driver - narrow this to interface endpoints on real AWS"
      }
    ]
  }
]
EOF

cat > policies/usms-alb-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "UserIdGroupPairs": [
      {
        "GroupId": "${ENROLMENT_SG}",
        "Description": "HTTP to the enrolment tasks - the ONLY thing this load balancer may initiate"
      }
    ]
  }
]
EOF

cat > policies/usms-app-sg-ssh-bastion.json << EOF
[
  {
    "IpProtocol": "tcp",
    "FromPort": 22,
    "ToPort": 22,
    "UserIdGroupPairs": [
      {
        "GroupId": "${BASTION_SG}",
        "Description": "SSH from the USMS jump host tier only - replaces the 10.0.0.0/16 rule from Lab 02 Step 14"
      }
    ]
  }
]
EOF

# Exercise 1. Unquoted heredoc: four IDs must be real now. DNS: UDP first because that is what
# resolvers use; TCP for responses over 512 bytes and for retries after truncation.
cat > policies/usms-app-sg-egress.json << EOF
[
  {
    "IpProtocol": "tcp", "FromPort": 443, "ToPort": 443,
    "PrefixListIds": [
      { "PrefixListId": "${S3_PREFIX_LIST}", "Description": "1. S3 via the Lab 02 gateway endpoint - Lab 10's transcripts" }
    ],
    "IpRanges": [
      { "CidrIp": "0.0.0.0/0", "Description": "2. HTTPS to AWS service endpoints, incl. STS for the instance profile - narrow to interface endpoints on real AWS" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 80, "ToPort": 80,
    "UserIdGroupPairs": [
      { "GroupId": "${ALB_SG}", "Description": "3. the enrolment API - since Lab 05 that is the load balancer, not the tasks" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
    "UserIdGroupPairs": [
      { "GroupId": "${DB_SG}", "Description": "4. PostgreSQL to the data tier" }
    ]
  },
  {
    "IpProtocol": "udp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [
      { "CidrIp": "${RESOLVER}/32", "Description": "5a. DNS to the Amazon resolver (VPC base + 2) - UDP is the normal path" }
    ]
  },
  {
    "IpProtocol": "tcp", "FromPort": 53, "ToPort": 53,
    "IpRanges": [
      { "CidrIp": "${RESOLVER}/32", "Description": "5b. DNS over TCP - large or truncated answers fall back to it" }
    ]
  }
]
EOF

# Exercise 2 Part B - Lambda's confused-deputy conditions, as for ecs-tasks.
cat > policies/trust-lambda-scoped.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LambdaMayAssumeThisRoleForThisAccountsFunctionsOnly",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT}" },
        "ArnLike": { "aws:SourceArn": "arn:aws:lambda:${REGION}:${ACCOUNT}:function:*" }
      }
    }
  ]
}
EOF

# Exercise 2 Part A - one Condition block, two operators: IAM ANDs them, so BOTH must hold.
cat > policies/trust-breakglass.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "OnlyTheAdminWithMfaAndTheExternalIdMayBreakTheGlass",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${ACCOUNT}:user/${ADMIN_USER}" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool": { "aws:MultiFactorAuthPresent": "true" },
        "StringEquals": { "sts:ExternalId": "usms-breakglass-suspend-scaling" }
      }
    }
  ]
}
EOF

for f in policies/usms-student-data-ro-policy.json policies/trust-ecs-tasks-scoped.json \
         policies/usms-permissions-boundary.json policies/usms-deploy-policy.json policies/trust-deploy.json \
         policies/usms-enrolment-sg-egress.json policies/usms-alb-sg-egress.json policies/usms-db-sg-egress.json \
         policies/usms-egress-allow-all.json policies/usms-app-sg-ssh-bastion.json policies/usms-app-sg-egress.json \
         policies/trust-lambda-scoped.json policies/trust-breakglass.json; do
  python3 -m json.tool "$f" > /dev/null && printf '%-44s valid JSON, %s unexpanded $\n' "$f" "$(grep -c '\$' "$f")"
done
echo "account=$ACCOUNT region=$REGION admin=$ADMIN_USER enrolment-sg=$ENROLMENT_SG bastion-sg=$BASTION_SG s3-prefix-list=$S3_PREFIX_LIST"
