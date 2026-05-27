# `tests/` — Terratest harness

Two tests today, both wired into `.github/workflows/terratest.yml`:

| Test | Kind | Cost | Runtime |
|---|---|---|---|
| `janitor/` | Python unit (mocked boto3) | $0 | ~1 s |
| `vpc/` | Terratest integration (real AWS apply/destroy) | ~$0.01 | ~5 min |

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

### VPC module integration test

Requires real AWS credentials and an S3 bucket for per-test state isolation.
Get credentials however you normally do (IDC SSO, `aws-vault`, etc.) and
export the bucket name:

```bash
cd tests
export STATE_BUCKET=tfstate-networking-fun-<suffix>   # the bootstrap output
make vpc
```

Per-test state is written to
`s3://$STATE_BUCKET/terratest/<random-suffix>/terraform.tfstate`, so
multiple tests can run in parallel without trampling each other.

## Tags

Every resource the harness provisions carries:

| Tag | Value | Why |
|---|---|---|
| `Terratest` | `true` | Acceptance-criteria flag for slice 9. |
| `Workload` | `terratest` | Hits the `$5/mo` Terratest budget (`platform/budgets.tf`). |
| `AutoDelete` | `<now + 1h>` ISO 8601 | If a run aborts, the janitor (`platform/janitor.tf`) will sweep the leftovers. |

Tags are applied via the AWS provider's `default_tags` in
`tests/vpc/fixtures/providers.tf`, so every AWS resource a test creates
picks them up without per-resource edits.

## CI

`.github/workflows/terratest.yml` runs:

- **On PR**, only when `modules/**`, `labs/**`, `platform/janitor/**`, or
  `tests/**` change. Docs-only PRs skip Terratest entirely
  (path-filtered with `dorny/paths-filter`).
- **Nightly cron** at 07:00 UTC against `main`.
- The janitor unit test always runs (pure Python, no cost).
- The VPC test runs in the `lab` GitHub environment, gated on the
  `gillzj00` actor for PR triggers.
- A sticky PR comment summarises pass/fail per test.

Failed tests block merge via the standard GitHub required-checks rule.
