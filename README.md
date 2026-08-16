# AWS CLI + Floci - USMS Course Project

Infrastructure for the **University Student Management System (USMS)**, built lab by lab
with the AWS CLI against [Floci](https://floci.io), a local AWS emulator.

## Quick start

```bash
source configs/course.env
./scripts/setup/floci-up.sh
./scripts/utilities/whoami.sh
```

## Daily workflow

```bash
./scripts/setup/floci-up.sh      # start or resume (idempotent)
# ... lab work ...
./scripts/setup/floci-down.sh    # pause; state is kept
```

## Never run these

| Command | Why |
|---|---|
| `docker compose down -v` | `-v` deletes volumes |
| `docker volume prune` | Unfiltered; use scripts/cleanup/floci-prune-volumes.sh |
| `floci start ...` | Bypasses Compose; disables persistence |
| `rm -rf ~/floci-data` | That directory is the IAM state |

## Labs

| Lab | Topic | Status | Report |
|-----|-------|--------|--------|
| 01  | IAM   | [x] complete | [lab-01-report.md](labs/lab-01-iam/lab-01-report.md) |
| 02  | VPC   | [ ] not started | |

### Lab 01 verification

![verify-lab-01.sh showing PASS=34 FAIL=0 across environment, persistence, groups, users, memberships, policies, roles and Git hygiene](screenshots/14-verify-lab-01.png)

Reproduce with:

```bash
source configs/course.env
./scripts/setup/floci-up.sh
source configs/lab-01.env
./scripts/utilities/verify-lab-01.sh
```

## Conventions

- All resources are prefixed `usms-`
- Region: `us-east-1`  ·  Floci account: `000000000000`
- Storage mode: `hybrid`, bind-mounted to `~/floci-data`
- Secrets live in `outputs/` and are **never** committed
# aws-floci-course
