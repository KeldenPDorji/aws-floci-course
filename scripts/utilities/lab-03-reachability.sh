#!/usr/bin/env bash
# Lab 03 Exercise 3 - one reachability line per running USMS instance.
# The verdict is computed from the subnet's route table, the instance's public
# address and its security groups - never from the instance's name or tags.
#
# -e is deliberately OFF. A null field or one failed lookup must degrade a single
# line to "-", not abort the whole report half-way through. The three describe
# calls the report cannot work without are checked explicitly instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

die() { echo "lab-03-reachability: $*" >&2; exit 1; }

instances=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --output json) || die "describe-instances failed"
# Fetched once and filtered locally: one call each, and no reliance on server-side
# filters (Lab 02 found Floci ignores some of them).
route_tables=$(aws ec2 describe-route-tables --output json) || die "describe-route-tables failed"
groups=$(aws ec2 describe-security-groups --output json) || die "describe-security-groups failed"

jq -c '[.Reservations[].Instances[] | {
         name:    ((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // .InstanceId),
         private: (.PrivateIpAddress // "-"),
         public:  (.PublicIpAddress // "-"),
         subnet:  (.SubnetId // ""),
         vpc:     (.VpcId // ""),
         sgs:     [(.SecurityGroups // [])[].GroupId]
       }] | sort_by(.name) | .[]' <<<"$instances" |
while read -r inst; do
  name=$(jq -r .name <<<"$inst")
  private=$(jq -r .private <<<"$inst")
  public=$(jq -r .public <<<"$inst")
  subnet=$(jq -r .subnet <<<"$inst")
  vpc=$(jq -r .vpc <<<"$inst")
  sgs=$(jq -c .sgs <<<"$inst")

  # The subnet's route table: its explicit association, else the VPC's main table.
  default_target=$(jq -r --arg s "$subnet" --arg v "$vpc" '
      ( [.RouteTables[] | select(any(.Associations[]?; .SubnetId == $s))] | .[0] )
      // ( [.RouteTables[] | select(.VpcId == $v and any(.Associations[]?; .Main == true))] | .[0] )
      | if . == null then "" else
          ([.Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")
                       | (.GatewayId // .NatGatewayId // "")] | .[0] // "")
        end' <<<"$route_tables")

  # Does any attached group admit tcp/80 (or all traffic) from 0.0.0.0/0?
  web_rules=$(jq -r --argjson ids "$sgs" '
      [ .SecurityGroups[] | select(.GroupId as $g | any($ids[]; . == $g))
        | .IpPermissions[]?
        | select(.IpProtocol == "-1"
                 or (.IpProtocol == "tcp" and (.FromPort // 0) <= 80 and (.ToPort // 65535) >= 80))
        | select(any(.IpRanges[]?; .CidrIp == "0.0.0.0/0")) ] | length' <<<"$groups")

  if [[ "$default_target" != igw-* ]]; then
    verdict=UNREACHABLE
    reason="no igw route on subnet${default_target:+ (0.0.0.0/0 -> $default_target)}"
  elif [ "$public" = "-" ]; then
    verdict=NO-ADDRESS
    reason="igw route present but no public address"
  elif [ "${web_rules:-0}" -gt 0 ]; then
    verdict=REACHABLE
    reason="igw route + sg allows 80/tcp from 0.0.0.0/0"
  else
    verdict=FILTERED
    reason="igw route + public address, but no sg rule admits 80/tcp from 0.0.0.0/0"
  fi

  printf '%-20s %-12s %-15s %-13s %s\n' "$name" "$private" "$public" "$verdict" "$reason"
done
