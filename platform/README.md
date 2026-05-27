# platform/

Long-lived, account-wide resources for `networking-fun`: anything the labs
consume but that itself outlives any individual PR. Today this includes a
trivial CloudWatch log group (loop-proof), the Janitor Lambda, and AWS
Budgets. Future slices add the Route53 delegated zone, wildcard ACM cert,
and the lab module registry (see
[PRD §6](../PRD.md#6-architecture--three-layers)).

## Janitor Lambda

`platform-janitor` is a Python 3.12 Lambda triggered every 15 minutes by an
EventBridge schedule. It uses the Resource Groups Tagging API to find any
resource whose `AutoDelete` tag is an ISO 8601 timestamp in the past,
publishes the count to the `NetworkingFun/Janitor` CloudWatch metric
namespace, and emits one structured log line per scan.

A `platform-janitor-errors` CloudWatch alarm watches `AWS/Lambda Errors`
on the function and routes to the `platform-alerts` SNS topic. The topic
has one email subscription on `OwnerEmail` — **subscription confirmation
is a one-time manual step**: after apply, click the link in the AWS-sent
confirmation email or the alarm won't deliver.

### v1: scanner-only

The PRD specifies that destruction should run `terraform destroy` against
the per-PR state file at `s3://<bucket>/labs/<pr-number>/terraform.tfstate`
so we don't orphan state. That state doesn't exist yet — `labs/runtime/`
is built in slice 8 (issue #8). Rather than ship a direct-API destroyer we
would then have to rip out, the v1 Lambda is **scanner-only**: it finds
expired resources, logs them, and emits a metric. The destroy path will
be wired up alongside slice 8 by triggering the lab-destroy workflow with
the affected PR number(s).

In the meantime the alarm, schedule, IAM role, and SNS plumbing all exist
and exercise the GitOps loop end-to-end.

## Budgets

Two AWS Budgets, both notify `OwnerEmail` at 80% actual and 100% forecast:

| Budget | Limit | Scope |
|---|---|---|
| `networking-fun-monthly` | $25/mo | Whole sub-account |
| `networking-fun-terratest` | $5/mo | Resources tagged `Workload=terratest` (set by slice 9) |

The `Workload` tag must be **activated as a cost-allocation tag** in the
Billing console before the Terratest budget can read non-zero spend. This
is a one-time manual step in the management account
(`Billing → Cost allocation tags → User-defined → Workload → Activate`).

Slice 9 ([`tests/`](../tests/README.md)) is now wired to emit
`Workload=terratest` on every resource its harness provisions, so the
budget will see real spend once the tag is activated.

## Trigger model

This layer is GitOps. You do **not** run `terraform apply` from your laptop —
GitHub Actions does it, authenticated via OIDC.

| Event | Workflow | Effect |
|---|---|---|
| PR opened / pushed, touches `platform/**` | [`.github/workflows/platform-plan.yml`](../.github/workflows/platform-plan.yml) | `fmt -check`, `tflint`, `checkov`, `terraform plan`; plan posted as a sticky PR comment; blast-radius check fails the PR if it touches bootstrap-owned resources |
| Push to `main` touches `platform/**` | [`.github/workflows/platform-apply.yml`](../.github/workflows/platform-apply.yml) | `terraform apply -auto-approve` |

Both workflows assume the `gha-terraform` role (created by [`bootstrap/`](../bootstrap/)) via OIDC.

### Why the plan workflow needs an environment approval

The `gha-terraform` trust policy is restricted (F-01) to two GitHub OIDC
subject patterns: `ref:refs/heads/main` and `environment:<protected env>`.
That keeps fork PRs from silently obtaining Admin in the dev account.

To allow PR plans to read state, the plan workflow targets a dedicated
GitHub environment named `terraform-plan`. The environment is configured
with **required-reviewer = @gillzj00**, so every PR plan run waits for one
explicit approval click in the GH UI before the role is assumed. This is
the same gate F-01 applies to production applies, just on a per-plan basis.

Required prerequisite (one-time, per fork):

1. Repo settings → Environments → create `terraform-plan` with
   required-reviewer `@gillzj00` and "all branches" deployment policy.
2. Re-apply `bootstrap/` so the trust policy picks up the new
   `environment:terraform-plan` subject.

Required GitHub Actions variables (`Settings → Secrets and variables → Actions → Variables`):

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-2` |
| `AWS_ROLE_ARN` | output `gha_role_arn` from `bootstrap/` |
| `TFSTATE_BUCKET` | output `tfstate_bucket` from `bootstrap/` |

## Blast-radius safety rail

The plan workflow runs `terraform show -json tfplan` and fails the PR if
any `resource_change` touches resources that belong to `bootstrap/`:

- `aws_s3_bucket.tfstate` and its sub-resources (the state bucket)
- `aws_iam_openid_connect_provider.github`
- `aws_iam_role.gha_terraform` and its policy attachments

These resources can only be changed by re-running `bootstrap/` manually
from a privileged IDC session. Catching the attempt in CI prevents a
platform-layer PR from accidentally hosing the credential surface that CI
itself depends on.

## Escape hatch

GitOps is the normal path. The IDC SSO admin role retains permission to
run `terraform apply` from a laptop in genuine emergencies — see the PRD
for the policy. Manual applies are an incident, not a workflow.

## Local development

You should rarely need to run Terraform locally for this layer, but for
debugging:

```bash
cp backend.hcl.example backend.hcl
# Fill in your dev account ID

cp terraform.tfvars.example terraform.tfvars
# Adjust if needed

export AWS_PROFILE=networking-fun-dev.NetworkingFunDevAdmin
terraform init -backend-config=backend.hcl
terraform plan
```

Do not `terraform apply` from your laptop — let the workflow do it.
