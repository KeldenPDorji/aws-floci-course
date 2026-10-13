#!/usr/bin/env python3
"""Lab 07 exercise edits to committed manifests, idempotent, so they are not typed by hand.

  python3 scripts/utilities/lab-07-exercise-edits.py ex2   add the /timetable/ route to 40-gateway.yaml
  python3 scripts/utilities/lab-07-exercise-edits.py ex4   spread + anti-affinity in 20-enrolment.yaml,
                                                          and write 21-enrolment-pdb.yaml

Each edit is a plain text insertion at a fixed anchor, and refuses to run twice.
Run from anywhere; paths resolve from this file.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
M = ROOT / "manifests" / "lab-07"

ROUTE = """
      location /timetable/ {
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://usms-timetable.usms.svc.cluster.local/;
      }
"""

SPREAD = """      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: usms-enrolment
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app: usms-enrolment
"""

PDB = """apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: usms-enrolment-pdb
  namespace: usms
  labels:
    app: usms-enrolment
    project: usms
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: usms-enrolment
"""


def ex2():
    p = M / "40-gateway.yaml"
    s = p.read_text()
    if "location /timetable/" in s:
        print(f"{p.name}: /timetable/ route already present - nothing to do")
        return
    anchor = "      location /results/ {"
    end = s.index("      }\n", s.index(anchor)) + len("      }\n")
    s = s[:end] + ROUTE.lstrip("\n") + s[end:]
    s = s.replace('"routes":["/enrolment/","/results/"]', '"routes":["/enrolment/","/results/","/timetable/"]')
    p.write_text(s)
    print(f"{p.name}: added the /timetable/ location and listed it in the root response")


def ex4():
    p = M / "20-enrolment.yaml"
    s = p.read_text()
    if "topologySpreadConstraints" in s:
        print(f"{p.name}: spread constraints already present")
    else:
        anchor = "    spec:\n      containers:\n        - name: enrolment"
        if anchor not in s:
            sys.exit(f"{p.name}: anchor not found - file changed by hand?")
        s = s.replace(anchor, "    spec:\n" + SPREAD + "      containers:\n        - name: enrolment", 1)
        p.write_text(s)
        print(f"{p.name}: added topologySpreadConstraints (advisory) and preferred podAntiAffinity")
    q = M / "21-enrolment-pdb.yaml"
    if q.exists():
        print(f"{q.name}: already present")
    else:
        q.write_text(PDB)
        print(f"{q.name}: written (minAvailable 1 - enforced on voluntary disruption)")


if __name__ == "__main__":
    {"ex2": ex2, "ex4": ex4}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
