#!/usr/bin/env bash
# One description of the whole USMS system, across every practical.
# Read-only. Safe to run at any time. Writes nothing except its own stdout.
#
# The guide's script (Lab 13, Appendix - Project Implementation Checkpoint 1), with two fixes:
# - "tracked secrets" used `grep -cv ... || echo 0`. grep -c already prints 0 when nothing
#   matches, and then exits 1, so the line read "0" followed by a second "0" on its own line.
#   It is now `|| true`.
# - "verification" printed `tail -1` of each script. verify-lab-05, -06 and -09 end with a
#   footnote after their totals, so three rows showed prose instead of PASS/FAIL - and two of
#   those hid a FAIL. It now prints the PASS= line.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
for f in configs/lab-*.env; do
  # shellcheck disable=SC1090
  [ -f "$f" ] && source "$f"
done

section() { printf '\n== %s ==\n' "$1"; }
count()   { printf '%s' "${1:-0}"; }

printf 'USMS project inventory - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'account : %s\n' "$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo UNREACHABLE)"
printf 'endpoint: %s\n' "${FLOCI_ENDPOINT:-unset}"

section "identity (Lab 01)"
aws iam list-roles --query "Roles[?starts_with(RoleName, 'usms-')].RoleName" --output text | tr '\t' '\n'
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, 'USMS')].PolicyName" --output text | tr '\t' '\n'

section "network (Lab 02)"
aws ec2 describe-vpcs --filters Name=tag:Project,Values=USMS \
  --query 'Vpcs[].[VpcId,CidrBlock]' --output text 2>/dev/null || echo "none"
aws ec2 describe-subnets --filters Name=tag:Project,Values=USMS \
  --query 'length(Subnets)' --output text 2>/dev/null || echo 0

section "compute (Labs 03, 04, 05)"
aws ec2 describe-instances --filters Name=tag:Project,Values=USMS \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>/dev/null || echo "none"
aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null || echo "none"
aws eks list-clusters --query 'clusters' --output text 2>/dev/null || echo "none"

section "storage and functions (Lab 10)"
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'usms-')].Name" --output text 2>/dev/null
aws lambda list-functions \
  --query "sort_by(Functions[?starts_with(FunctionName, 'usms-')], &FunctionName)[].[FunctionName,Runtime,TracingConfig.Mode]" \
  --output text 2>/dev/null || echo "none"

section "pipeline (Labs 11, 12)"
aws codepipeline list-pipelines --query 'pipelines[].name' --output text 2>/dev/null || echo "none"
aws codebuild list-projects --query 'projects' --output text 2>/dev/null || echo "none"
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null || echo "none"

section "observability (Lab 13)"
aws logs describe-log-groups \
  --query 'logGroups[].[logGroupName,retentionInDays]' --output text 2>/dev/null
aws cloudwatch list-metrics --namespace USMS/Application \
  --query 'Metrics[].MetricName' --output text 2>/dev/null | tr '\t' '\n' | sort -u
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text 2>/dev/null
aws cloudwatch describe-alarms --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].AlarmName' --output text 2>/dev/null
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text 2>/dev/null

section "repository"
printf 'lab documents   : %s\n' "$(ls -d labs/lab-* 2>/dev/null | wc -l | tr -d ' ')"
printf 'env files       : %s\n' "$(ls configs/lab-*.env 2>/dev/null | wc -l | tr -d ' ')"
printf 'verify scripts  : %s\n' "$(ls scripts/utilities/verify-lab-*.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'cleanup scripts : %s\n' "$(ls scripts/cleanup/lab-*-cleanup.sh 2>/dev/null | wc -l | tr -d ' ')"
printf 'commits         : %s\n' "$(git rev-list --count HEAD 2>/dev/null || echo 0)"
printf 'tracked secrets : %s\n' "$(git ls-files outputs/ | grep -cv '.gitkeep' || true)"

section "verification"
for v in scripts/utilities/verify-lab-*.sh; do
  [ -x "$v" ] || continue
  printf '%-40s %s\n' "$v" "$("$v" 2>/dev/null | grep -E '^PASS=' | tail -1)"
done
