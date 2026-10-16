#!/usr/bin/env bash
# USMS exposure report (Lab 09 Exercise 3). One line per network interface in usms-vpc:
#   name  private-ip  public-ip  VERDICT  reason
# The verdict is COMPUTED from three facts per interface, never from names, tags or
# descriptions: (1) does its subnet's route table send 0.0.0.0/0 to an internet gateway,
# (2) does it have a public address, (3) does any of its security groups admit 0.0.0.0/0.
#   EXPOSED      igw route + public address + an ingress rule from 0.0.0.0/0
#   ADDRESSABLE  igw route + public address, but NO rule admits the internet. The internet can
#                send it packets and every new connection is dropped. Not exposed today; one
#                rule away from it. (A NAT gateway is the textbook case.) Defended in exercises.md.
#   UNADDRESSED  igw route but no public address - nothing on the internet can name it
#   ISOLATED     no igw route on its subnet - replies could not leave even if a request arrived
# Also writes outputs/lab-09-exposure.json.
#
# set -uo pipefail WITHOUT -e: this is a report. One unreadable interface or group must
# produce a line that says so, not abort the whole run half-way through.
#   ./scripts/utilities/usms-exposure-report.sh        (no arguments; any directory)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-02.env"
VPC="${USMS_VPC_ID:?USMS_VPC_ID missing from configs/lab-02.env}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="Name=vpc-id,Values=$VPC"
aws ec2 describe-network-interfaces --filters "$F" --output json > "$T/eni.json"  || echo '{"NetworkInterfaces":[]}' > "$T/eni.json"
aws ec2 describe-route-tables      --filters "$F" --output json > "$T/rt.json"   || echo '{"RouteTables":[]}'      > "$T/rt.json"
aws ec2 describe-security-groups   --filters "$F" --output json > "$T/sg.json"   || echo '{"SecurityGroups":[]}'   > "$T/sg.json"
aws ec2 describe-instances         --filters "$F" --output json > "$T/ec2.json"  || echo '{"Reservations":[]}'     > "$T/ec2.json"

python3 - "$T" "$REPO_ROOT/outputs/lab-09-exposure.json" "$VPC" << 'PY'
import json, subprocess, sys, datetime

d, out_json, vpc = sys.argv[1], sys.argv[2], sys.argv[3]
enis = json.load(open(f"{d}/eni.json"))["NetworkInterfaces"]
rts = json.load(open(f"{d}/rt.json"))["RouteTables"]
sgs = {g["GroupId"]: g for g in json.load(open(f"{d}/sg.json"))["SecurityGroups"]}
insts = {i["InstanceId"]: i for r in json.load(open(f"{d}/ec2.json"))["Reservations"] for i in r["Instances"]}

# subnet -> route table: the explicit association, else the VPC's main table
main = next((rt for rt in rts if any(a.get("Main") for a in rt.get("Associations", []))), None)
by_subnet = {a["SubnetId"]: rt for rt in rts for a in rt.get("Associations", []) if a.get("SubnetId")}

def group(gid):
    """A group from the cache, or fetched by ID if the VPC filter missed it."""
    if gid in sgs:
        return sgs[gid]
    r = subprocess.run(["aws", "ec2", "describe-security-groups", "--group-ids", gid, "--output", "json"],
                       capture_output=True, text=True)
    g = json.loads(r.stdout)["SecurityGroups"][0] if r.returncode == 0 and r.stdout.strip() else {"GroupId": gid, "IpPermissions": []}
    sgs[gid] = g
    return g

def internet_ports(g):
    ports = []
    for p in g.get("IpPermissions", []):
        if any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", [])) or \
           any(r.get("CidrIpv6") == "::/0" for r in p.get("Ipv6Ranges", [])):
            lo = p.get("FromPort")
            ports.append("all" if lo is None else str(lo) if lo == p.get("ToPort") else f"{lo}-{p.get('ToPort')}")
    return ports

rows = []
for e in sorted(enis, key=lambda x: x.get("PrivateIpAddress", "")):
    att = (e.get("Attachment") or {}).get("InstanceId")
    inst = insts.get(att) if att else None
    tags = {t["Key"]: t["Value"] for t in (inst or {}).get("Tags", [])}
    desc = e.get("Description") or ""
    if inst:
        name = tags.get("Name", att)
        if inst.get("State", {}).get("Name") == "terminated":
            name += " (terminated, eni lingers)"
    elif desc.startswith("ECS task"):
        name = "enrolment task " + desc.rsplit("/", 1)[-1][:8]
    else:
        name = desc or f"{e['NetworkInterfaceId']} ({e.get('InterfaceType', 'interface')})"

    rt = by_subnet.get(e.get("SubnetId")) or main
    igw = rt and any(r.get("DestinationCidrBlock") == "0.0.0.0/0" and str(r.get("GatewayId", "")).startswith("igw-")
                     for r in rt.get("Routes", []))
    pub = (e.get("Association") or {}).get("PublicIp") or ((inst or {}).get("PublicIpAddress") if inst else None)
    placeholder = pub == "127.0.0.1"
    ports = sorted({p for gid in [g["GroupId"] for g in e.get("Groups", [])] for p in internet_ports(group(gid))})

    if not igw:
        verdict, why = "ISOLATED", f"no igw route on {e.get('SubnetId')}" + ("" if rt is not main else " (main route table)")
    elif not pub:
        verdict, why = "UNADDRESSED", "igw route, but no public address"
    elif ports:
        verdict, why = "EXPOSED", f"igw route + sg allows {','.join(ports)} from 0.0.0.0/0"
    else:
        verdict, why = "ADDRESSABLE", "igw route + public address, but no ingress rule at all from the internet"
    if placeholder:
        why += "  [127.0.0.1 = Floci placeholder]"
    rows.append({"name": name, "eni": e["NetworkInterfaceId"], "private": e.get("PrivateIpAddress"),
                 "public": pub, "subnet": e.get("SubnetId"), "routeTable": rt and rt["RouteTableId"],
                 "igwRoute": bool(igw), "internetPorts": ports, "groups": [g.get("GroupName") for g in e.get("Groups", [])],
                 "verdict": verdict, "reason": why})
    print(f"{name:<28} {e.get('PrivateIpAddress','-'):<12} {pub or '-':<11} {verdict:<12} {why}")

counts = {}
for r in rows:
    counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
print()
print("interfaces=%d  " % len(rows) + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
print("not listed: usms-nat and the load balancer - Floci 2.2.0 gives neither a network interface")
json.dump({"generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "vpc": vpc, "interfaces": rows, "counts": counts}, open(out_json, "w"), indent=2)
PY
