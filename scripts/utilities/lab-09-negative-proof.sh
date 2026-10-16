#!/usr/bin/env bash
# Lab 09 Step 17 Part 2 - "usms-db-01 is not reachable from the internet", five controls,
# each of which would have to fail independently for the claim to be false. Read-only.
# Every identifier is looked up, not taken from a shell variable. One line per control.
#   ./scripts/utilities/lab-09-negative-proof.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env

DB=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=usms-db-01" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text)
SUBNET=$(aws ec2 describe-instances --instance-ids "$DB" --query 'Reservations[0].Instances[0].SubnetId' --output text)
DBSG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-db-sg" --query 'SecurityGroups[0].GroupId' --output text)
APPSG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-app-sg" --query 'SecurityGroups[0].GroupId' --output text)

c() { printf '  %-60s %s\n' "$1" "$(echo "$2" | tr '\t\n' '  ')"; }
echo "== Claim: usms-db-01 ($DB in $SUBNET) is not reachable from the internet =="
c "control 1: no public address" \
  "$(aws ec2 describe-instances --instance-ids "$DB" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
c "control 2: subnet does not auto-assign one" \
  "$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].MapPublicIpOnLaunch' --output text)"
c "control 3: 0.0.0.0/0 route -> [internet gateway, nat]" \
  "$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET" --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId]' --output text)"
c "control 4: usms-db-sg ingress [port, group, cidr]" \
  "$(aws ec2 describe-security-groups --group-ids "$DBSG" --query 'SecurityGroups[0].IpPermissions[].[FromPort,UserIdGroupPairs[0].GroupId,IpRanges[0].CidrIp]' --output text)   (usms-app-sg = $APPSG)"
c "control 5: subnet NACL [id, is-default]" \
  "$(aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$SUBNET" --query 'NetworkAcls[0].[NetworkAclId,IsDefault]' --output text)"
