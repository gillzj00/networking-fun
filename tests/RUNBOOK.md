# `tests/` — local runbook

Operational details for running the Terratest suite locally. See
[`README.md`](./README.md) for the suite overview and CI behaviour.

## Janitor unit test

No AWS, no Go needed.

```bash
cd tests
make tidy        # one-time: installs pytest + mock deps
make janitor
```

## Integration tests (real AWS)

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

The `lab1` and `lab2` targets each run two subtests with `-parallel 2`, so the
wall-clock for each is one fault-scenario worth of provisioning, not two.

Per-test state is written to
`s3://$STATE_BUCKET/terratest/<random-suffix>/terraform.tfstate`, so multiple
tests can run in parallel without trampling each other.

## What each lab test does

`lab1/` and `lab2/` each:

1. Apply a Terraform fixture wrapping the lab module + probe module (the same
   composition `labs/runtime/` uses for per-PR labs).
2. Wait for the lab instance(s) to register with SSM (happy-path) or sleep
   ~90s (fault scenarios that deliberately fail to register).
3. Invoke the probe Lambda synchronously.
4. Assert that the decoded probe JSON matches the per-scenario expectation
   matrix in `labs/modules/probe/src/handler.py` (`LAYERED_EXPECTED`,
   `THREE_TIER_EXPECTED`).
5. `defer` `terraform destroy` so a panicking assertion still tears down.

Go assertions re-encode the expected matrices instead of importing them from
the probe handler — a regression in the handler that silently flips a cell
fails this test, not just the live PR probe matrix.
