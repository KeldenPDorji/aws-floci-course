#!/usr/bin/env bash
# Exercise 3: one line per subnet in usms-vpc, classified PUBLIC / PRIVATE /
# ISOLATED strictly from its route table's default route — never from the
# subnet's name or tags.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=usms-vpc" --query 'Vpcs[0].VpcId' --output text)

for s in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text); do
  name=$(aws ec2 describe-subnets --subnet-ids "$s" --query 'Subnets[0].Tags[?Key==`Name`]|[0].Value' --output text)
  cidr=$(aws ec2 describe-subnets --subnet-ids "$s" --query 'Subnets[0].CidrBlock' --output text)
  az=$(aws ec2 describe-subnets --subnet-ids "$s" --query 'Subnets[0].AvailabilityZone' --output text)
  rt=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$s" --query 'RouteTables[0].RouteTableId' --output text)
  igw=$(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' --output text 2>/dev/null)
  nat=$(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' --output text 2>/dev/null)

  if [ -n "$igw" ] && [ "$igw" != "None" ]; then
    printf '%s %s %s PUBLIC via %s\n' "$name" "$cidr" "$az" "$igw"
  elif [ -n "$nat" ] && [ "$nat" != "None" ]; then
    printf '%s %s %s PRIVATE via %s\n' "$name" "$cidr" "$az" "$nat"
  else
    printf '%s %s %s ISOLATED no default route\n' "$name" "$cidr" "$az"
  fi
done
