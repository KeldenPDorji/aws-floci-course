#!/usr/bin/env python3
"""Lab 08 edits to committed manifests, idempotent, so the repository keeps matching the cluster.

  python3 scripts/utilities/lab-08-edits.py nodeselector   Step 11: nodeSelector workload=usms in 20-enrolment.yaml
  python3 scripts/utilities/lab-08-edits.py pdb            Step 12: retire lab-07/21-enrolment-pdb.yaml, whose object
                                                           lab-08/30-pdb-gateway.yaml now redefines (maxUnavailable 1)
  python3 scripts/utilities/lab-08-edits.py gateway-svc    Step 15: drop the ClusterIP Service from 40-gateway.yaml;
                                                           lab-08/50-service-loadbalancer.yaml now owns usms-gateway
  python3 scripts/utilities/lab-08-edits.py ex2            Exercise 2: usms-gateway replicas 1 -> 2 in 40-gateway.yaml

Why not the guide's Step 11 python: its anchor ("    spec:\\n      containers:") no longer exists once
Lab 07 Exercise 4 put topologySpreadConstraints first, and it would print "added" without adding.
Every edit here refuses to report success unless the text really changed.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
L7 = ROOT / "manifests" / "lab-07"


def nodeselector():
    p = L7 / "20-enrolment.yaml"
    s = p.read_text()
    if "nodeSelector:" in s:
        print(f"{p.name}: nodeSelector already present")
        return
    for anchor in ("    spec:\n      topologySpreadConstraints:", "    spec:\n      containers:"):
        if anchor in s:
            new = anchor.replace("    spec:\n", "    spec:\n      nodeSelector:\n        workload: usms\n", 1)
            p.write_text(s.replace(anchor, new, 1))
            print(f"{p.name}: nodeSelector workload=usms added to the pod template")
            return
    sys.exit(f"{p.name}: pod template anchor not found - file changed by hand?")


def pdb():
    q = L7 / "21-enrolment-pdb.yaml"
    if not q.exists():
        print(f"{q.name}: already retired")
        return
    q.unlink()
    print(f"{q.name}: removed - usms-enrolment-pdb is now defined once, in manifests/lab-08/30-pdb-gateway.yaml")


def gateway_svc():
    p = L7 / "40-gateway.yaml"
    s = p.read_text()
    marker = "---\napiVersion: v1\nkind: Service\n"
    if marker not in s:
        print(f"{p.name}: Service block already removed")
        return
    s = s[: s.index(marker)].rstrip("\n") + "\n"
    s += ("# The usms-gateway Service moved to manifests/lab-08/50-service-loadbalancer.yaml (Lab 08 Step 15),\n"
          "# so exactly one file defines it and re-applying this one cannot turn it back into a ClusterIP.\n")
    p.write_text(s)
    print(f"{p.name}: ClusterIP Service removed; lab-08/50-service-loadbalancer.yaml owns usms-gateway")


def ex2():
    p = L7 / "40-gateway.yaml"
    s = p.read_text()
    if "  replicas: 2\n" in s:
        print(f"{p.name}: replicas already 2")
        return
    if "  replicas: 1\n" not in s:
        sys.exit(f"{p.name}: 'replicas: 1' not found")
    p.write_text(s.replace("  replicas: 1\n", "  replicas: 2\n", 1))
    print(f"{p.name}: usms-gateway replicas 1 -> 2")


if __name__ == "__main__":
    ops = {"nodeselector": nodeselector, "pdb": pdb, "gateway-svc": gateway_svc, "ex2": ex2}
    ops.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
