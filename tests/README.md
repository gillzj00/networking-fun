# `tests/` — Terratest harness

Six tests, all wired into `.github/workflows/terratest.yml`:

| Test | Kind | Cost | Runtime |
|---|---|---|---|
| `janitor/` | Python unit (mocked boto3) | $0 | ~1s |
| `vpc/` | Terratest module-shape (real AWS apply/destroy) | ~$0.01 | ~5 min |
| `lab1/` → `TestLab1HappyPath` | Terratest end-to-end (Lab #1 happy-path probe) | ~$0.02 | ~10 min |
| `lab1/` → `TestLab1NaclDenyEgress` | Terratest end-to-end (Lab #1 fault) | ~$0.02 | ~10 min |
| `lab2/` → `TestLab2HappyPath` | Terratest end-to-end (Lab #2 happy-path matrix) | ~$0.03 | ~10 min |
| `lab2/` → `TestLab2NaclStatelessReturn` | Terratest end-to-end (Lab #2 fault) | ~$0.03 | ~10 min |

Total nightly compute: ~45 min wall-time across parallel CI jobs, ~$0.11 per
run. Well under the `$5/mo` Terratest budget alarm even at one full run a day.

## Layout

```
tests/
├── go.mod                       # Go module for Terratest
├── Makefile                     # local entry points
├── helpers/                     # shared Terratest helpers
├── vpc/                         # VPC module integration test
├── lab1/                        # Lab #1 end-to-end (layered-reachability)
├── lab2/                        # Lab #2 end-to-end (three-tier-segmentation)
└── janitor/                     # Python unit test for the janitor Lambda
```

See [`RUNBOOK.md`](./RUNBOOK.md) for local commands and per-test behaviour.

## Tags

Every resource the harness provisions carries:

| Tag | Value | Why |
|---|---|---|
| `Terratest` | `true` | Acceptance flag for slice 9. |
| `Workload` | `terratest` | Hits the `$5/mo` Terratest budget (`platform/budgets.tf`). |
| `AutoDelete` | `<now + 1h>` ISO 8601 | Janitor sweeps leftovers if a run aborts. |

Tags applied via AWS provider `default_tags` in each fixture's
`providers.tf` — every AWS resource picks them up without per-resource edits.

## CI

`.github/workflows/terratest.yml` runs:

- **On PR** only when `labs/**`, `platform/janitor/**`, `platform/budgets.tf`,
  or `tests/**` change. Docs-only PRs skip Terratest (path-filtered with
  `dorny/paths-filter`).
- **Nightly cron** at 07:00 UTC against `main`.
- The janitor unit test always runs (pure Python, no cost).
- VPC, lab1, lab2 run in the `lab` GitHub environment, gated on the
  `gillzj00` actor for PR triggers.
- A sticky PR comment summarises pass/fail per job.

Failed tests block merge via standard required-checks.
