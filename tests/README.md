# `tests/` — Terratest harness

Six tests today, all wired into `.github/workflows/terratest.yml`:

| Test | Kind | Cost | Runtime |
|---|---|---|---|
| `janitor/` | Python unit (mocked boto3) | $0 | ~1 s |
| `vpc/` | Terratest module-shape (real AWS apply/destroy) | ~$0.01 | ~5 min |
| `lab1/` → `TestLab1HappyPath` | Terratest end-to-end (Lab #1 happy-path probe) | ~$0.02 | ~10 min |
| `lab1/` → `TestLab1NaclDenyEgress` | Terratest end-to-end (Lab #1 fault) | ~$0.02 | ~10 min |
| `lab2/` → `TestLab2HappyPath` | Terratest end-to-end (Lab #2 happy-path matrix) | ~$0.03 | ~10 min |
| `lab2/` → `TestLab2NaclStatelessReturn` | Terratest end-to-end (Lab #2 fault) | ~$0.03 | ~10 min |

Total nightly compute is ~45 min wall-time across parallel CI jobs and
~$0.11 worth of AWS time per run. Well under the `$5/mo` Terratest
budget alarm even at one full run a day.

## Layout

```
tests/
├── go.mod                       # Go module for Terratest
├── Makefile                     # local entry points
├── helpers/                     # shared Terratest helpers
│   └── helpers.go
├── vpc/                         # VPC module integration test
│   ├── vpc_test.go
│   └── fixtures/                # test-only Terraform root
├── lab1/                        # Lab #1 end-to-end (layered-reachability)
│   ├── lab1_test.go             #   TestLab1HappyPath, TestLab1NaclDenyEgress
│   └── fixtures/                #   wraps lab + probe modules
├── lab2/                        # Lab #2 end-to-end (three-tier-segmentation)
│   ├── lab2_test.go             #   TestLab2HappyPath, TestLab2NaclStatelessReturn
│   └── fixtures/
└── janitor/                     # Python unit test for the janitor Lambda
    ├── requirements-dev.txt
    └── test_handler.py
```

## Running locally

### Janitor unit test

No AWS, no Go needed.

```bash
cd tests
make tidy        # one-time: installs pytest + mock deps
make janitor
```

### Integration tests (real AWS)

Requires real AWS credentials and an S3 bucket for per-test state isolation.
Get credentials however you normally do (IDC SSO, `aws-vault`, etc.) and
export the bucket name:

```bash
cd tests
export STATE_BUCKET=tfstate-networking-fun-<suffix>   # the bootstrap output

# One at a time:
make vpc           # static VPC module shape (~5 min)
make lab1          # Lab #1 happy-path + nacl-deny-egress (~20 min)
make lab2          # Lab #2 happy-path + nacl-stateless-return (~20 min)

# Or all of them:
make integration   # vpc + lab1 + lab2 sequentially
make all           # janitor + integration
```

The `lab1` and `lab2` targets each run two subtests with `-parallel 2`,
so the wall-clock for each is one fault-scenario worth of provisioning,
not two.

Per-test state is written to
`s3://$STATE_BUCKET/terratest/<random-suffix>/terraform.tfstate`, so
multiple tests can run in parallel without trampling each other.

## What each lab test does

`lab1/` and `lab2/` each:

1. Apply a Terraform fixture that wraps the lab module + probe module
   (the same composition `labs/runtime/` uses for the per-PR labs).
2. Wait for the lab instance(s) to register with SSM (happy-path) or
   sleep ~90 s (fault scenarios that deliberately fail to register).
3. Invoke the probe Lambda synchronously.
4. Assert that the decoded probe JSON matches the per-scenario
   expectation matrix encoded in
   `labs/modules/probe/src/handler.py` (`LAYERED_EXPECTED`,
   `THREE_TIER_EXPECTED`).
5. `defer` `terraform destroy` so a panicking assertion still tears
   the run down.

The Go assertions deliberately re-encode the expected matrices instead
of importing them from the probe handler, so a regression in the
handler that silently flips a cell fails this test, not just the
live PR probe matrix.

## Tags

Every resource the harness provisions carries:

| Tag | Value | Why |
|---|---|---|
| `Terratest` | `true` | Acceptance-criteria flag for slice 9. |
| `Workload` | `terratest` | Hits the `$5/mo` Terratest budget (`platform/budgets.tf`). |
| `AutoDelete` | `<now + 1h>` ISO 8601 | If a run aborts, the janitor (`platform/janitor.tf`) will sweep the leftovers. |

Tags are applied via the AWS provider's `default_tags` in each
fixture's `providers.tf`, so every AWS resource a test creates picks
them up without per-resource edits.

## CI

`.github/workflows/terratest.yml` runs:

- **On PR**, only when `labs/**`, `platform/janitor/**`,
  `platform/budgets.tf`, or `tests/**` change. Docs-only PRs skip
  Terratest entirely (path-filtered with `dorny/paths-filter`).
- **Nightly cron** at 07:00 UTC against `main`.
- The janitor unit test always runs (pure Python, no cost).
- VPC, lab1, and lab2 jobs run in the `lab` GitHub environment, each
  gated on the `gillzj00` actor for PR triggers.
- A sticky PR comment summarises pass/fail per job.

Failed tests block merge via the standard GitHub required-checks rule.
